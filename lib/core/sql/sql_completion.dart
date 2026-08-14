import 'package:astryx_ui/astryx_ui.dart';

import 'sql_lexer.dart';

/// What the editor knows about the connection it is writing against.
///
/// Deliberately a plain value rather than a live view of the connection: the
/// completion engine runs on every keystroke and must never wait on a query.
/// Whoever owns the connection fills this in as the answers arrive, and the
/// engine offers whatever is in it at the time.
class SqlCatalogue {
  const SqlCatalogue({
    this.tables = const <String>[],
    this.columns = const <String, List<SqlColumnInfo>>{},
  });

  /// Every container the connection listed, named as the backend names it.
  final List<String> tables;

  /// Columns by table, keyed by the *lower-cased* table name. Read it through
  /// [columnsOf], which also answers for a name written the other way round.
  final Map<String, List<SqlColumnInfo>> columns;

  static const empty = SqlCatalogue();

  /// The columns known for [table], by any casing, and by either its bare or
  /// its qualified name — `public.users` and `users` are one table to someone
  /// typing.
  List<SqlColumnInfo> columnsOf(String table) {
    final key = table.toLowerCase();
    final direct = columns[key];
    if (direct != null) return direct;
    final bare = key.split('.').last;
    final match = columns.entries.cast<MapEntry<String, List<SqlColumnInfo>>?>().firstWhere(
      (e) => e!.key == bare || e.key.split('.').last == bare,
      orElse: () => null,
    );
    return match?.value ?? const <SqlColumnInfo>[];
  }

  bool knowsColumnsOf(String table) => columnsOf(table).isNotEmpty;

  SqlCatalogue copyWith({
    List<String>? tables,
    Map<String, List<SqlColumnInfo>>? columns,
  }) => SqlCatalogue(
    tables: tables ?? this.tables,
    columns: columns ?? this.columns,
  );
}

/// One column, as the completion list needs to describe it.
class SqlColumnInfo {
  const SqlColumnInfo({
    required this.name,
    required this.type,
    this.nullable = true,
    this.primaryKey = false,
  });

  final String name;
  final String type;
  final bool nullable;
  final bool primaryKey;

  /// The line under the name in the list: enough to answer "can I compare this
  /// to a string, and can it be null" without opening the schema view.
  String get detail => <String>[
    type,
    if (primaryKey) 'primary key' else if (!nullable) 'not null',
  ].join(' · ');
}

/// What a suggestion is, which decides its icon and how it is ranked.
enum SqlCompletionKind { column, table, alias, function, keyword }

/// One suggestion.
class SqlCompletion {
  const SqlCompletion({
    required this.label,
    required this.kind,
    this.insertOverride,
    this.detail,
  });

  /// What the list shows.
  final String label;

  /// What replaces the word being typed where that is not the label itself —
  /// `COUNT()` is offered with its brackets and inserted with the caret
  /// inside them.
  final String? insertOverride;

  String get insert => insertOverride ?? label;

  final SqlCompletionKind kind;

  /// The supporting line — a column's type, a table's kind.
  final String? detail;

  AstryxSyntaxToken get syntax => switch (kind) {
    SqlCompletionKind.column => AstryxSyntaxToken.property,
    SqlCompletionKind.table => AstryxSyntaxToken.type,
    SqlCompletionKind.alias => AstryxSyntaxToken.variable,
    SqlCompletionKind.function => AstryxSyntaxToken.function,
    SqlCompletionKind.keyword => AstryxSyntaxToken.keyword,
  };
}

/// The suggestions for one caret position, and the span they replace.
class SqlCompletionResult {
  const SqlCompletionResult({
    required this.items,
    required this.replaceStart,
    required this.replaceEnd,
    required this.prefix,
  });

  static const none = SqlCompletionResult(
    items: <SqlCompletion>[],
    replaceStart: 0,
    replaceEnd: 0,
    prefix: '',
  );

  final List<SqlCompletion> items;

  /// The half-open range of the word being completed. Accepting a suggestion
  /// replaces exactly this.
  final int replaceStart;
  final int replaceEnd;

  /// What the user has typed of that word.
  final String prefix;

  bool get isEmpty => items.isEmpty;

