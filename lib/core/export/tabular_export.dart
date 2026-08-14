/// Turns rows into text, in whichever of the [ExportFormat]s was asked for.
///
/// Pure: no files, no widgets, no `dart:io`. The whole point of keeping it that
/// way is that every rule below — how a comma inside a value is quoted, how a
/// blob survives a CSV, what an unknown type becomes — is testable without a
/// connection or a file picker.
///
/// Line endings are `\n` in every format, including CSV. RFC 4180 says CRLF,
/// and every consumer that matters — Excel, Sheets, `csv` in Python, pandas,
/// `COPY` in Postgres — reads LF as well. A file whose line endings depend on
/// which format was picked is worse than one that is consistently readable.
library;

import 'dart:convert';

import '../cell_value.dart';
import 'export_format.dart';

/// A table of rows and the columns to write them in, in order.
///
/// Columns are given rather than derived from the rows: an empty result set
/// still has columns, and a row is a map whose key order is not a contract.
class ExportTable {
  const ExportTable({
    required this.columns,
    required this.rows,
    this.truncated = false,
  });

  static const empty = ExportTable(
    columns: <String>[],
    rows: <RowData>[],
  );

  final List<String> columns;
  final List<RowData> rows;

  /// Whether rows were left behind because a limit was reached. The caller says
  /// so out loud rather than handing over a short file that looks complete.
  final bool truncated;

  bool get isEmpty => rows.isEmpty && columns.isEmpty;
}

/// Encodes [table] as a string.
String encodeTable(ExportTable table, ExportOptions options) {
  final buffer = StringBuffer();
  writeTable(buffer, table, options);
  return buffer.toString();
}

/// Writes [table] into [sink].
///
/// Takes a sink rather than returning a string so a large export can be written
/// straight to a file without a second copy of the whole thing in memory.
void writeTable(StringSink sink, ExportTable table, ExportOptions options) {
  switch (options.format) {
    case ExportFormat.csv:
    case ExportFormat.tsv:
      _writeDelimited(sink, table, options);
    case ExportFormat.json:
      _writeJson(sink, table, options);
    case ExportFormat.jsonl:
      _writeJsonLines(sink, table);
    case ExportFormat.sql:
      _writeSqlInserts(sink, table, options);
    case ExportFormat.markdown:
      _writeMarkdown(sink, table, options);
  }
}

// --- CSV and TSV -------------------------------------------------------------

void _writeDelimited(StringSink sink, ExportTable table, ExportOptions options) {
  final delimiter = options.format.delimiter;
  // Written as an escape: an invisible character in a source file is one nobody
  // can see is there.
  if (options.byteOrderMark) sink.write('\uFEFF');

  if (options.includeHeader && table.columns.isNotEmpty) {
    sink.writeln(
      table.columns.map((c) => _quoteField(c, delimiter)).join(delimiter),
    );
  }
  for (final row in table.rows) {
    sink.writeln(
      table.columns
          .map(
            (column) => _quoteField(
              _plainText(row[column] ?? const NullCell(), options),
              delimiter,
            ),
          )
          .join(delimiter),
    );
  }
}

/// Quotes a field only where it has to be quoted, per RFC 4180.
///
/// Also quotes a value with leading or trailing whitespace: unquoted, a reader
/// is free to trim it, and " 007" arriving as "007" is a silent data change.
String _quoteField(String value, String delimiter) {
  final needsQuotes =
      value.contains(delimiter) ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r') ||
      value != value.trim();
  if (!needsQuotes) return value;
  return '"${value.replaceAll('"', '""')}"';
}

// --- JSON --------------------------------------------------------------------

void _writeJson(StringSink sink, ExportTable table, ExportOptions options) {
  final maps = <Map<String, Object?>>[
    for (final row in table.rows) _jsonRow(row, table.columns),
  ];
  sink.write(
    options.prettyJson
        ? const JsonEncoder.withIndent('  ').convert(maps)
        : jsonEncode(maps),
  );
  sink.write('\n');
}

void _writeJsonLines(StringSink sink, ExportTable table) {
  for (final row in table.rows) {
    // Never indented: a JSON Lines record that spans lines is not JSON Lines.
    sink.writeln(jsonEncode(_jsonRow(row, table.columns)));
  }
}

