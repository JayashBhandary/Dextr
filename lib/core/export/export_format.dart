/// What an export can be, and what the caller may choose about it.
///
/// Export in this application comes in two halves, and they are different jobs
/// rather than two settings of one:
///
///  * **Structured** — rows and columns turned into a text format that keeps
///    the structure: CSV for a spreadsheet, JSON for a script, SQL for another
///    database. That is [ExportFormat] and everything in `tabular_export.dart`.
///  * **Unstructured** — the bytes as they are, with no interpretation: an
///    object out of a bucket, a query saved as a `.sql` file, a preview written
///    to disk. That has no format to pick, only a destination, and it goes
///    through `ExportService` directly.
///
/// Keeping the two apart is the point. A bucket full of JPEGs has no columns to
/// name, and a result set has no meaningful raw form.
library;

/// A text format a table of rows can be written as.
enum ExportFormat {
  /// Comma-separated, quoted per RFC 4180. What a spreadsheet expects.
  csv,

  /// Tab-separated. Worth having because a tab almost never appears inside a
  /// value, so a TSV of messy text needs far less quoting than a CSV of it.
  tsv,

  /// One JSON array of objects. What a script wants.
  json,

  /// One JSON object per line. What a stream, a log pipeline or `jq` wants,
  /// and the only one of these that can be appended to.
  jsonl,

  /// `INSERT` statements, for moving rows into another database.
  sql,

  /// A markdown table, for pasting into a ticket or a document.
  markdown,
}

/// Everything about a format that the encoder and the UI both need.
extension ExportFormatInfo on ExportFormat {
  /// The name shown to the user.
  String get label => switch (this) {
    ExportFormat.csv => 'CSV',
    ExportFormat.tsv => 'TSV',
    ExportFormat.json => 'JSON',
    ExportFormat.jsonl => 'JSON Lines',
    ExportFormat.sql => 'SQL inserts',
    ExportFormat.markdown => 'Markdown table',
  };

  /// What the saved file is called, without the dot.
  String get fileExtension => switch (this) {
    ExportFormat.csv => 'csv',
    ExportFormat.tsv => 'tsv',
    ExportFormat.json => 'json',
    ExportFormat.jsonl => 'jsonl',
    ExportFormat.sql => 'sql',
    ExportFormat.markdown => 'md',
  };

  /// One line on what this format is for, shown beside the choice.
  String get description => switch (this) {
    ExportFormat.csv => 'Opens in a spreadsheet. Quoted per RFC 4180.',
    ExportFormat.tsv => 'Tab-separated. Less quoting than CSV for messy text.',
    ExportFormat.json => 'One array of objects, with real JSON types.',
    ExportFormat.jsonl => 'One object per line, for streams and jq.',
    ExportFormat.sql => 'INSERT statements, to load into another database.',
    ExportFormat.markdown => 'A table to paste into a document or a ticket.',
  };

  /// Whether values are separated by a single character, and so whether
  /// [delimiter], a header row and a null placeholder mean anything.
  bool get isDelimited =>
      this == ExportFormat.csv || this == ExportFormat.tsv;

  /// The separator between values, for the delimited formats.
  String get delimiter => switch (this) {
    ExportFormat.csv => ',',
    ExportFormat.tsv => '\t',
    _ => '',
  };

  /// Whether a row of column names is optional. It is not for markdown — a
  /// markdown table without a header row is not a table — and meaningless for
  /// the rest, which name every column on every row.
  bool get supportsHeader => isDelimited;

  /// Whether the format has to write *something* where a value is null, and so
  /// whether [ExportOptions.nullText] applies. JSON and SQL have a null of
  /// their own; a delimited file and a markdown cell do not.
  bool get supportsNullText => isDelimited || this == ExportFormat.markdown;

  /// Whether the output can be indented without changing what it means.
  bool get supportsPretty => this == ExportFormat.json;

  /// Whether the export needs to be told what the rows are called.
  bool get needsTableName => this == ExportFormat.sql;
}

/// The choices a structured export offers.
///
/// Deliberately small: every field here is one the output is wrong without for
/// somebody. A knob that only changes how the file looks does not belong.
class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.csv,
    this.includeHeader = true,
    this.nullText = '',
    this.prettyJson = true,
    this.tableName,
    this.byteOrderMark = false,
  });

  final ExportFormat format;

  /// Whether a delimited file starts with a row of column names.
  final bool includeHeader;

  /// What stands in for SQL NULL where the format has no null of its own.
  ///
  /// Empty by default, which is what a spreadsheet shows for a blank cell. Set
  /// it to `NULL` or `\N` when the file is going somewhere that has to tell an
  /// empty string from a missing value — the distinction a database tool must
  /// never quietly lose.
  final String nullText;

  /// Whether JSON is indented. Off makes the file smaller; on makes it
  /// readable, which is usually why someone exported JSON rather than JSONL.
  final bool prettyJson;

  /// The table the `INSERT` statements name. Null falls back to a placeholder,
  /// because a script with no table name at least fails loudly.
  final String? tableName;

  /// Whether to prefix the file with a UTF-8 byte-order mark.
  ///
  /// Only for the delimited formats, and only because Excel on Windows reads a
  /// UTF-8 CSV as the local code page without one, which turns every non-ASCII
  /// name into mojibake. Nothing else wants it.
  final bool byteOrderMark;

  ExportOptions copyWith({
    ExportFormat? format,
    bool? includeHeader,
    String? nullText,
    bool? prettyJson,
    String? tableName,
    bool clearTableName = false,
    bool? byteOrderMark,
  }) => ExportOptions(
    format: format ?? this.format,
    includeHeader: includeHeader ?? this.includeHeader,
    nullText: nullText ?? this.nullText,
    prettyJson: prettyJson ?? this.prettyJson,
    tableName: clearTableName ? null : (tableName ?? this.tableName),
    byteOrderMark: byteOrderMark ?? this.byteOrderMark,
  );
}
