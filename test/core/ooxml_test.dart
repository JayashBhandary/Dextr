import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dextr/core/files/ooxml.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading a `.docx` and a `.xlsx`.
///
/// The fixtures are built here rather than committed as binaries, so what each
/// test is about is visible in the test: this is the XML Word and Excel write,
/// zipped the way they zip it. A committed `.xlsx` would test the same code and
/// tell a reader nothing about why.
void main() {
  Uint8List zip(Map<String, String> parts) {
    final archive = Archive();
    for (final entry in parts.entries) {
      archive.add(ArchiveFile.string(entry.key, entry.value));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  group('docx', () {
    Uint8List docx(String body) => zip(<String, String>{
      'word/document.xml':
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:body>$body</w:body></w:document>',
    });

    String paragraph(String text) => '<w:p><w:r><w:t>$text</w:t></w:r></w:p>';

    test('the paragraphs come back in order', () {
      final document = readDocx(
        docx('${paragraph('Title')}${paragraph('Then a line.')}'),
      );

      expect(document.paragraphs, <String>['Title', 'Then a line.']);
      expect(document.words, 4);
      expect(document.isEmpty, isFalse);
    });

    test('runs inside one paragraph are joined', () {
      // Word splits a sentence into runs wherever the formatting changes, so a
      // bolded word is its own run and the paragraph is the join of them.
      final document = readDocx(
        docx(
          '<w:p><w:r><w:t>Hello </w:t></w:r>'
          '<w:r><w:t>world</w:t></w:r></w:p>',
        ),
      );

      expect(document.paragraphs.single, 'Hello world');
    });

    test('a break is a newline and a tab is a tab', () {
      final document = readDocx(
        docx('<w:p><w:r><w:t>a</w:t><w:br/><w:t>b</w:t><w:tab/><w:t>c</w:t></w:r></w:p>'),
      );

      expect(document.paragraphs.single, 'a\nb\tc');
    });

    test('text deleted under tracked changes is not shown', () {
      final document = readDocx(
        docx(
          '<w:p><w:r><w:t>kept</w:t></w:r>'
          '<w:del><w:r><w:delText> removed</w:delText></w:r></w:del></w:p>',
        ),
      );

      expect(document.paragraphs.single, 'kept');
    });

    test('trailing empty paragraphs are dropped, inner ones kept', () {
      final document = readDocx(
        docx(
          '${paragraph('one')}<w:p/>${paragraph('two')}<w:p/><w:p/>',
        ),
      );

      expect(document.paragraphs, <String>['one', '', 'two']);
    });

    test('the paragraph cap is reported', () {
      final document = readDocx(
        docx(List<String>.generate(20, (i) => paragraph('p$i')).join()),
        maxParagraphs: 5,
      );

      expect(document.paragraphs, hasLength(5));
      expect(document.truncated, isTrue);
    });

    test('a zip that is not a docx says which part is missing', () {
      expect(
        () => readDocx(zip(<String, String>{'a.txt': 'hello'})),
        throwsA(
          isA<OoxmlException>().having(
            (e) => e.message,
            'message',
            contains('word/document.xml'),
          ),
        ),
      );
    });

    test('bytes that are not a zip blame the truncation, not the format', () {
      expect(
        () => readDocx(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(
          isA<OoxmlException>().having(
            (e) => e.message,
            'message',
            contains('incomplete'),
          ),
        ),
      );
    });
  });

  group('xlsx', () {
    /// A workbook of one sheet, with [sheetXml] as its rows.
    Uint8List xlsx({
      required String sheetXml,
      String sharedStrings = '',
      String sheets =
          '<sheet name="Sales" sheetId="1" r:id="rId1"/>',
      Map<String, String> extra = const <String, String>{},
    }) => zip(<String, String>{
      'xl/workbook.xml':
          '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sheets>$sheets</sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<Relationships>'
          '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
          '<Relationship Id="rId2" Target="worksheets/sheet2.xml"/>'
          '</Relationships>',
      'xl/sharedStrings.xml': '<sst>$sharedStrings</sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData>$sheetXml</sheetData></worksheet>',
      ...extra,
    });

    test('shared strings and numbers land in the right cells', () {
      final workbook = readXlsx(
        xlsx(
          sharedStrings: '<si><t>name</t></si><si><t>Intro</t></si>',
          sheetXml:
              '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>30</v></c></row>'
              '<row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>95.5</v></c></row>',
        ),
      );

      expect(workbook.sheets.single.name, 'Sales');
      expect(workbook.sheets.single.rows, <List<String>>[
        <String>['name', '30'],
        <String>['Intro', '95.5'],
      ]);
    });

    test('an omitted cell leaves its column empty rather than shifting', () {
      // Excel writes no `<c>` at all for an empty cell, so the second `<c>` in
      // this row is column C. Reading by position would put it in B.
      final workbook = readXlsx(
        xlsx(
          sheetXml: '<row r="1"><c r="A1"><v>1</v></c><c r="C1"><v>3</v></c></row>',
        ),
      );

      expect(workbook.sheets.single.rows.single, <String>['1', '', '3']);
    });

    test('a reference past Z is decoded', () {
      final workbook = readXlsx(
        xlsx(sheetXml: '<row r="1"><c r="AB1"><v>28</v></c></row>'),
      );

      final row = workbook.sheets.single.rows.single;
      expect(row, hasLength(28));
      expect(row.last, '28');
    });

    test('rows are padded to the widest one', () {
      final workbook = readXlsx(
        xlsx(
          sheetXml:
              '<row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c></row>'
              '<row r="2"><c r="A2"><v>3</v></c></row>',
        ),
      );

      expect(workbook.sheets.single.rows.last, <String>['3', '']);
    });

    test('an inline string, a boolean and a formula result are all read', () {
      final workbook = readXlsx(
        xlsx(
          sheetXml:
              '<row r="1">'
              '<c r="A1" t="inlineStr"><is><t>inline</t></is></c>'
              '<c r="B1" t="b"><v>1</v></c>'
              '<c r="C1"><f>SUM(A1:B1)</f><v>7</v></c>'
              '</row>',
        ),
      );

      expect(workbook.sheets.single.rows.single, <String>[
        'inline',
        'TRUE',
        // The value, not the formula: what the file says the cell shows.
        '7',
      ]);
    });

    test('a formatted string keeps every run of itself', () {
      final workbook = readXlsx(
        xlsx(
          sharedStrings: '<si><r><t>Total </t></r><r><t>2026</t></r></si>',
          sheetXml: '<row r="1"><c r="A1" t="s"><v>0</v></c></row>',
        ),
      );

      expect(workbook.sheets.single.rows.single.single, 'Total 2026');
    });

    test('several sheets come back in the workbook order, named', () {
      final workbook = readXlsx(
        xlsx(
          sheets:
              '<sheet name="Sales" sheetId="1" r:id="rId1"/>'
              '<sheet name="Costs" sheetId="2" r:id="rId2"/>',
          sheetXml: '<row r="1"><c r="A1"><v>1</v></c></row>',
          extra: <String, String>{
            'xl/worksheets/sheet2.xml':
                '<worksheet><sheetData>'
                '<row r="1"><c r="A1"><v>2</v></c></row>'
                '</sheetData></worksheet>',
          },
        ),
      );

      expect(workbook.sheets.map((s) => s.name), <String>['Sales', 'Costs']);
      expect(workbook.sheets.last.rows.single.single, '2');
    });

    test('the row cap is reported per sheet', () {
      final rows = List<String>.generate(
        30,
        (i) => '<row r="${i + 1}"><c r="A${i + 1}"><v>$i</v></c></row>',
      ).join();

      final workbook = readXlsx(xlsx(sheetXml: rows), maxRows: 4);

      expect(workbook.sheets.single.rows, hasLength(4));
      expect(workbook.sheets.single.truncated, isTrue);
    });

    test('a workbook with no relationships still finds its sheets on disk', () {
      final workbook = readXlsx(
        zip(<String, String>{
          'xl/workbook.xml': '<workbook><sheets><sheet name="Orphan"/></sheets></workbook>',
          'xl/worksheets/sheet1.xml':
              '<worksheet><sheetData>'
              '<row r="1"><c r="A1"><v>9</v></c></row>'
              '</sheetData></worksheet>',
        }),
      );

      expect(workbook.sheets, hasLength(1));
      expect(workbook.sheets.single.rows.single.single, '9');
    });

    test('a zip that is not a xlsx says which part is missing', () {
      expect(
        () => readXlsx(zip(<String, String>{'a.txt': 'hello'})),
        throwsA(
          isA<OoxmlException>().having(
            (e) => e.message,
            'message',
            contains('xl/workbook.xml'),
          ),
        ),
      );
    });
  });
}