Map<String, Object?> _jsonRow(RowData row, List<String> columns) =>
    <String, Object?>{
      for (final column in columns)
        column: _jsonValue(row[column] ?? const NullCell()),
    };

/// A cell as a JSON value, keeping the type where JSON has one.
///
/// A number stays a number and a null stays null — the reason to export JSON
/// rather than CSV is that the types survive. What JSON has no type for is
/// written as the string a reader can get back: ISO-8601 for a timestamp,
/// base64 for bytes.
Object? _jsonValue(CellValue value) => switch (value) {
  NullCell() => null,
  BoolCell(value: final v) => v,
  NumCell(value: final v) => v,
  StringCell(value: final v) => v,
  TimestampCell(value: final v) => v.toIso8601String(),
  BlobCell(value: final v) => base64Encode(v),
  JsonCell(value: final v) => v,
  UnknownCell(raw: final v) => v?.toString(),
};

// --- SQL ---------------------------------------------------------------------

void _writeSqlInserts(
  StringSink sink,
  ExportTable table,
  ExportOptions options,
) {
  if (table.columns.isEmpty) return;
  // A name rather than nothing: a script that says `exported_rows` fails with a
  // clear message, and one with an empty identifier fails with a parse error
  // fifty lines from the cause.
  final name = _sqlIdentifier(options.tableName ?? 'exported_rows');
  final columns = table.columns.map(_sqlIdentifier).join(', ');

  // One statement per row rather than one multi-row VALUES list: every engine
  // takes it, the file can be split anywhere, and a single bad row does not
  // take the rest of the batch with it.
  for (final row in table.rows) {
    final values = table.columns
        .map((column) => _sqlLiteral(row[column] ?? const NullCell()))
        .join(', ');
    sink.writeln('INSERT INTO $name ($columns) VALUES ($values);');
  }
}

/// Double-quoted, which is the SQL standard and what Postgres, SQLite and
/// modern MySQL in ANSI_QUOTES mode all accept. Embedded quotes are doubled.
String _sqlIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

String _sqlLiteral(CellValue value) => switch (value) {
  NullCell() => 'NULL',
  BoolCell(value: final v) => v ? 'TRUE' : 'FALSE',
  NumCell(value: final v) => v.toString(),
  StringCell(value: final v) => _sqlString(v),
  TimestampCell(value: final v) => _sqlString(v.toIso8601String()),
  // A hex literal rather than base64: `X'...'` is bytes to the database, and a
  // base64 string would arrive as text that happens to look like base64.
  BlobCell(value: final v) => "X'${_hex(v)}'",
  JsonCell(value: final v) => _sqlString(jsonEncode(v)),
  UnknownCell(raw: final v) => v == null ? 'NULL' : _sqlString(v.toString()),
};

String _sqlString(String value) => "'${value.replaceAll("'", "''")}'";

String _hex(List<int> bytes) => <String>[
  for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
].join();

// --- Markdown ----------------------------------------------------------------

void _writeMarkdown(StringSink sink, ExportTable table, ExportOptions options) {
  if (table.columns.isEmpty) return;
  sink.writeln('| ${table.columns.map(_markdownCell).join(' | ')} |');
  sink.writeln('| ${table.columns.map((_) => '---').join(' | ')} |');
  for (final row in table.rows) {
    sink.writeln(
      '| '
      '${table.columns.map((c) => _markdownCell(_plainText(row[c] ?? const NullCell(), options))).join(' | ')}'
      ' |',
    );
  }
}

/// A pipe would end the cell and a newline would end the row, so both are
/// neutralised — the second as `<br>`, because markdown tables cannot hold a
/// real line break and dropping it would join two lines into one word.
String _markdownCell(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('|', r'\|')
    .replaceAll('\r\n', '<br>')
    .replaceAll('\n', '<br>')
    .replaceAll('\r', '<br>');

// --- Shared ------------------------------------------------------------------

/// A cell as plain text, for the formats that have only text.
///
/// Not [CellValue.display]: that is written for a table cell on screen, where
/// `<blob 12B>` is the right thing to show and the wrong thing to save. An
/// export has to be something a reader can get the value back out of, so bytes
/// become base64 rather than a description of themselves.
String _plainText(CellValue value, ExportOptions options) => switch (value) {
  NullCell() => options.nullText,
  BlobCell(value: final v) => base64Encode(v),
  JsonCell(value: final v) => jsonEncode(v),
  _ => value.display(),
};