  /// The rest of the best suggestion — what the editor paints ahead of the
  /// caret. Empty unless the best one actually continues what was typed: a
  /// hint that is not a continuation would have to be read rather than
  /// glanced at, which is slower than no hint.
  String get ghost {
    if (items.isEmpty || prefix.isEmpty) return '';
    final best = items.first.insert;
    if (best.length <= prefix.length) return '';
    if (!best.toLowerCase().startsWith(prefix.toLowerCase())) return '';
    return best.substring(prefix.length);
  }
}

/// A table named in the statement, and what it was called there.
class SqlTableRef {
  const SqlTableRef(this.table, this.alias);

  final String table;
  final String? alias;
}

/// Statement-level keywords, offered when nothing else fits.
const _statementKeywords = <String>[
  'SELECT',
  'INSERT INTO',
  'UPDATE',
  'DELETE FROM',
  'WITH',
  'CREATE TABLE',
  'ALTER TABLE',
  'DROP TABLE',
  'EXPLAIN',
];

/// Keywords that continue a statement already under way.
const _clauseKeywords = <String>[
  'FROM',
  'WHERE',
  'GROUP BY',
  'ORDER BY',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'INNER JOIN',
  'LEFT JOIN',
  'RIGHT JOIN',
  'FULL JOIN',
  'CROSS JOIN',
  'ON',
  'AS',
  'AND',
  'OR',
  'NOT',
  'IN',
  'IS NULL',
  'IS NOT NULL',
  'LIKE',
  'BETWEEN',
  'DISTINCT',
  'UNION',
  'UNION ALL',
  'RETURNING',
  'SET',
  'VALUES',
  'ASC',
  'DESC',
];

/// Functions worth a snippet rather than a bare name.
const _functionSnippets = <(String, String)>[
  ('COUNT(*)', 'COUNT(*)'),
  ('COUNT()', 'COUNT('),
  ('SUM()', 'SUM('),
  ('AVG()', 'AVG('),
  ('MIN()', 'MIN('),
  ('MAX()', 'MAX('),
  ('COALESCE()', 'COALESCE('),
  ('LOWER()', 'LOWER('),
  ('UPPER()', 'UPPER('),
  ('LENGTH()', 'LENGTH('),
  ('NOW()', 'NOW()'),
];

/// The clause the caret is in, which is what decides *what kind* of thing is
/// being named at it.
enum SqlClause {
  none,
  select,
  from,
  join,
  on,
  where,
  having,
  groupBy,
  orderBy,
  set,
  into,
  valueList,
  update,
  table,
}

