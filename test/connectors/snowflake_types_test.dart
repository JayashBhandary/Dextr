import 'package:dextr/connectors/snowflake/snowflake_types.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:flutter_test/flutter_test.dart';

/// Snowflake sends every value as a string and describes the type separately,
/// so this is where a column of numbers becomes numbers rather than text.
void main() {
  SnowflakeColumn column(String type, {int? scale}) =>
      SnowflakeColumn(name: 'c', type: type, scale: scale);

  group('snowflakeCell', () {
    test('a null is a null whatever the column says', () {
      expect(snowflakeCell(null, column('fixed')), isA<NullCell>());
    });

    test('scale 0 fixed is an integer', () {
      final cell = snowflakeCell('42', column('fixed', scale: 0));
      expect(cell, isA<NumCell>());
      expect((cell as NumCell).value, 42);
    });

    test('a scaled fixed keeps its point', () {
      final cell = snowflakeCell('1.25', column('fixed', scale: 2));
      expect((cell as NumCell).value, 1.25);
    });

    test('a number too long for an int stays exact as text', () {
      // NUMBER(38,0) does not fit in a 64-bit int, and a wrong number is
      // worse than an unparsed one.
      const huge = '123456789012345678901234567890';
      final cell = snowflakeCell(huge, column('fixed', scale: 0));
      expect(cell, isA<StringCell>());
      expect((cell as StringCell).value, huge);
    });

    test('booleans arrive as the words', () {
      expect((snowflakeCell('true', column('boolean')) as BoolCell).value,
          isTrue);
      expect((snowflakeCell('false', column('boolean')) as BoolCell).value,
          isFalse);
    });

    test('a date is a count of days from the epoch', () {
      final cell = snowflakeCell('18705', column('date')) as TimestampCell;
      expect(cell.value, DateTime.utc(2021, 3, 19));
    });

    test('a negative date is before the epoch', () {
      final cell = snowflakeCell('-1', column('date')) as TimestampCell;
      expect(cell.value, DateTime.utc(1969, 12, 31));
    });

    test('a timestamp carries its fraction to microseconds', () {
      final cell = snowflakeCell('1616173200.123456789', column('timestamp_ntz'))
          as TimestampCell;
      expect(cell.value.millisecondsSinceEpoch, 1616173200123);
      expect(cell.value.microsecondsSinceEpoch, 1616173200123456);
      expect(cell.value.isUtc, isTrue);
    });

    test('a TIMESTAMP_TZ offset suffix is not read as part of the seconds', () {
      final cell =
          snowflakeCell('1616173200.000000000 1440', column('timestamp_tz'))
              as TimestampCell;
      expect(cell.value.millisecondsSinceEpoch, 1616173200000);
    });

    test('a time is written out rather than pinned to a day', () {
      expect(
        (snowflakeCell('3661.500000000', column('time')) as StringCell).value,
        '01:01:01.5',
      );
      expect(
        (snowflakeCell('0.000000000', column('time')) as StringCell).value,
        '00:00:00',
      );
    });

    test('binary is hex, and becomes bytes', () {
      final cell = snowflakeCell('DEADBEEF', column('binary')) as BlobCell;
      expect(cell.value, <int>[0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('odd-length hex is left as text rather than half-decoded', () {
      expect(snowflakeCell('ABC', column('binary')), isA<StringCell>());
    });

    test('a variant document is JSON', () {
      final cell = snowflakeCell('{"a":1}', column('variant')) as JsonCell;
      expect(cell.value, <String, Object?>{'a': 1});
    });

    test('a variant holding a bare string is not forced into JSON', () {
      expect(snowflakeCell('hello', column('variant')), isA<StringCell>());
    });

    test('an unparseable value falls back to the text as sent', () {
      expect(snowflakeCell('not a number', column('fixed')), isA<StringCell>());
    });
  });

  group('snowflakeHost', () {
    test('an account identifier gains the domain', () {
      expect(snowflakeHost('xy12345.eu-west-1'),
          'xy12345.eu-west-1.snowflakecomputing.com');
    });

    test('a full hostname is left exactly as typed', () {
      // A PrivateLink endpoint is a hostname already; appending to it produces
      // a name that does not resolve.
      expect(snowflakeHost('acct.privatelink.snowflakecomputing.com'),
          'acct.privatelink.snowflakecomputing.com');
    });

    test('a pasted URL is reduced to its host', () {
      expect(snowflakeHost('https://xy12345.snowflakecomputing.com/'),
          'xy12345.snowflakecomputing.com');
    });
  });

  group('snowflakeBinding', () {
    test('every value is sent as a string beside its type', () {
      expect(snowflakeBinding(7), {'type': 'FIXED', 'value': '7'});
      expect(snowflakeBinding(1.5), {'type': 'REAL', 'value': '1.5'});
      expect(snowflakeBinding(true), {'type': 'BOOLEAN', 'value': 'true'});
      expect(snowflakeBinding('x'), {'type': 'TEXT', 'value': 'x'});
      expect(snowflakeBinding(null), {'type': 'TEXT', 'value': null});
      expect(snowflakeBinding(<int>[0xAB, 0x01]),
          {'type': 'BINARY', 'value': 'AB01'});
    });
  });

  group('SnowflakeAuth', () {
    test('each mode names the header value the API expects', () {
      expect(SnowflakeAuth.pat.tokenTypeHeader, 'PROGRAMMATIC_ACCESS_TOKEN');
      expect(SnowflakeAuth.oauth.tokenTypeHeader, 'OAUTH');
    });

    test('an unknown stored value reads back as the safe default', () {
      expect(SnowflakeAuth.fromName('keypair'), SnowflakeAuth.pat);
      expect(SnowflakeAuth.fromName(null), SnowflakeAuth.pat);
      expect(SnowflakeAuth.fromName('oauth'), SnowflakeAuth.oauth);
    });
  });
}
