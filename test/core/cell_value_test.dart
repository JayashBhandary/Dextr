import 'dart:convert';
import 'dart:typed_data';

import 'package:dextr/core/cell_value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CellValue.fromDynamic', () {
    test('maps null to NullCell', () {
      expect(CellValue.fromDynamic(null), isA<NullCell>());
    });

    test('maps bool to BoolCell', () {
      expect(CellValue.fromDynamic(true), isA<BoolCell>());
      expect((CellValue.fromDynamic(false) as BoolCell).value, isFalse);
    });

    test('maps int and double to NumCell', () {
      expect((CellValue.fromDynamic(7) as NumCell).value, 7);
      expect((CellValue.fromDynamic(3.5) as NumCell).value, 3.5);
    });

    test('maps DateTime to TimestampCell', () {
      final now = DateTime.utc(2026, 5, 29, 12, 0, 0);
      expect((CellValue.fromDynamic(now) as TimestampCell).value, now);
    });

    test('maps String to StringCell', () {
      expect((CellValue.fromDynamic('hi') as StringCell).value, 'hi');
    });

    test('maps List<int> and Uint8List to BlobCell', () {
      expect(CellValue.fromDynamic(Uint8List.fromList([1, 2, 3])),
          isA<BlobCell>());
      expect(CellValue.fromDynamic(<int>[1, 2, 3]), isA<BlobCell>());
    });

    test('maps Map and List to JsonCell', () {
      expect(CellValue.fromDynamic({'a': 1}), isA<JsonCell>());
      expect(CellValue.fromDynamic([1, 'two']), isA<JsonCell>());
    });

    test('falls back to UnknownCell', () {
      expect(CellValue.fromDynamic(Object()), isA<UnknownCell>());
    });
  });

  group('CellValue.toBindable', () {
    test('null round-trips to null', () {
      expect(const NullCell().toBindable(), isNull);
    });

    test('bool encodes as 1/0', () {
      expect(const BoolCell(true).toBindable(), 1);
      expect(const BoolCell(false).toBindable(), 0);
    });

    test('num and string pass through', () {
      expect(const NumCell(42).toBindable(), 42);
      expect(const StringCell('x').toBindable(), 'x');
    });

    test('timestamp encodes ISO-8601', () {
      final dt = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(TimestampCell(dt).toBindable(), dt.toIso8601String());
    });

    test('json encodes via jsonEncode', () {
      expect(const JsonCell({'a': 1}).toBindable(), jsonEncode({'a': 1}));
    });

    test('string -> StringCell -> bindable round-trips identity', () {
      const original = 'hello world';
      final cell = CellValue.fromDynamic(original);
      expect(cell.toBindable(), original);
    });

    test('int round-trips through fromDynamic/toBindable', () {
      final cell = CellValue.fromDynamic(123);
      expect(cell.toBindable(), 123);
    });
  });

  group('CellValue.display', () {
    test('null displays as empty string', () {
      expect(const NullCell().display(), '');
    });

    test('bool displays as true/false', () {
      expect(const BoolCell(true).display(), 'true');
      expect(const BoolCell(false).display(), 'false');
    });

    test('blob displays byte length summary', () {
      final blob = BlobCell(Uint8List.fromList([1, 2, 3, 4]));
      expect(blob.display(), '<blob 4B>');
    });

    test('json displays encoded form', () {
      expect(const JsonCell({'k': 'v'}).display(), jsonEncode({'k': 'v'}));
    });
  });
}
