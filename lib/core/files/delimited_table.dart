/// Reading a CSV or a TSV back into rows and columns.
///
/// The counterpart of `core/export/tabular_export.dart`, and deliberately not
/// the same code read backwards: writing needs to know when to quote, reading
/// needs to know what a quote *meant*, and the two rule sets are different
/// enough that sharing one would make both harder to follow.
///
/// A hand-written scanner rather than a package: the whole of RFC 4180 is the
/// loop below — a quoted field ends at a quote that is not doubled, everything
/// else ends at a delimiter or a line break — and a dependency for that is a
/// dependency to keep up to date for no gain.
library;

/// A parsed delimited file.
class DelimitedTable {
  const DelimitedTable({
    required this.columns,
    required this.rows,
    required this.delimiter,
    this.truncated = false,
  });

  static const empty = DelimitedTable(
    columns: <String>[],
    rows: <List<String>>[],
    delimiter: ',',
  );

  /// The first line, or generated names when the file has no header.
  final List<String> columns;

  /// Every row after the header, each padded to the width of [columns].
  final List<List<String>> rows;

  /// Which character separated the values. Reported because the reader guesses
  /// it, and a guess the reader cannot see is a guess nobody can check.
  final String delimiter;

  /// Whether reading stopped at the row cap rather than at the end of the text.
  final bool truncated;

  bool get isEmpty => columns.isEmpty && rows.isEmpty;
}

/// Parses [text] as delimited data.
///
/// [delimiter] is guessed when not given. [maxRows] caps the result: a preview
/// of a million-row CSV is the first screen of it, and building a table widget
/// for the rest would freeze the frame that opened the dialog.
DelimitedTable parseDelimited(
  String text, {
  String? delimiter,
  bool hasHeader = true,
  int maxRows = 500,
}) {
  if (text.isEmpty) return DelimitedTable.empty;
  final separator = delimiter ?? sniffDelimiter(text);
  final records = <List<String>>[];
  var truncated = false;

  final field = StringBuffer();
  var record = <String>[];
  var quoted = false;
  var index = 0;

  void endField() {
    record.add(field.toString());
    field.clear();
  }

  bool endRecord() {
    endField();
    // A trailing newline is not an empty last row.
    final blank = record.length == 1 && record.single.isEmpty;
    if (!blank) records.add(record);
    record = <String>[];
    // One over the cap, so the header does not eat one of the rows the caller
    // asked for.
    if (records.length > maxRows + (hasHeader ? 1 : 0)) {
      truncated = true;
      return false;
    }
    return true;
  }

  while (index < text.length) {
    final char = text[index];

    if (quoted) {
      if (char == '"') {
        // A doubled quote is one quote; a single one closes the field.
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index++;
        continue;
      }
      field.write(char);
      index++;
      continue;
    }

    if (char == '"' && field.isEmpty) {
      quoted = true;
      index++;
      continue;
    }
    if (char == separator) {
      endField();
      index++;
      continue;
    }
    if (char == '\r' || char == '\n') {
      // CRLF is one break, not two.
      final skip = char == '\r' && index + 1 < text.length && text[index + 1] == '\n'
          ? 2
          : 1;
      if (!endRecord()) break;
      index += skip;
      continue;
    }
    field.write(char);
    index++;
  }

  // Whatever is left when the text ends without a final break.
  if (!truncated && (field.isNotEmpty || record.isNotEmpty)) endRecord();
  if (records.isEmpty) return DelimitedTable.empty;

  final header = hasHeader ? records.removeAt(0) : null;
  final width = <int>[
    header?.length ?? 0,
    for (final row in records) row.length,
  ].reduce((a, b) => a > b ? a : b);

  final columns = <String>[
    for (var i = 0; i < width; i++)
      // A header cell can be blank in a real file; a column with no name at all
      // cannot be referred to, so it gets its position instead.
      (i < (header?.length ?? 0) && header![i].trim().isNotEmpty)
          ? header[i]
          : 'column ${i + 1}',
  ];

  return DelimitedTable(
    columns: columns,
    // Padded to the header's width: a short row is a ragged file, not a reason
    // for the table to throw on a missing cell.
    rows: <List<String>>[
      for (final row in records.take(maxRows))
        <String>[
          for (var i = 0; i < width; i++) i < row.length ? row[i] : '',
        ],
    ],
    delimiter: separator,
    truncated: truncated || records.length > maxRows,
  );
}

/// Guesses the delimiter from the first few lines.
///
/// Counted outside quotes and compared *per line*: the winner is the candidate
/// that appears the same number of times on every line, because that is what a
/// column separator does and what a comma inside prose does not.
String sniffDelimiter(String text, {int sampleLines = 5}) {
  const candidates = <String>[',', '\t', ';', '|'];
  final lines = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length && lines.length < sampleLines; i++) {
    final char = text[i];
    if (char == '"') quoted = !quoted;
    if (!quoted && (char == '\n' || char == '\r')) {
      if (buffer.isNotEmpty) lines.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty && lines.length < sampleLines) {
    lines.add(buffer.toString());
  }
  if (lines.isEmpty) return ',';

  var best = ',';
  var bestScore = -1;
  for (final candidate in candidates) {
    final counts = lines.map((line) => _countOutsideQuotes(line, candidate));
    final first = counts.first;
    if (first == 0) continue;
    final consistent = counts.every((count) => count == first);
    // Consistency beats frequency: two commas on every line beats nine on one.
    final score = (consistent ? 1000 : 0) + first;
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

int _countOutsideQuotes(String line, String needle) {
  var count = 0;
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && char == needle) count++;
  }
  return count;
}
