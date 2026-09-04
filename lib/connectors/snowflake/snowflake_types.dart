/// How the SQL REST API describes a result, and how to read it back.
///
/// Snowflake's `/api/v2/statements` returns every value as a JSON **string**,
/// whatever the column's type actually is — `1` comes back as `"1"`, a
/// timestamp as `"1616173200.000000000"`, a date as the number of days since
/// the epoch. The type is described once, in `resultSetMetaData.rowType`, and
/// applying it to the strings is this file's whole job.
///
/// Kept apart from the connector because it is pure: a row of strings and a row
/// of column descriptions in, [CellValue]s out, no socket involved. That is
/// what makes it testable, and the decoding is where the mistakes live.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/cell_value.dart';

/// One column of a Snowflake result, as `rowType` describes it.
class SnowflakeColumn {
  const SnowflakeColumn({
    required this.name,
    required this.type,
    this.scale,
    this.nullable = true,
  });

  final String name;

  /// Snowflake's own lowercase type name: `fixed`, `text`, `timestamp_ntz`…
  final String type;

  /// Digits after the point, for `fixed`. Null for everything else.
  final int? scale;

  final bool nullable;

  static SnowflakeColumn fromJson(Map<String, Object?> j) => SnowflakeColumn(
        name: j['name'] as String? ?? '?',
        type: (j['type'] as String? ?? 'text').toLowerCase(),
        scale: (j['scale'] as num?)?.toInt(),
        nullable: (j['nullable'] as bool?) ?? true,
      );

  /// What the schema pane shows. Uppercased because that is how Snowflake's own
  /// `information_schema` and console spell a type.
  String get typeLabel => type.toUpperCase();
}

/// Turn one JSON value from `data` into a cell, using its column's type.
CellValue snowflakeCell(Object? raw, SnowflakeColumn column) {
  if (raw == null) return const NullCell();
  // Every value arrives as a string. Anything else is a shape change in the
  // API rather than a value to interpret, so it is passed through generically.
  if (raw is! String) return CellValue.fromDynamic(raw);

  switch (column.type) {
    case 'fixed':
      // Scale 0 is an integer; anything else has a point in it. Both fall back
      // to the text as sent rather than losing digits: a NUMBER(38,0) does not
      // fit in an int, and a NUMBER(38,20) does not fit in a double, and a
      // wrong number is worse than an unparsed one.
      if ((column.scale ?? 0) == 0) {
        final v = int.tryParse(raw);
        return v == null ? StringCell(raw) : NumCell(v);
      }
      final v = double.tryParse(raw);
      return v == null ? StringCell(raw) : NumCell(v);

    case 'real':
      final v = double.tryParse(raw);
      return v == null ? StringCell(raw) : NumCell(v);

    case 'boolean':
      if (raw == 'true' || raw == '1') return const BoolCell(true);
      if (raw == 'false' || raw == '0') return const BoolCell(false);
      return StringCell(raw);

    case 'date':
      final days = int.tryParse(raw);
      if (days == null) return StringCell(raw);
      return TimestampCell(
        DateTime.utc(1970).add(Duration(days: days)),
      );

    case 'time':
      return StringCell(snowflakeTimeOfDay(raw) ?? raw);

    case 'timestamp_ntz':
    case 'timestamp_ltz':
    case 'timestamp_tz':
      final at = snowflakeInstant(raw);
      return at == null ? StringCell(raw) : TimestampCell(at);

    case 'binary':
      final bytes = _hexToBytes(raw);
      return bytes == null ? StringCell(raw) : BlobCell(bytes);

    case 'variant':
    case 'object':
    case 'array':
    case 'geography':
    case 'geometry':
    case 'vector':
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) return JsonCell(decoded);
        if (decoded is List) return JsonCell(decoded);
      } catch (_) {
        // A VARIANT holding a bare string is valid and is not a JSON document.
      }
      return StringCell(raw);

    default:
      return StringCell(raw);
  }
}

/// The instant behind `"1616173200.123456789"`, or `"… 1440"` for a
/// `TIMESTAMP_TZ`.
///
/// Seconds since the epoch, a nanosecond fraction, and — for `TIMESTAMP_TZ`
/// only — a trailing offset in minutes past 1440. The offset is dropped: the
/// instant it names is exact, and what is lost is which wall clock it was
/// written on, which no [CellValue] can carry.
DateTime? snowflakeInstant(String raw) {
  final head = raw.split(' ').first;
  final dot = head.indexOf('.');
  final seconds = int.tryParse(dot < 0 ? head : head.substring(0, dot));
  if (seconds == null) return null;
  var micros = 0;
  if (dot >= 0) {
    final nanos = head.substring(dot + 1).padRight(9, '0').substring(0, 9);
    micros = (int.tryParse(nanos) ?? 0) ~/ 1000;
  }
  return DateTime.fromMicrosecondsSinceEpoch(
    seconds * Duration.microsecondsPerSecond + (seconds < 0 ? -micros : micros),
    isUtc: true,
  );
}

