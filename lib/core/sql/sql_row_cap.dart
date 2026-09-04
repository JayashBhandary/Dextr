/// A ceiling on how many rows a raw query is allowed to bring back.
library;

import 'package:astryx_ui/astryx_ui.dart';

import '../capabilities.dart';
import 'sql_lexer.dart';

/// How many rows of a raw query result the application keeps.
///
/// `SELECT * FROM orders WHERE coupon_code IS NOT NULL` against a real orders
/// table is a few million rows, and every one of them is a `Map` built on the
/// UI isolate and then a row of widgets in a table that does not virtualise.
/// The ceiling is what makes an unqualified `SELECT *` survivable: enough rows
/// to look at and to page through, few enough that the fetch and the render
/// stay in the tens of milliseconds.
///
/// It is a ceiling, not a page size — the grid pages within what is fetched.
const int maxQueryRows = 10000;

/// Whether a `LIMIT n` can be appended to a statement for this kind.
///
/// The SQL engines all take it. The others are not SQL at all: a Redis command,
/// a Mongo pipeline, a REST path and a GraphQL document each have their own way
/// of asking for fewer results, and appending words to them would produce
/// nonsense rather than a smaller result.
bool dialectTakesLimitClause(DataSourceKind kind) => switch (kind) {
  DataSourceKind.sqlite ||
  DataSourceKind.postgres ||
  DataSourceKind.redshift ||
  DataSourceKind.mysql ||
  DataSourceKind.snowflake ||
  DataSourceKind.bigquery => true,
  _ => false,
};

/// [sql] with a row ceiling applied, or null when it must be left alone.
///
/// Null is the answer for anything that is not one read-only statement, and for
/// a statement that already says how many rows it wants: the user's own `LIMIT`
/// is a decision, and a second one appended after it would either be a syntax
/// error or would silently override it.
///
/// The cap asked for is [cap] `+ 1`, which is what lets the caller tell "the
/// table has exactly this many rows" apart from "there are more, and this is
/// where we stopped looking".
String? sqlWithRowCap(String sql, {int cap = maxQueryRows}) {
  final trimmed = sql.trim();
  if (trimmed.isEmpty) return null;

  // Comments and string bodies are not clauses: a `-- limit the audit table`
  // above the query, or a literal `'limit'`, must not read as one.
  //
  // The lexer runs everything it does not recognise together — `orders FETCH
  // FIRST` comes back as one unclassified run — so the words of those runs are
  // split out here. Only the keywords it does know arrive one to a token, and
  // `FETCH` is not one of them.
  final words = <String>[];
  for (final token in tokenizeSql(trimmed)) {
    if (token.token == AstryxSyntaxToken.comment ||
        token.token == AstryxSyntaxToken.string) {
      continue;
    }
    if (token.token == AstryxSyntaxToken.punctuation ||
        token.token == AstryxSyntaxToken.operator) {
      words.add(token.text);
      continue;
    }
    for (final word in token.text.split(RegExp(r'\s+'))) {
      if (word.isNotEmpty) words.add(word.toLowerCase());
    }
  }
  if (words.isEmpty) return null;

  if (words.first != 'select' && words.first != 'with') return null;

  var depth = 0;
  for (var i = 0; i < words.length; i++) {
    switch (words[i]) {
      case '(':
        depth++;
      case ')':
        depth--;
      // A semicolon anywhere but the very end means more than one statement,
      // and only the caller knows which of them it meant to run.
      case ';':
        if (i != words.length - 1) return null;
      // Only at the top level: a `LIMIT` inside a subquery or a CTE bounds that
      // subquery, not the rows the statement returns.
      case 'limit' || 'offset' || 'fetch':
        if (depth == 0) return null;
    }
  }

  final body = trimmed.endsWith(';')
      ? trimmed.substring(0, trimmed.length - 1).trimRight()
      : trimmed;
  return '$body\nLIMIT ${cap + 1}';
}