/// Suggests what could come next at [caret] in [text].
///
/// The rule the whole engine follows: offer what is *nameable here*. After
/// `FROM` that is a table and nothing else; after `SELECT` or `WHERE` it is the
/// columns of the tables this statement already named, because those are the
/// only columns that can be referred to. A list that offers every column in the
/// database at every position is a list nobody reads.
///
/// [contextTable] is the table the editor is pointed at from outside the text —
/// the one selected in the rail. It stands in for a `FROM` clause that has not
/// been written yet: an empty `SELECT ` with a table selected offers that
/// table's columns, which is the whole point of having selected it. It is
/// ignored the moment the statement names a table of its own, because at that
/// point the statement has said what it is about and the rail has not.
SqlCompletionResult completeSql({
  required String text,
  required int caret,
  required SqlCatalogue catalogue,
  String? contextTable,
  int limit = 40,
}) {
  if (caret < 0 || caret > text.length) return SqlCompletionResult.none;

  final tokens = tokenizeSql(text);
  final (statementStart, statementEnd) = sqlStatementRange(text, caret, tokens);
  final inStatement = tokens
      .where((t) => t.start >= statementStart && t.end <= statementEnd)
      .toList();

  // Inside a comment or a string nothing is being named, and a list popping up
  // over prose is noise.
  final enclosing = inStatement.cast<SqlToken?>().firstWhere(
    (t) => t!.start < caret && t.end >= caret,
    orElse: () => null,
  );
  if (enclosing != null &&
      (enclosing.token == AstryxSyntaxToken.comment ||
          enclosing.token == AstryxSyntaxToken.string)) {
    return SqlCompletionResult.none;
  }

  final word = _wordAt(text, caret);
  final prefix = text.substring(word.$1, caret);
  final qualifier = _qualifierBefore(text, word.$1);
  final clause = _clauseAt(inStatement, word.$1);
  final named = sqlTableRefs(inStatement, text);

  // The statement's own tables where it has any, and the selected one where it
  // has none.
  final refs = named.isNotEmpty
      ? named
      : <SqlTableRef>[if (contextTable != null) SqlTableRef(contextTable, null)];

  final items = <SqlCompletion>[];

  void addColumns(Iterable<SqlTableRef> from, {bool qualify = false}) {
    for (final ref in from) {
      for (final column in catalogue.columnsOf(ref.table)) {
        final name = ref.alias != null && qualify
            ? '${ref.alias}.${column.name}'
            : column.name;
        items.add(
          SqlCompletion(
            label: name,
            kind: SqlCompletionKind.column,
            detail: '${column.detail} · ${ref.table}',
          ),
        );
      }
    }
  }

  void addTables() {
    for (final table in catalogue.tables) {
      // The selected one says so, because after `FROM` it is almost always the
      // table meant and the list is otherwise every table in the database.
      final selected =
          contextTable != null &&
          (table.toLowerCase() == contextTable.toLowerCase() ||
              table.toLowerCase().split('.').last ==
                  contextTable.toLowerCase().split('.').last);
      items.add(
        SqlCompletion(
          label: table,
          kind: SqlCompletionKind.table,
          detail: selected ? 'table · selected' : 'table',
        ),
      );
    }
  }

  void addAliases() {
    for (final ref in refs) {
      if (ref.alias == null) continue;
      items.add(
        SqlCompletion(
          label: ref.alias!,
          kind: SqlCompletionKind.alias,
          detail: ref.table,
        ),
      );
    }
  }

  void addFunctions() {
    for (final (label, insert) in _functionSnippets) {
      items.add(
        SqlCompletion(
          label: label,
          insertOverride: insert,
          kind: SqlCompletionKind.function,
          detail: 'function',
        ),
      );
    }
  }

  void addKeywords(List<String> words) {
    for (final word in words) {
      items.add(SqlCompletion(label: word, kind: SqlCompletionKind.keyword));
    }
  }

  if (qualifier != null) {
    // `alias.` or `table.` — only that one table's columns, and no keywords:
    // nothing else can legally follow a dot.
    final target = refs.cast<SqlTableRef?>().firstWhere(
      (r) => r!.alias?.toLowerCase() == qualifier.toLowerCase(),
      orElse: () => null,
    );
    addColumns(<SqlTableRef>[SqlTableRef(target?.table ?? qualifier, null)]);
    return _rank(items, prefix, word.$1, caret, limit);
  }


  switch (clause) {
    case SqlClause.from || SqlClause.join || SqlClause.into || SqlClause.update || SqlClause.table:
      addTables();
    case SqlClause.select || SqlClause.where || SqlClause.on || SqlClause.groupBy || SqlClause.orderBy || SqlClause.set || SqlClause.having:
      addColumns(refs);
      addAliases();
      addFunctions();
      addTables();
      addKeywords(_clauseKeywords);
    case SqlClause.valueList:
      addKeywords(<String>['DEFAULT', 'NULL']);
    case SqlClause.none:
      addKeywords(_statementKeywords);
      // A bare table name at the start of a line is nearly always the start of
      // `SELECT * FROM …` written back to front, so the tables stay on offer.
      addTables();
  }

  return _rank(items, prefix, word.$1, caret, limit, preferred: contextTable);
}

/// The half-open range of the statement [caret] sits in.
///
/// Statements are split on `;`, but only on a `;` the lexer called
/// punctuation — one inside a string or a comment is text, not a boundary.
(int, int) sqlStatementRange(String text, int caret, [List<SqlToken>? tokens]) {
  final all = tokens ?? tokenizeSql(text);
  var start = 0;
  var end = text.length;
  for (final token in all) {
    if (token.token != AstryxSyntaxToken.punctuation || token.text != ';') {
      continue;
    }
    if (token.end <= caret) {
      start = token.end;
    } else {
      end = token.start;
      break;
    }
  }
  return (start, end);
}