/// `"3661.500000000"` — seconds since midnight — as `"01:01:01.5"`.
///
/// A TIME is not an instant and has no date to hang off, so it stays text
/// rather than becoming a [TimestampCell] on some arbitrary day.
String? snowflakeTimeOfDay(String raw) {
  final dot = raw.indexOf('.');
  final seconds = int.tryParse(dot < 0 ? raw : raw.substring(0, dot));
  if (seconds == null || seconds < 0) return null;
  final h = (seconds ~/ 3600).toString().padLeft(2, '0');
  final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  var fraction = '';
  if (dot >= 0) {
    final trimmed = raw.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');
    if (trimmed.isNotEmpty) fraction = '.$trimmed';
  }
  return '$h:$m:$s$fraction';
}

Uint8List? _hexToBytes(String hex) {
  if (hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

/// One entry of the `bindings` map a statement is parameterised with.
///
/// Snowflake wants `{"1": {"type": "TEXT", "value": "abc"}}` — a Snowflake type
/// name and, again, the value as a string whatever it is.
Map<String, Object?> snowflakeBinding(Object? value) {
  if (value == null) return const {'type': 'TEXT', 'value': null};
  if (value is bool) {
    return {'type': 'BOOLEAN', 'value': value ? 'true' : 'false'};
  }
  if (value is int) return {'type': 'FIXED', 'value': value.toString()};
  if (value is double) return {'type': 'REAL', 'value': value.toString()};
  if (value is DateTime) {
    return {
      'type': 'TEXT',
      'value': value.toIso8601String(),
    };
  }
  if (value is List<int>) {
    final hex = value
        .map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0'))
        .join();
    return {'type': 'BINARY', 'value': hex.toUpperCase()};
  }
  return {'type': 'TEXT', 'value': value.toString()};
}

/// The host an account identifier is reached on.
///
/// Snowflake gives an account as `xy12345.eu-west-1` or
/// `myorg-myaccount`, and the endpoint is that plus
/// `.snowflakecomputing.com`. A value that already looks like a hostname — a
/// PrivateLink endpoint, say — is left exactly as typed, because guessing at
/// one of those produces a host that does not resolve.
String snowflakeHost(String account) {
  var a = account.trim();
  if (a.isEmpty) return a;
  if (a.startsWith('http://') || a.startsWith('https://')) {
    a = Uri.parse(a).host;
  }
  if (a.endsWith('/')) a = a.substring(0, a.length - 1);
  if (a.contains('.snowflakecomputing.com')) return a;
  return '$a.snowflakecomputing.com';
}

/// How a Snowflake connection proves who it is.
///
/// Two token types, and one absence worth stating plainly.
///
/// **Key-pair authentication is not offered.** It is Snowflake's recommended
/// method for a service, and it works by signing a JWT with an RSA private key
/// — RS256, an RSASSA-PKCS1-v1_5 signature over SHA-256. Dart's standard
/// library has no RSA at all: `dart:io` exposes TLS through the platform's
/// stack but no primitive to sign a payload with a private key, and neither
/// does any package this application depends on. Offering the option would mean
/// shipping an RSA implementation, and an option that cannot be honoured is
/// worse than one that is absent — somebody would pick it and file a bug.
///
/// Both modes below send a bearer token, so both are exactly as strong as the
/// keychain holding it. A programmatic access token can be scoped to a role and
/// given an expiry in Snowflake, which is the closest thing to a key pair's
/// safety that this transport can carry.
enum SnowflakeAuth {
  /// A programmatic access token, created under Snowflake's authentication
  /// policies. Long-lived, scoped to a user and a role, revocable.
  pat,

  /// An OAuth access token, from Snowflake's own OAuth or an external provider.
  /// Short-lived, so it is re-pasted when it expires.
  oauth;

  String get label => switch (this) {
        pat => 'Programmatic access token',
        oauth => 'OAuth access token',
      };

  String get description => switch (this) {
        pat =>
          'Created in Snowflake under a user, scoped to a role, with an '
              'expiry. The usual choice for a tool like this.',
        oauth =>
          'A short-lived token from Snowflake OAuth or your identity '
              'provider. Expires, and is then pasted again.',
      };

  /// The value of the `X-Snowflake-Authorization-Token-Type` header, which is
  /// how the API is told which of the two a bearer token is.
  String get tokenTypeHeader => switch (this) {
        pat => 'PROGRAMMATIC_ACCESS_TOKEN',
        oauth => 'OAUTH',
      };

  static SnowflakeAuth fromName(Object? raw) {
    for (final a in SnowflakeAuth.values) {
      if (a.name == raw) return a;
    }
    return SnowflakeAuth.pat;
  }
}
