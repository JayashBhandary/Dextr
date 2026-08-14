/// Reading `.docx` and `.xlsx` without a rendering engine.
///
/// Both are Open Packaging Convention files: a zip of XML parts. A `.docx`
/// keeps its text in `word/document.xml`; a `.xlsx` keeps its cells in
/// `xl/worksheets/sheetN.xml` and, because the same string is usually repeated,
/// most of its text in `xl/sharedStrings.xml`. Unzip, walk the XML, and there is
/// the content — no Office, no native library.
///
/// What this deliberately does not do is *lay out* the document. A `.docx`
/// preview here is the words in order, not the page; a `.xlsx` preview is the
/// values, not the formatting or the formulae. That is the honest limit of
/// reading a format rather than rendering it, and it is what a database tool
/// looking at a file in a bucket actually needs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A `.docx`, as the text in it.
class WordDocument {
  const WordDocument({required this.paragraphs, this.truncated = false});

  /// One entry per paragraph, in reading order. Empty paragraphs are kept:
  /// they are the blank lines between sections.
  final List<String> paragraphs;

  /// Whether reading stopped at the paragraph cap.
  final bool truncated;

  bool get isEmpty => paragraphs.every((p) => p.trim().isEmpty);

  /// The whole document as plain text.
  String get text => paragraphs.join('\n\n');

  /// A word count, for the facts beside the preview.
  int get words => paragraphs
      .expand((p) => p.split(RegExp(r'\s+')))
      .where((w) => w.trim().isNotEmpty)
      .length;
}

/// A `.xlsx`, as the values in one or more sheets.
class Workbook {
  const Workbook({required this.sheets});

  final List<Worksheet> sheets;

  bool get isEmpty => sheets.every((s) => s.rows.isEmpty);
}

/// One sheet: a dense grid of display strings.
class Worksheet {
  const Worksheet({
    required this.name,
    required this.rows,
    this.truncated = false,
  });

  final String name;

  /// Row-major, each row padded to the width of the widest one.
  final List<List<String>> rows;

  /// Whether reading stopped at the row cap.
  final bool truncated;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;
}

