import 'package:astryx_ui/astryx_ui.dart';

/// One run of source text and the syntax role it plays.
///
/// A null [token] means "whatever the base style says" — the editor's own
/// foreground colour, rather than a syntax colour.
class SqlToken {
  const SqlToken(this.text, this.token, [this.start = 0]);

  final String text;
  final AstryxSyntaxToken? token;

  /// Where this run begins in the source it was cut from.
  ///
  /// The highlighter never needed it — it lays the runs out end to end. The
  /// completion engine does: everything it decides is "what is at the caret",
  /// and a run with no position cannot answer that.
  final int start;

  /// One past the last character of this run.
  int get end => start + text.length;
}

/// Reserved words. Anything not in here is an identifier, which is the honest
/// default: a highlighter that guesses at table names gets them wrong.
const _keywords = <String>{
  'add',
  'all',
  'alter',
  'analyze',
  'and',
  'as',
  'asc',
  'attach',
  'begin',
  'between',
  'by',
  'cascade',
  'case',
  'cast',
  'check',
  'collate',
  'column',
  'commit',
  'conflict',
  'constraint',
  'create',
  'cross',
  'database',
  'default',
  'deferrable',
  'delete',
  'desc',
  'distinct',
  'do',
  'drop',
  'each',
  'else',
  'end',
  'escape',
  'except',
  'exists',
  'explain',
  'foreign',
  'from',
  'full',
  'group',
  'having',
  'if',
  'ignore',
  'immediate',
  'in',
  'index',
  'inner',
  'insert',
  'intersect',
  'into',
  'is',
  'join',
  'key',
  'left',
  'like',
  'limit',
  'not',
  'nothing',
  'null',
  'nulls',
  'offset',
  'on',
  'or',
  'order',
  'outer',
  'over',
  'partition',
  'primary',
  'references',
  'rename',
  'replace',
  'restrict',
  'returning',
  'right',
  'rollback',
  'row',
  'savepoint',
  'select',
  'set',
  'table',
  'temp',
  'temporary',
  'then',
  'to',
  'transaction',
  'trigger',
  'truncate',
  'union',
  'unique',
  'update',
  'using',
  'vacuum',
  'values',
  'view',
  'when',
  'where',
  'window',
  'with',
};

/// Words that are values rather than instructions.
const _constants = <String>{'true', 'false', 'current_timestamp', 'default'};

/// Aggregates and the functions a query is usually built from.
const _functions = <String>{
  'abs',
  'avg',
  'cast',
  'ceil',
  'coalesce',
  'concat',
  'count',
  'date',
  'date_trunc',
  'floor',
  'greatest',
  'group_concat',
  'ifnull',
  'json_agg',
  'json_build_object',
  'least',
  'length',
  'lower',
  'max',
  'min',
  'now',
  'nullif',
  'random',
  'round',
  'row_number',
  'strftime',
  'substr',
  'substring',
  'sum',
  'to_char',
  'trim',
  'upper',
};

/// Types, as they appear in DDL.
const _types = <String>{
  'bigint',
  'blob',
  'bool',
  'boolean',
  'bytea',
  'char',
  'date',
  'decimal',
  'double',
  'float',
  'int',
  'int2',
  'int4',
  'int8',
  'integer',
  'json',
  'jsonb',
  'numeric',
  'real',
  'serial',
  'smallint',
  'text',
  'time',
  'timestamp',
  'timestamptz',
  'uuid',
  'varchar',
};

const _operatorChars = '+-*/%<>=!|&~^';
const _punctuationChars = '(),;.[]{}:?';

