import 'dart:convert';

import 'package:dextr/connectors/bigquery/bigquery_value.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:flutter_test/flutter_test.dart';

/// BigQuery sends scalars as strings and nests everything else in `{"v": …}`
/// wrappers, so these are the two things worth pinning down: that a typed
/// scalar comes back typed, and that a struct or an array survives the walk.
void main() {
  BqField field(String type, {String mode = 'NULLABLE', List<BqField>? sub}) =>
      BqField(name: 'c', type: type, mode: mode, fields: sub ?? const []);

  /// A cell as the API wraps it.
  Object? v(Object? value) => <String, Object?>{'v': value};

  group('bigqueryCell — scalars', () {
    test('an INT64 becomes a number', () {
      expect((bigqueryCell('42', field('INT64')) as NumCell).value, 42);
      expect((bigqueryCell('42', field('INTEGER')) as NumCell).value, 42);
    });

    test('a FLOAT64 becomes a number', () {
      expect((bigqueryCell('1.5', field('FLOAT64')) as NumCell).value, 1.5);
    });

    test('NUMERIC keeps every digit as text', () {
      // 38 digits of NUMERIC and 77 of BIGNUMERIC do not survive a double, and
      // a number right to fifteen digits and wrong after them is worse.
      const exact = '0.12345678901234567890123456789';
      expect((bigqueryCell(exact, field('NUMERIC')) as StringCell).value, exact);
      expect((bigqueryCell(exact, field('BIGNUMERIC')) as StringCell).value,
          exact);
    });

    test('a BOOL becomes a bool', () {
      expect((bigqueryCell('true', field('BOOL')) as BoolCell).value, isTrue);
      expect(
          (bigqueryCell('false', field('BOOLEAN')) as BoolCell).value, isFalse);
    });

    test('a TIMESTAMP is epoch seconds with microseconds after the point', () {
      final cell =
          bigqueryCell('1616173200.123456', field('TIMESTAMP')) as TimestampCell;
      expect(cell.value.microsecondsSinceEpoch, 1616173200123456);
      expect(cell.value.isUtc, isTrue);
    });

    test('a DATE, DATETIME and TIME stay as BigQuery wrote them', () {
      // None of the three names an instant — a DATETIME has no zone, a TIME
      // has no day — so none is pinned to a zone this app invented.
      expect((bigqueryCell('2021-03-19', field('DATE')) as StringCell).value,
          '2021-03-19');
      expect(
          (bigqueryCell('2021-03-19T12:00:00', field('DATETIME')) as StringCell)
              .value,
          '2021-03-19T12:00:00');
      expect((bigqueryCell('12:00:00', field('TIME')) as StringCell).value,
          '12:00:00');
    });

    test('BYTES is base64, and becomes bytes', () {
      final encoded = base64Encode(<int>[1, 2, 3]);
      expect((bigqueryCell(encoded, field('BYTES')) as BlobCell).value,
          <int>[1, 2, 3]);
    });

    test('a JSON column becomes JSON', () {
      final cell = bigqueryCell('{"a":1}', field('JSON')) as JsonCell;
      expect(cell.value, <String, Object?>{'a': 1});
    });

    test('a null is a null', () {
      expect(bigqueryCell(null, field('INT64')), isA<NullCell>());
    });
  });

  group('bigqueryCell — nesting', () {
    test('a repeated scalar becomes one JSON array cell', () {
      final cell = bigqueryCell(
        <Object?>[v('1'), v('2'), v('3')],
        field('INT64', mode: 'REPEATED'),
      ) as JsonCell;
      expect(cell.value, <Object?>[1, 2, 3]);
    });

    test('a struct becomes a JSON object keyed by its field names', () {
      final cell = bigqueryCell(
        <String, Object?>{
          'f': <Object?>[v('7'), v('nick')],
        },
        field('RECORD', sub: <BqField>[
          const BqField(name: 'id', type: 'INT64'),
          const BqField(name: 'name', type: 'STRING'),
        ]),
      ) as JsonCell;
      expect(cell.value, <String, Object?>{'id': 7, 'name': 'nick'});
    });

    test('an array of structs keeps each struct whole', () {
      final cell = bigqueryCell(
        <Object?>[
          v(<String, Object?>{
            'f': <Object?>[v('1')],
          }),
          v(<String, Object?>{
            'f': <Object?>[v('2')],
          }),
        ],
        field('RECORD',
            mode: 'REPEATED',
            sub: const <BqField>[BqField(name: 'id', type: 'INT64')]),
      ) as JsonCell;
      expect(cell.value, <Object?>[
        <String, Object?>{'id': 1},
        <String, Object?>{'id': 2},
      ]);
    });

    test('a repeated field inside a struct is an array inside the object', () {
      final cell = bigqueryCell(
        <String, Object?>{
          'f': <Object?>[
            v(<Object?>[v('a'), v('b')]),
          ],
        },
        field('RECORD', sub: <BqField>[
          const BqField(name: 'tags', type: 'STRING', mode: 'REPEATED'),
        ]),
      ) as JsonCell;
      expect(cell.value, <String, Object?>{
        'tags': <Object?>['a', 'b'],
      });
    });

    test('a timestamp inside a struct is written out, not left as seconds', () {
      final cell = bigqueryCell(
        <String, Object?>{
          'f': <Object?>[v('1616173200.000000')],
        },
        field('RECORD',
            sub: const <BqField>[BqField(name: 'at', type: 'TIMESTAMP')]),
      ) as JsonCell;
      expect((cell.value as Map)['at'], '2021-03-19T17:00:00.000Z');
    });
  });

  group('bigqueryRow', () {
    test('a row is read positionally against the schema', () {
      final row = bigqueryRow(
        <String, Object?>{
          'f': <Object?>[v('1'), v('alpha'), v(null)],
        },
        <BqField>[
          const BqField(name: 'id', type: 'INT64', mode: 'REQUIRED'),
          const BqField(name: 'name', type: 'STRING'),
          const BqField(name: 'note', type: 'STRING'),
        ],
      );
      expect(row.keys, <String>['id', 'name', 'note']);
      expect((row['id'] as NumCell).value, 1);
      expect((row['name'] as StringCell).value, 'alpha');
      expect(row['note'], isA<NullCell>());
    });

    test('a row shorter than the schema fills the rest with nulls', () {
      // A partial response, or a schema read after the rows. Either way it is
      // a missing value rather than a reason to throw.
      final row = bigqueryRow(
        <String, Object?>{
          'f': <Object?>[v('1')],
        },
        <BqField>[
          const BqField(name: 'id', type: 'INT64'),
          const BqField(name: 'name', type: 'STRING'),
        ],
      );
      expect(row['name'], isA<NullCell>());
    });
  });

  group('BqField', () {
    test('a repeated field says so in its type label', () {
      expect(field('STRING', mode: 'REPEATED').typeLabel, 'ARRAY<STRING>');
      expect(field('STRING').typeLabel, 'STRING');
    });

    test('the schema JSON round-trips, nesting and all', () {
      final parsed = BqField.fromJson(<String, Object?>{
        'name': 'user',
        'type': 'RECORD',
        'mode': 'REPEATED',
        'fields': <Object?>[
          <String, Object?>{'name': 'id', 'type': 'INT64', 'mode': 'REQUIRED'},
        ],
      });
      expect(parsed.isRecord, isTrue);
      expect(parsed.isRepeated, isTrue);
      expect(parsed.fields.single.name, 'id');
      expect(parsed.fields.single.isRequired, isTrue);
    });
  });
}