/// Thrown when the bytes are not the format they claimed to be.
class OoxmlException implements Exception {
  const OoxmlException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads the paragraphs of a `.docx`.
WordDocument readDocx(Uint8List bytes, {int maxParagraphs = 400}) {
  final archive = _unzip(bytes);
  final document = _partNamed(archive, 'word/document.xml');
  if (document == null) {
    throw const OoxmlException(
      'No word/document.xml in this file, so it is not a .docx.',
    );
  }

  final body = XmlDocument.parse(utf8.decode(document, allowMalformed: true));
  final paragraphs = <String>[];
  var truncated = false;

  for (final node in body.findAllElements('w:p')) {
    if (paragraphs.length >= maxParagraphs) {
      truncated = true;
      break;
    }
    paragraphs.add(_paragraphText(node));
  }

  // Trailing blank paragraphs are the end of the file, not content.
  while (paragraphs.isNotEmpty && paragraphs.last.trim().isEmpty) {
    paragraphs.removeLast();
  }
  return WordDocument(paragraphs: paragraphs, truncated: truncated);
}

/// The text of one `w:p`, with the breaks and tabs it contains.
String _paragraphText(XmlElement paragraph) {
  final buffer = StringBuffer();
  for (final node in paragraph.descendantElements) {
    switch (node.name.qualified) {
      case 'w:t':
        buffer.write(node.innerText);
      case 'w:tab':
        buffer.write('\t');
      case 'w:br':
      case 'w:cr':
        buffer.write('\n');
      // `w:delText` is deleted text under tracked changes. Skipped on purpose:
      // showing it would put words in the document that its author removed.
    }
  }
  return buffer.toString();
}

/// Reads the sheets of a `.xlsx`.
///
/// [maxRows] and [maxColumns] cap each sheet. A spreadsheet with a hundred
/// thousand rows is common, and a table widget that does not virtualise cannot
/// be handed one.
Workbook readXlsx(
  Uint8List bytes, {
  int maxRows = 500,
  int maxColumns = 40,
  int maxSheets = 12,
}) {
  final archive = _unzip(bytes);
  final workbookPart = _partNamed(archive, 'xl/workbook.xml');
  if (workbookPart == null) {
    throw const OoxmlException(
      'No xl/workbook.xml in this file, so it is not a .xlsx.',
    );
  }

  final shared = _sharedStrings(archive);
  final workbook = XmlDocument.parse(
    utf8.decode(workbookPart, allowMalformed: true),
  );
  final relations = _sheetRelations(archive);

  final sheets = <Worksheet>[];
  for (final sheet in workbook.findAllElements('sheet')) {
    if (sheets.length >= maxSheets) break;
    final name = sheet.getAttribute('name') ?? 'Sheet ${sheets.length + 1}';
    final id = sheet.getAttribute('r:id');
    final target = id == null ? null : relations[id];
    final part = target == null
        ? null
        // A relationship target is relative to `xl/`, and may or may not say so.
        : _partNamed(archive, _resolveSheetPath(target)) ??
              _partNamed(archive, target);
    if (part == null) continue;

    sheets.add(
      _readSheet(
        name: name,
        xml: utf8.decode(part, allowMalformed: true),
        shared: shared,
        maxRows: maxRows,
        maxColumns: maxColumns,
      ),
    );
  }

  // A workbook whose relationships could not be followed still has its sheets
  // on disk, in order; falling back to those beats showing nothing.
  if (sheets.isEmpty) {
    final parts = archive.files
        .where((f) => f.name.startsWith('xl/worksheets/sheet'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final part in parts.take(maxSheets)) {
      final data = part.readBytes();
      if (data == null) continue;
      sheets.add(
        _readSheet(
          name: 'Sheet ${sheets.length + 1}',
          xml: utf8.decode(data, allowMalformed: true),
          shared: shared,
          maxRows: maxRows,
          maxColumns: maxColumns,
        ),
      );
    }
  }

  return Workbook(sheets: sheets);
}

Worksheet _readSheet({
  required String name,
  required String xml,
  required List<String> shared,
  required int maxRows,
  required int maxColumns,
}) {
  final document = XmlDocument.parse(xml);
  final rows = <List<String>>[];
  var truncated = false;
  var width = 0;

  for (final row in document.findAllElements('row')) {
    if (rows.length >= maxRows) {
      truncated = true;
      break;
    }
    // Addressed by cell reference rather than by position: a spreadsheet omits
    // empty cells, so the third `<c>` in a row is not the third column.
    final cells = <int, String>{};
    for (final cell in row.findElements('c')) {
      final column = _columnIndex(cell.getAttribute('r'));
      if (column == null || column >= maxColumns) continue;
      cells[column] = _cellText(cell, shared);
    }
    final rowWidth = cells.isEmpty ? 0 : cells.keys.reduce((a, b) => a > b ? a : b) + 1;
    if (rowWidth > width) width = rowWidth;
    rows.add(<String>[
      for (var i = 0; i < rowWidth; i++) cells[i] ?? '',
    ]);
  }

  return Worksheet(
    name: name,
    rows: <List<String>>[
      for (final row in rows)
        <String>[for (var i = 0; i < width; i++) i < row.length ? row[i] : ''],
    ],
    truncated: truncated,
  );
}

/// One cell's value as a string.
///
/// `t="s"` means the value is an index into the shared strings; `t="inlineStr"`
/// means it is in the cell; anything else is a literal in `<v>` — a number, a
/// serial date, a boolean. Numbers are left exactly as stored: guessing that
/// `45000` is a date, or rounding it to look nicer, would be inventing data.
String _cellText(XmlElement cell, List<String> shared) {
  final type = cell.getAttribute('t');
  if (type == 's') {
    final index = int.tryParse(cell.findElements('v').firstOrNull?.innerText ?? '');
    if (index == null || index < 0 || index >= shared.length) return '';
    return shared[index];
  }
  if (type == 'inlineStr') {
    return cell
        .findElements('is')
        .expand((is_) => is_.findAllElements('t'))
        .map((t) => t.innerText)
        .join();
  }
  if (type == 'b') {
    return cell.findElements('v').firstOrNull?.innerText == '1'
        ? 'TRUE'
        : 'FALSE';
  }
  if (type == 'e') return cell.findElements('v').firstOrNull?.innerText ?? '';
  return cell.findElements('v').firstOrNull?.innerText ?? '';
}

/// The zero-based column of an A1-style reference: `C7` → 2.
int? _columnIndex(String? reference) {
  if (reference == null || reference.isEmpty) return null;
  var index = 0;
  var seen = 0;
  for (final unit in reference.codeUnits) {
    if (unit >= 0x41 && unit <= 0x5A) {
      index = index * 26 + (unit - 0x40);
      seen++;
      continue;
    }
    if (unit >= 0x61 && unit <= 0x7A) {
      index = index * 26 + (unit - 0x60);
      seen++;
      continue;
    }
    break;
  }
  return seen == 0 ? null : index - 1;
}

List<String> _sharedStrings(Archive archive) {
  final part = _partNamed(archive, 'xl/sharedStrings.xml');
  if (part == null) return const <String>[];
  final document = XmlDocument.parse(utf8.decode(part, allowMalformed: true));
  return <String>[
    // Every `<t>` inside one `<si>` joined: a string with mixed formatting is
    // split into runs, and joining them back is what the cell actually says.
    for (final si in document.findAllElements('si'))
      si.findAllElements('t').map((t) => t.innerText).join(),
  ];
}

/// Relationship id → part path, from `xl/_rels/workbook.xml.rels`.
Map<String, String> _sheetRelations(Archive archive) {
  final part = _partNamed(archive, 'xl/_rels/workbook.xml.rels');
  if (part == null) return const <String, String>{};
  final document = XmlDocument.parse(utf8.decode(part, allowMalformed: true));
  final relations = <String, String>{};
  for (final relation in document.findAllElements('Relationship')) {
    final id = relation.getAttribute('Id');
    if (id == null) continue;
    relations[id] = relation.getAttribute('Target') ?? '';
  }
  return relations;
}

String _resolveSheetPath(String target) {
  final trimmed = target.startsWith('/') ? target.substring(1) : target;
  return trimmed.startsWith('xl/') ? trimmed : 'xl/$trimmed';
}

Archive _unzip(Uint8List bytes) {
  // Checked before decoding, because the decoder answers a garbage buffer with
  // an *empty archive* rather than an error — and an empty archive would be
  // reported below as "no word/document.xml", which sends the reader looking
  // for the wrong problem. The likeliest cause by far is a truncated download:
  // a zip keeps its index at the end, so the first few megabytes of one cannot
  // be opened at all.
  const message =
      'This file could not be opened as a zip. It may be incomplete — a zip is '
      'read from its end — or not an Office document at all.';
  if (bytes.length < 4 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4B) {
    throw const OoxmlException(message);
  }
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.files.isEmpty) throw const OoxmlException(message);
    return archive;
  } on OoxmlException {
    rethrow;
  } on Object catch (e) {
    throw OoxmlException('$message ($e)');
  }
}

Uint8List? _partNamed(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file != null) return file.readBytes();
  // Some writers use backslashes or a leading slash in the entry names.
  final lower = name.toLowerCase();
  for (final candidate in archive.files) {
    final normalised = candidate.name
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp('^/'), '')
        .toLowerCase();
    if (normalised == lower) return candidate.readBytes();
  }
  return null;
}
