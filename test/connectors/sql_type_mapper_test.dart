import 'package:dextr/connectors/sql_common/sql_type_mapper.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('familyForSqlType', () {
    test('null type is unknown', () {
      expect(familyForSqlType(null), CellTypeFamily.unknown);
    });

    test('integer families', () {
      for (final t in ['INTEGER', 'int', 'BIGINT', 'smallint']) {
        expect(familyForSqlType(t), CellTypeFamily.integer, reason: t);
      }
    });

    test('real families', () {
      for (final t in ['REAL', 'FLOAT', 'double precision', 'NUMERIC', 'decimal']) {
        expect(familyForSqlType(t), CellTypeFamily.real, reason: t);
      }
    });

    test('bool / timestamp / blob / json / text', () {
      expect(familyForSqlType('BOOLEAN'), CellTypeFamily.bool);
      expect(familyForSqlType('TIMESTAMP'), CellTypeFamily.timestamp);
      expect(familyForSqlType('DATE'), CellTypeFamily.timestamp);
      expect(familyForSqlType('BLOB'), CellTypeFamily.blob);
      expect(familyForSqlType('bytea'), CellTypeFamily.blob);
      expect(familyForSqlType('JSONB'), CellTypeFamily.json);
      expect(familyForSqlType('VARCHAR'), CellTypeFamily.text);
      expect(familyForSqlType('TEXT'), CellTypeFamily.text);
    });

    test('unrecognized type is unknown', () {
      expect(familyForSqlType('GEOMETRY'), CellTypeFamily.unknown);
    });
  });

  group('parseString', () {
    test('empty input is null cell regardless of family', () {
      expect(parseString('', CellTypeFamily.integer), isA<NullCell>());
      expect(parseString('', CellTypeFamily.text), isA<NullCell>());
    });

    test('integer parses or falls back to string', () {
      expect((parseString('42', CellTypeFamily.integer) as NumCell).value, 42);
      expect(parseString('x', CellTypeFamily.integer), isA<StringCell>());
    });

    test('real parses or falls back to string', () {
      expect((parseString('3.14', CellTypeFamily.real) as NumCell).value, 3.14);
      expect(parseString('nope', CellTypeFamily.real), isA<StringCell>());
    });

    test('bool recognizes common truthy/falsy tokens', () {
      for (final t in ['true', '1', 't', 'TRUE']) {
        expect((parseString(t, CellTypeFamily.bool) as BoolCell).value, isTrue,
            reason: t);
      }
      for (final f in ['false', '0', 'f', 'FALSE']) {
        expect((parseString(f, CellTypeFamily.bool) as BoolCell).value, isFalse,
            reason: f);
      }
      expect(parseString('maybe', CellTypeFamily.bool), isA<StringCell>());
    });

    test('timestamp parses ISO or falls back to string', () {
      final cell = parseString('2026-05-29T10:00:00Z', CellTypeFamily.timestamp);
      expect(cell, isA<TimestampCell>());
      expect(parseString('not-a-date', CellTypeFamily.timestamp),
          isA<StringCell>());
    });

    test('default family yields string cell', () {
      expect((parseString('hi', CellTypeFamily.text) as StringCell).value, 'hi');
    });
  });
}