/// Splits the lexer's runs into single words, keeping their positions.
///
/// The highlighter has no reason to cut `tracks t` in two — neither word is
/// coloured, so it emits one unstyled run. Everything below needs them apart:
/// `FROM tracks t` is a table and its alias, and a single run cannot say that.
List<SqlToken> sqlWords(List<SqlToken> tokens) {
  final words = <SqlToken>[];
  for (final token in tokens) {
    if (token.token != null) {
      words.add(token);
      continue;
    }
    var start = -1;
    for (var i = 0; i <= token.text.length; i++) {
      final isWord = i < token.text.length && _isIdentifierChar(token.text[i]);
      if (isWord && start < 0) {
        start = i;
      } else if (!isWord && start >= 0) {
        words.add(
          SqlToken(token.text.substring(start, i), null, token.start + start),
        );
        start = -1;
      }
    }
  }
  return words;
}

/// Every table the statement names, with the alias it was given.
///
/// `FROM users u JOIN orders AS o ON …` is two refs, and it is what makes
/// `u.` and `o.` mean anything.
List<SqlTableRef> sqlTableRefs(List<SqlToken> tokens, String text) {
  final refs = <SqlTableRef>[];
  final words = sqlWords(tokens).where(_isMeaningful).toList();

  for (var i = 0; i < words.length; i++) {
    final lower = words[i].text.toLowerCase().trim();
    if (lower != 'from' && lower != 'join' && lower != 'into' && lower != 'update') {
      continue;
    }
    final name = _identifierAt(words, i + 1);
    if (name == null) continue;
    var alias = _identifierAt(words, name.$2 + 1);
    if (alias != null && alias.$1.toLowerCase() == 'as') {
      alias = _identifierAt(words, alias.$2 + 1);
    }
    final aliasWord = alias?.$1;
    refs.add(
      SqlTableRef(
        name.$1,
        aliasWord == null || _isReserved(aliasWord) ? null : aliasWord,
      ),
    );
  }
  return refs;
}

/// The word being typed: `[start, caret)` where start is the first character
/// of the identifier the caret is inside or at the end of.
(int, int) _wordAt(String text, int caret) {
  var start = caret;
  while (start > 0 && _isIdentifierChar(text[start - 1])) {
    start--;
  }
  return (start, caret);
}

/// The `alias` in `alias.column`, if the word at [wordStart] follows a dot.
String? _qualifierBefore(String text, int wordStart) {
  if (wordStart == 0 || text[wordStart - 1] != '.') return null;
  var end = wordStart - 1;
  var start = end;
  while (start > 0 && _isIdentifierChar(text[start - 1])) {
    start--;
  }
  if (start == end) return null;
  return text.substring(start, end);
}

/// Which clause [offset] falls in: the last clause keyword before it wins.
SqlClause _clauseAt(List<SqlToken> tokens, int offset) {
  var clause = SqlClause.none;
  String? previous;
  for (final token in sqlWords(tokens)) {
    if (token.start >= offset) break;
    if (!_isMeaningful(token)) continue;
    final word = token.text.toLowerCase().trim();
    clause = switch (word) {
      'select' => SqlClause.select,
      'from' => SqlClause.from,
      'join' => SqlClause.join,
      'on' || 'using' => SqlClause.on,
      'where' => SqlClause.where,
      'having' => SqlClause.having,
      'set' => SqlClause.set,
      'into' => SqlClause.into,
      'values' => SqlClause.valueList,
      'update' => SqlClause.update,
      'table' => SqlClause.table,
      // `BY` alone is meaningless; what it belongs to is the word before it.
      'by' when previous == 'group' => SqlClause.groupBy,
      'by' when previous == 'order' => SqlClause.orderBy,
      _ => clause,
    };
    previous = word;
  }
  return clause;
}

/// The [index]th meaningful word if it is a name rather than punctuation, with
/// the index it was found at.
(String, int)? _identifierAt(List<SqlToken> words, int index) {
  if (index < 0 || index >= words.length) return null;
  final token = words[index];
  if (token.token == AstryxSyntaxToken.punctuation ||
      token.token == AstryxSyntaxToken.operator) {
    return null;
  }
  final text = token.text.trim();
  if (text.isEmpty) return null;
  return (text.replaceAll(RegExp('^["`]|["`]\$'), ''), index);
}

