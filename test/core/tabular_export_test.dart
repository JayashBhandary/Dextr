import 'dart:convert';
import 'dart:typed_data';

import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/export/export_format.dart';
import 'package:dextr/core/export/tabular_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an export actually contains.
///
/// These are the tests that matter most in the whole feature: an export is the
/// point at which data leaves this tool for a spreadsheet, a script or another
/// database, and a value that changes on the way out — a comma that splits a
/// field, an empty string that arrives as NULL, bytes described instead of
/// encoded — is a silent corruption nobody notices until much later.
void main() {
  final table = ExportTable(
    columns: const <String>['id', 'name', 'ratio', 'ok', 'seen', 'meta', 'raw'],
    rows: <RowData>[
      <String, CellValue>{
        'id': const NumCell(1),
        'name': const StringCell('Intro'),
        'ratio': const NumCell(0.5),
        'ok': const BoolCell(true),
        'seen': TimestampCell(DateTime.utc(2026, 8, 14, 9, 30)),
        'meta': const JsonCell(<String, Object?>{'tags': <String>['a']}),
        'raw': BlobCell(Uint8List.fromList(<int>[0, 255, 16])),
      },
      <String, CellValue>{
        'id': const NumCell(2),
        'name': const NullCell(),
        'ratio': const NullCell(),
        'ok': const BoolCell(false),
        'seen': const NullCell(),
        'meta': const NullCell(),
        'raw': const NullCell(),
      },
    ],
  );

  String encode(ExportFormat format, {ExportOptions? options}) => encodeTable(
    table,
    (options ?? const ExportOptions()).copyWith(format: format),
  );

  group('CSV', () {
    test('writes a header and one line per row', () {
      final lines = encode(ExportFormat.csv).trim().split('\n');

      expect(lines.first, 'id,name,ratio,ok,seen,meta,raw');
      expect(lines.length, 3);
      expect(lines[1], startsWith('1,Intro,0.5,true,2026-08-14T09:30:00.000Z,'));
    });

    test('drops the header when asked', () {
      final lines = encode(
        ExportFormat.csv,
        options: const ExportOptions(includeHeader: false),
      ).trim().split('\n');

      expect(lines.length, 2);
      expect(lines.first, startsWith('1,Intro'));
    });

    test('quotes only what has to be quoted, and doubles inner quotes', () {
      const awkward = ExportTable(
        columns: <String>['a', 'b', 'c', 'd'],
        rows: <RowData>[
          <String, CellValue>{
            'a': StringCell('plain'),
            'b': StringCell('has,comma'),
            'c': StringCell('say "hi"'),
            'd': StringCell('two\nlines'),
          },
        ],
      );

      final line = encodeTable(
        awkward,
        const ExportOptions(includeHeader: false),
      ).trim();

      expect(line, 'plain,"has,comma","say ""hi""","two\nlines"');
    });

    test('quotes a value with edge whitespace, which a reader may trim', () {
      const padded = ExportTable(
        columns: <String>['code'],
        rows: <RowData>[
          <String, CellValue>{'code': StringCell(' 007')},
        ],
      );

      expect(
        encodeTable(padded, const ExportOptions(includeHeader: false)).trim(),
        '" 007"',
      );
    });

    test('a tab does not need quoting in a TSV, and a comma does not either', () {
      const commas = ExportTable(
        columns: <String>['a'],
        rows: <RowData>[
          <String, CellValue>{'a': StringCell('has,comma')},
        ],
      );

      expect(
        encodeTable(
          commas,
          const ExportOptions(
            format: ExportFormat.tsv,
            includeHeader: false,
          ),
        ).trim(),
        'has,comma',
      );
    });

    test('NULL is the placeholder, and an empty string is not', () {
      const mixed = ExportTable(
        columns: <String>['missing', 'blank'],
        rows: <RowData>[
          <String, CellValue>{
            'missing': NullCell(),
            'blank': StringCell(''),
          },
        ],
      );

      // Default: both look blank, which is what a spreadsheet wants.
      expect(
        encodeTable(mixed, const ExportOptions(includeHeader: false)).trim(),
        ',',
      );
      // And with a placeholder set they are told apart, which is the point of
      // having the setting at all.
      expect(
        encodeTable(
          mixed,
          const ExportOptions(includeHeader: false, nullText: r'\N'),
        ).trim(),
        r'\N,',
      );
    });

    test('bytes come out as base64, not as a description of themselves', () {
      final line = encode(
        ExportFormat.csv,
        options: const ExportOptions(includeHeader: false),
      ).split('\n').first;

      expect(line, contains(base64Encode(<int>[0, 255, 16])));
      expect(line, isNot(contains('blob')));
    });

    test('the byte-order mark is written only when asked', () {
      expect(encode(ExportFormat.csv).codeUnitAt(0), isNot(0xFEFF));
      expect(
        encode(
          ExportFormat.csv,
          options: const ExportOptions(byteOrderMark: true),
        ).codeUnitAt(0),
        0xFEFF,
      );
    });
  });

  group('JSON', () {
    test('keeps the types JSON has, and stringifies the ones it does not', () {
      final decoded =
          jsonDecode(encode(ExportFormat.json)) as List<Object?>;
      final first = decoded.first! as Map<String, Object?>;

      expect(first['id'], 1);
      expect(first['ratio'], 0.5);
      expect(first['ok'], true);
      expect(first['name'], 'Intro');
      expect(first['seen'], '2026-08-14T09:30:00.000Z');
      expect(first['meta'], <String, Object?>{'tags': <String>['a']});
      expect(first['raw'], base64Encode(<int>[0, 255, 16]));

      // A null stays null rather than becoming the empty string: the reason to
      // pick JSON over CSV is that the difference survives.
      final second = decoded[1]! as Map<String, Object?>;
      expect(second['name'], isNull);
      expect(second.containsKey('name'), isTrue);
    });

    test('indents when asked and not otherwise', () {
      expect(encode(ExportFormat.json), contains('\n  {'));
      expect(
        encode(
          ExportFormat.json,
          options: const ExportOptions(prettyJson: false),
        ),
        isNot(contains('\n  ')),
      );
    });

    test('JSON Lines is one compact object per line', () {
      final lines = encode(ExportFormat.jsonl).trim().split('\n');

      expect(lines.length, 2);
      for (final line in lines) {
        expect(jsonDecode(line), isA<Map<String, Object?>>());
      }
    });
  });

  group('SQL', () {
    test('one INSERT per row, with the table and identifiers quoted', () {
      final lines = encode(
        ExportFormat.sql,
        options: const ExportOptions(tableName: 'public.tracks'),
      ).trim().split('\n');

      expect(lines.length, 2);
      expect(
        lines.first,
        startsWith(
          'INSERT INTO "public.tracks" '
          '("id", "name", "ratio", "ok", "seen", "meta", "raw") VALUES (',
        ),
      );
      expect(lines.first, endsWith(');'));
    });

    test('literals are typed: NULL bare, strings quoted, bytes hex', () {
      final rows = encode(ExportFormat.sql).trim().split('\n');

      expect(rows.first, contains("'Intro'"));
      expect(rows.first, contains("X'00ff10'"));
      expect(rows.first, contains('TRUE'));
      // The second row is nulls, and they must not be the string 'NULL'.
      expect(rows[1], contains('VALUES (2, NULL, NULL, FALSE, NULL'));
      expect(rows[1], isNot(contains("'NULL'")));
    });

    test('an apostrophe is doubled rather than ending the literal', () {
      const quoted = ExportTable(
        columns: <String>['name'],
        rows: <RowData>[
          <String, CellValue>{'name': StringCell("O'Hara")},
        ],
      );

      expect(
        encodeTable(quoted, const ExportOptions(format: ExportFormat.sql)),
        contains("('O''Hara')"),
      );
    });

    test('a table name with a quote in it cannot break out of the identifier', () {
      final rows = encodeTable(
        table,
        const ExportOptions(format: ExportFormat.sql, tableName: 'a"b'),
      );

      expect(rows, contains('INSERT INTO "a""b" ('));
    });
  });

  group('markdown', () {
    test('a header, a rule, and one row each', () {
      final lines = encode(ExportFormat.markdown).trim().split('\n');

      expect(lines.first, '| id | name | ratio | ok | seen | meta | raw |');
      expect(lines[1], '| --- | --- | --- | --- | --- | --- | --- |');
      expect(lines.length, 4);
    });

    test('a pipe is escaped and a newline becomes a break', () {
      const awkward = ExportTable(
        columns: <String>['text'],
        rows: <RowData>[
          <String, CellValue>{'text': StringCell('a|b\nc')},
        ],
      );

      final lines = encodeTable(
        awkward,
        const ExportOptions(format: ExportFormat.markdown),
      ).trim().split('\n');

      // Still three lines, not four: a raw newline would have started a row.
      expect(lines.length, 3);
      expect(lines.last, r'| a\|b<br>c |');
    });
  });

  test('a table with no columns produces nothing rather than a broken file', () {
    for (final format in ExportFormat.values) {
      expect(
        encodeTable(ExportTable.empty, ExportOptions(format: format)).trim(),
        anyOf('', '[]'),
        reason: '${format.name} should not invent structure',
      );
    }
  });

  test('a column the row does not have is null, not missing', () {
    const ragged = ExportTable(
      columns: <String>['a', 'b'],
      rows: <RowData>[
        <String, CellValue>{'a': NumCell(1)},
      ],
    );

    expect(
      encodeTable(ragged, const ExportOptions(includeHeader: false)).trim(),
      '1,',
    );
    expect(
      jsonDecode(
        encodeTable(ragged, const ExportOptions(format: ExportFormat.jsonl)),
      ),
      <String, Object?>{'a': 1, 'b': null},
    );
  });

  test('every format names a file extension and describes itself', () {
    for (final format in ExportFormat.values) {
      expect(format.fileExtension, isNotEmpty);
      expect(format.label, isNotEmpty);
      expect(format.description, isNotEmpty);
    }
  });
}