/// Splits SQL into coloured runs. Every character of [source] appears in the
/// output exactly once and in order, because the result has to reassemble into
/// the text being edited — a highlighter that drops a character moves the caret.
List<SqlToken> tokenizeSql(String source) {
  final tokens = <SqlToken>[];
  final buffer = StringBuffer();
  var bufferStart = 0;

  void flushPlain() {
    if (buffer.isEmpty) return;
    tokens.add(SqlToken(buffer.toString(), null, bufferStart));
    buffer.clear();
  }

  void emit(String text, AstryxSyntaxToken token, int start) {
    flushPlain();
    tokens.add(SqlToken(text, token, start));
  }

  var i = 0;
  while (i < source.length) {
    final rest = source.substring(i);
    final char = source[i];

    // -- line comment, to the end of the line.
    if (rest.startsWith('--') || rest.startsWith('#')) {
      final end = source.indexOf('\n', i);
      final stop = end == -1 ? source.length : end;
      emit(source.substring(i, stop), AstryxSyntaxToken.comment, i);
      i = stop;
      continue;
    }

    // /* block comment */, unterminated to the end of input.
    if (rest.startsWith('/*')) {
      final end = source.indexOf('*/', i + 2);
      final stop = end == -1 ? source.length : end + 2;
      emit(source.substring(i, stop), AstryxSyntaxToken.comment, i);
      i = stop;
      continue;
    }

    // 'string literal', where '' is an escaped quote.
    if (char == "'") {
      var j = i + 1;
      while (j < source.length) {
        if (source[j] == "'") {
          if (j + 1 < source.length && source[j + 1] == "'") {
            j += 2;
            continue;
          }
          j++;
          break;
        }
        j++;
      }
      emit(source.substring(i, j), AstryxSyntaxToken.string, i);
      i = j;
      continue;
    }

    // "quoted identifier" or `backticked` one — a name, not a string.
    if (char == '"' || char == '`') {
      final end = source.indexOf(char, i + 1);
      final stop = end == -1 ? source.length : end + 1;
      emit(source.substring(i, stop), AstryxSyntaxToken.property, i);
      i = stop;
      continue;
    }

    // A number, including a decimal part.
    if (_isDigit(char)) {
      var j = i;
      while (j < source.length && (_isDigit(source[j]) || source[j] == '.')) {
        j++;
      }
      emit(source.substring(i, j), AstryxSyntaxToken.number, i);
      i = j;
      continue;
    }

    // :named, $1 and @var parameters.
    if ((char == ':' || char == r'$' || char == '@') &&
        i + 1 < source.length &&
        (_isWordChar(source[i + 1]) || _isDigit(source[i + 1]))) {
      var j = i + 1;
      while (j < source.length &&
          (_isWordChar(source[j]) || _isDigit(source[j]))) {
        j++;
      }
      emit(source.substring(i, j), AstryxSyntaxToken.variable, i);
      i = j;
      continue;
    }

    // A word: keyword, type, function, constant, or a name.
    if (_isWordChar(char)) {
      var j = i;
      while (j < source.length &&
          (_isWordChar(source[j]) || _isDigit(source[j]))) {
        j++;
      }
      final word = source.substring(i, j);
      final lower = word.toLowerCase();
      // A word followed by '(' is being called, whatever else it looks like.
      final called = _peekIsCall(source, j);
      final role = switch (lower) {
        _ when _constants.contains(lower) => AstryxSyntaxToken.constant,
        _ when _keywords.contains(lower) => AstryxSyntaxToken.keyword,
        _ when called && _functions.contains(lower) =>
          AstryxSyntaxToken.function,
        _ when called => AstryxSyntaxToken.function,
        _ when _types.contains(lower) => AstryxSyntaxToken.type,
        _ => null,
      };
      if (role == null) {
        if (buffer.isEmpty) bufferStart = i;
        buffer.write(word);
      } else {
        emit(word, role, i);
      }
      i = j;
      continue;
    }

    if (_operatorChars.contains(char)) {
      emit(char, AstryxSyntaxToken.operator, i);
      i++;
      continue;
    }

    if (_punctuationChars.contains(char)) {
      emit(char, AstryxSyntaxToken.punctuation, i);
      i++;
      continue;
    }

    if (buffer.isEmpty) bufferStart = i;
    buffer.write(char);
    i++;
  }

  flushPlain();
  return tokens;
}

/// Whether the next non-space character at [from] opens an argument list.
bool _peekIsCall(String source, int from) {
  var i = from;
  while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
    i++;
  }
  return i < source.length && source[i] == '(';
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

bool _isWordChar(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) || // A-Z
      (code >= 0x61 && code <= 0x7A) || // a-z
      code == 0x5F; // _
}

/// The tokens of `[start, end)` of [source], positioned as they are in the
/// whole of it.
///
/// For the completion engine, which works one statement at a time but reports
/// offsets into the document the editor is holding.
List<SqlToken> tokenizeSqlRange(String source, int start, int end) {
  final from = start.clamp(0, source.length);
  final to = end.clamp(from, source.length);
  return <SqlToken>[
    for (final token in tokenizeSql(source.substring(from, to)))
      SqlToken(token.text, token.token, token.start + from),
  ];
}
