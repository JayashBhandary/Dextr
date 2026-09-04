/// How BigQuery's REST API describes a row, and how to read one back.
///
/// Like Snowflake, BigQuery sends every scalar as a JSON **string** — an
/// `INT64` as `"42"`, a `TIMESTAMP` as `"1616173200.123456"` seconds since the
/// epoch — and describes the types once, in the table or query schema. Unlike
/// Snowflake it also nests: a row is `{"f": [{"v": …}]}`, a `STRUCT` is another
/// one of those inside a cell, and a `REPEATED` field is a list of them.
///
/// Pure by design, and kept out of the connector for the same reason
/// Snowflake's decoder is: this is where the mistakes live, and a mistake here
/// is a wrong number on screen rather than an error.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/cell_value.dart';

/// One field of a BigQuery schema — `TableFieldSchema`, without the dependency.
class BqField {
  const BqField({
    required this.name,
    required this.type,
    this.mode = 'NULLABLE',
    this.fields = const <BqField>[],
  });

  final String name;

  /// BigQuery's own type name: `STRING`, `INT64`, `TIMESTAMP`, `RECORD`…
  final String type;

  /// `NULLABLE`, `REQUIRED` or `REPEATED`.
  final String mode;

  /// Sub-fields, for a `RECORD` / `STRUCT`.
  final List<BqField> fields;

  bool get isRepeated => mode.toUpperCase() == 'REPEATED';
  bool get isRequired => mode.toUpperCase() == 'REQUIRED';
  bool get isRecord {
    final t = type.toUpperCase();
    return t == 'RECORD' || t == 'STRUCT';
  }

  /// What the schema pane shows: the type, and the fact that there are many.
  String get typeLabel => isRepeated ? 'ARRAY<$type>' : type;

  /// The same field describing one element of itself, for walking an array.
  BqField oneOf() => BqField(name: name, type: type, fields: fields);

  static BqField fromJson(Map<String, Object?> j) => BqField(
        name: j['name'] as String? ?? '?',
        type: j['type'] as String? ?? 'STRING',
        mode: j['mode'] as String? ?? 'NULLABLE',
        fields: <BqField>[
          for (final f in (j['fields'] as List?) ?? const [])
            BqField.fromJson(Map<String, Object?>.from(f as Map)),
        ],
      );
}

/// Turn `{"f": [{"v": …}]}` into a row, using [fields] to type each cell.
RowData bigqueryRow(Object? row, List<BqField> fields) {
  final cells = row is Map ? row['f'] : null;
  final out = <String, CellValue>{};
  for (var i = 0; i < fields.length; i++) {
    final raw = cells is List && i < cells.length ? cells[i] : null;
    out[fields[i].name] = bigqueryCell(_unwrap(raw), fields[i]);
  }
  return out;
}

/// Turn one `v` into a cell.
CellValue bigqueryCell(Object? v, BqField field) {
  if (v == null) return const NullCell();

  // A repeated or nested field becomes one JSON cell rather than several
  // columns: a grid column holds one value, and an array's length is a
  // property of the row, so spreading it across columns would need a column
  // count that changed from row to row.
  if (field.isRepeated || field.isRecord) {
    final plain = bigqueryPlain(v, field);
    return plain == null ? const NullCell() : JsonCell(plain);
  }

  return _scalarCell(v, field.type);
}

/// A value of [field] as plain JSON, recursing through records and arrays.
Object? bigqueryPlain(Object? v, BqField field) {
  if (v == null) return null;

  if (field.isRepeated) {
    if (v is! List) return null;
    final element = field.oneOf();
    return <Object?>[
      for (final e in v) bigqueryPlain(_unwrap(e), element),
    ];
  }

  if (field.isRecord) {
    final cells = v is Map ? v['f'] : null;
    if (cells is! List) return null;
    return <String, Object?>{
      for (var i = 0; i < field.fields.length; i++)
        field.fields[i].name: i < cells.length
            ? bigqueryPlain(_unwrap(cells[i]), field.fields[i])
            : null,
    };
  }

  return _jsonScalar(_scalarCell(v, field.type));
}

/// What a scalar looks like inside a JSON cell: a value, not a [CellValue].
Object? _jsonScalar(CellValue cell) => switch (cell) {
      NullCell() => null,
      BoolCell(:final value) => value,
      NumCell(:final value) => value,
      StringCell(:final value) => value,
      TimestampCell(:final value) => value.toIso8601String(),
      BlobCell(:final value) => base64Encode(value),
      JsonCell(:final value) => value,
      UnknownCell(:final raw) => raw?.toString(),
    };

/// `{"v": x}` → `x`. Rows, records and array elements are all wrapped.
Object? _unwrap(Object? cell) => cell is Map ? cell['v'] : cell;

CellValue _scalarCell(Object? v, String type) {
  if (v == null) return const NullCell();
  if (v is! String) return CellValue.fromDynamic(v);

  switch (type.toUpperCase()) {
    case 'INTEGER':
    case 'INT64':
      final n = int.tryParse(v);
      return n == null ? StringCell(v) : NumCell(n);

    case 'FLOAT':
    case 'FLOAT64':
      final n = double.tryParse(v);
      return n == null ? StringCell(v) : NumCell(n);

    // NUMERIC is 38 digits and BIGNUMERIC is 77, neither of which survives a
    // double. Kept as the exact decimal text BigQuery sent: a number that is
    // right to fifteen digits and wrong after them is worse than a string.
    case 'NUMERIC':
    case 'BIGNUMERIC':
    case 'DECIMAL':
    case 'BIGDECIMAL':
      return StringCell(v);

    case 'BOOLEAN':
    case 'BOOL':
      if (v == 'true') return const BoolCell(true);
      if (v == 'false') return const BoolCell(false);
      return StringCell(v);

    // Seconds since the epoch, with microseconds after the point.
    case 'TIMESTAMP':
      final at = bigqueryInstant(v);
      return at == null ? StringCell(v) : TimestampCell(at);

    // A DATE, a DATETIME and a TIME arrive already written out, and none of
    // them names an instant — a DATETIME has no zone and a TIME has no day —
    // so they stay as the text BigQuery chose rather than being pinned to a
    // zone this application invented.
    case 'DATE':
    case 'DATETIME':
    case 'TIME':
      return StringCell(v);

    case 'BYTES':
      try {
        return BlobCell(Uint8List.fromList(base64Decode(v)));
      } catch (_) {
        return StringCell(v);
      }

    case 'JSON':
      try {
        final Object? decoded = jsonDecode(v);
        if (decoded is Map) return JsonCell(decoded);
        if (decoded is List) return JsonCell(decoded);
      } catch (_) {
        // A JSON column holding a bare scalar is valid.
      }
      return StringCell(v);

    default:
      return StringCell(v);
  }
}

/// The instant behind `"1616173200.123456"`.
DateTime? bigqueryInstant(String raw) {
  final dot = raw.indexOf('.');
  final seconds = int.tryParse(dot < 0 ? raw : raw.substring(0, dot));
  if (seconds == null) return null;
  var micros = 0;
  if (dot >= 0) {
    final frac = raw.substring(dot + 1).padRight(6, '0').substring(0, 6);
    micros = int.tryParse(frac) ?? 0;
  }
  return DateTime.fromMicrosecondsSinceEpoch(
    seconds * Duration.microsecondsPerSecond + (seconds < 0 ? -micros : micros),
    isUtc: true,
  );
}