/// Whether a token carries a word at all — whitespace runs come back as
/// unstyled tokens and would otherwise count as identifiers.
bool _isMeaningful(SqlToken token) {
  if (token.token == AstryxSyntaxToken.comment) return false;
  return token.text.trim().isNotEmpty;
}

const _reserved = <String>{
  'on',
  'where',
  'group',
  'order',
  'having',
  'limit',
  'inner',
  'left',
  'right',
  'full',
  'cross',
  'join',
  'union',
  'set',
  'values',
  'returning',
  'using',
  'select',
  'from',
  'and',
  'or',
};

bool _isReserved(String word) => _reserved.contains(word.toLowerCase());

bool _isIdentifierChar(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      (code >= 0x30 && code <= 0x39) ||
      code == 0x5F;
}

/// Filters by what has been typed and puts the likeliest first.
///
/// Prefix matches beat matches in the middle of a name — someone typing `us`
/// means `users` long before they mean `status`. Within a tier the kind
/// decides: a column is a better guess than the keyword that could also follow,
/// because the keywords are few and already known while the columns are the
/// thing nobody remembers.
///
/// [preferred] is a name that wins its tier outright — the table selected in the
/// rail, which is the one the reader is looking at while they type.
SqlCompletionResult _rank(
  List<SqlCompletion> items,
  String prefix,
  int start,
  int end,
  int limit, {
  String? preferred,
}) {
  final preferredNames = <String>{
    if (preferred != null) ...<String>[
      preferred.toLowerCase(),
      preferred.toLowerCase().split('.').last,
    ],
  };
  final lower = prefix.toLowerCase();
  final scored = <(SqlCompletion, int)>[];

  for (final item in items) {
    final label = item.label.toLowerCase();
    if (lower.isEmpty) {
      scored.add((item, 1));
      continue;
    }
    if (label.startsWith(lower)) {
      scored.add((item, 0));
    } else if (label.contains(lower)) {
      scored.add((item, 2));
    } else if (_subsequence(label, lower)) {
      scored.add((item, 3));
    }
  }

  int kindRank(SqlCompletionKind kind) => switch (kind) {
    SqlCompletionKind.column => 0,
    SqlCompletionKind.alias => 1,
    SqlCompletionKind.table => 2,
    SqlCompletionKind.function => 3,
    SqlCompletionKind.keyword => 4,
  };

  // 0 for the selected table, 1 for every other table. A plain sort key rather
  // than insertion order, because `List.sort` is not stable and the one row
  // that has to come first cannot be left to chance. Applied *within* the kind,
  // not above it: a table beating the columns of the statement in a `SELECT`
  // would be worse than not marking it at all.
  int preferenceRank(SqlCompletion item) {
    if (item.kind != SqlCompletionKind.table) return 1;
    final label = item.label.toLowerCase();
    return preferredNames.contains(label) ||
            preferredNames.contains(label.split('.').last)
        ? 0
        : 1;
  }

  scored.sort((a, b) {
    final byMatch = a.$2.compareTo(b.$2);
    if (byMatch != 0) return byMatch;
    final byKind = kindRank(a.$1.kind).compareTo(kindRank(b.$1.kind));
    if (byKind != 0) return byKind;
    final byPreference = preferenceRank(a.$1).compareTo(preferenceRank(b.$1));
    if (byPreference != 0) return byPreference;
    final byLength = a.$1.label.length.compareTo(b.$1.label.length);
    if (byLength != 0) return byLength;
    return a.$1.label.toLowerCase().compareTo(b.$1.label.toLowerCase());
  });

  final seen = <String>{};
  final unique = <SqlCompletion>[];
  for (final (item, _) in scored) {
    if (!seen.add('${item.kind}:${item.label.toLowerCase()}')) continue;
    unique.add(item);
    if (unique.length >= limit) break;
  }

  return SqlCompletionResult(
    items: unique,
    replaceStart: start,
    replaceEnd: end,
    prefix: prefix,
  );
}

/// Whether every character of [needle] appears in [haystack] in order — the
/// `slct` that should still find `select`.
bool _subsequence(String haystack, String needle) {
  var i = 0;
  for (var j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack[j] == needle[i]) i++;
  }
  return i == needle.length;
}
