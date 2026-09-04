import 'package:dextr/connectors/redis/redis_command.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of the Redis connector that need no server: splitting a typed
/// command, deciding which commands would break the connection, and turning a
/// RESP reply into something a grid can draw.
void main() {
  group('parseRedisCommand', () {
    test('splits on whitespace', () {
      expect(parseRedisCommand('GET mykey'), <String>['GET', 'mykey']);
    });

    test('collapses runs of whitespace and trims', () {
      expect(parseRedisCommand('  SET   a   b \t'),
          <String>['SET', 'a', 'b']);
    });

    test('a quoted argument keeps its spaces', () {
      expect(parseRedisCommand('SET greeting "hello world"'),
          <String>['SET', 'greeting', 'hello world']);
    });

    test('single quotes group too', () {
      expect(parseRedisCommand("SET k 'a b'"), <String>['SET', 'k', 'a b']);
    });

    test('an escape inside double quotes is honoured', () {
      expect(parseRedisCommand(r'SET k "line\none"'),
          <String>['SET', 'k', 'line\none']);
      expect(parseRedisCommand(r'SET k "say \"hi\""'),
          <String>['SET', 'k', 'say "hi"']);
    });

    test('a backslash inside single quotes is literal', () {
      // redis-cli treats single quotes as raw, and a Windows path pasted into
      // one should survive it.
      expect(parseRedisCommand(r"SET k 'C:\temp'"),
          <String>['SET', 'k', r'C:\temp']);
    });

    test('an empty quoted argument is an argument', () {
      expect(parseRedisCommand('SET k ""'), <String>['SET', 'k', '']);
    });

    test('a quote does not start a new argument, only whitespace does', () {
      // As in redis-cli: quoting suspends whitespace splitting, it does not
      // delimit arguments, so this is two of them and not three.
      expect(parseRedisCommand('SET pre"fix mid"dle'),
          <String>['SET', 'prefix middle']);
    });

    test('an unbalanced quote is an error, not a guess', () {
      expect(() => parseRedisCommand('SET k "unterminated'),
          throwsA(isA<QueryError>()));
    });

    test('an empty line is no arguments', () {
      expect(parseRedisCommand('   '), isEmpty);
    });
  });

  group('redisCommandRefusal', () {
    test('an ordinary command is allowed', () {
      expect(redisCommandRefusal(<String>['GET', 'k']), isNull);
      expect(redisCommandRefusal(<String>['HGETALL', 'k']), isNull);
    });

    test('a destructive command is still the owner\'s to run', () {
      // The refusal list is not about protecting a database from its owner.
      expect(redisCommandRefusal(<String>['FLUSHALL']), isNull);
      expect(redisCommandRefusal(<String>['DEL', 'k']), isNull);
    });

    test('commands that never return are refused', () {
      for (final name in <String>[
        'SUBSCRIBE',
        'PSUBSCRIBE',
        'SSUBSCRIBE',
        'MONITOR',
      ]) {
        expect(redisCommandRefusal(<String>[name, 'ch']), isNotNull,
            reason: '$name streams forever and answers nothing');
      }
    });

    test('HELLO is refused because the parser speaks RESP2', () {
      expect(redisCommandRefusal(<String>['HELLO', '3']), contains('RESP2'));
    });

    test('commands that tear down the session are refused', () {
      expect(redisCommandRefusal(<String>['RESET']), isNotNull);
      expect(redisCommandRefusal(<String>['QUIT']), isNotNull);
    });

    test('the check is case-insensitive', () {
      expect(redisCommandRefusal(<String>['monitor']), isNotNull);
    });

    test('nothing typed at all says what to type', () {
      expect(redisCommandRefusal(<String>[]), contains('GET mykey'));
    });
  });

  group('redisKeyspaceDatabases', () {
    test('reads the database indexes out of an INFO section', () {
      const info = '# Keyspace\r\n'
          'db0:keys=3,expires=0,avg_ttl=0\r\n'
          'db5:keys=1,expires=1,avg_ttl=100\r\n';
      expect(redisKeyspaceDatabases(info), <int>{0, 5});
    });

    test('an empty server lists nothing', () {
      expect(redisKeyspaceDatabases('# Keyspace\r\n'), isEmpty);
    });

    test('a line that is not a database is skipped', () {
      expect(redisKeyspaceDatabases('# Keyspace\ndbx:keys=1\ndb2:keys=1\n'),
          <int>{2});
    });
  });

  group('redisReplyToResult', () {
    test('a scalar is one row in one column', () {
      final result = redisReplyToResult('PONG', Duration.zero);
      expect(result.columns, <String>['value']);
      expect(result.rows.single['value']!.display(), 'PONG');
    });

    test('a nil reply is a null, not the word null', () {
      final result = redisReplyToResult(null, Duration.zero);
      expect(result.rows.single['value'], isA<NullCell>());
    });

    test('an integer reply keeps its type', () {
      final result = redisReplyToResult(3, Duration.zero);
      expect((result.rows.single['value'] as NumCell).value, 3);
    });

    test('an array is one row per element, with its position', () {
      // What makes a flat HGETALL reply — field, value, field, value —
      // readable at all.
      final result = redisReplyToResult(
          <Object?>['name', 'nick', 'age', '9'], Duration.zero);
      expect(result.columns, <String>['#', 'value']);
      expect(result.rows, hasLength(4));
      expect((result.rows[0]['#'] as NumCell).value, 0);
      expect(result.rows[1]['value']!.display(), 'nick');
    });

    test('a nested array stays nested rather than being flattened', () {
      // An XRANGE entry is a list inside a list, and flattening it loses which
      // field went with which value.
      final result = redisReplyToResult(
        <Object?>[
          <Object?>['1-0', <Object?>['temp', '21']],
        ],
        Duration.zero,
      );
      expect(result.rows.single['value'], isA<JsonCell>());
      expect((result.rows.single['value'] as JsonCell).value, <Object?>[
        '1-0',
        <Object?>['temp', '21'],
      ]);
    });
  });

  group('redisPairs', () {
    test('a flat reply becomes a map', () {
      expect(redisPairs(<Object?>['a', '1', 'b', '2']),
          <String, Object?>{'a': '1', 'b': '2'});
    });

    test('a trailing unpaired element is dropped rather than half-read', () {
      expect(redisPairs(<Object?>['a', '1', 'b']),
          <String, Object?>{'a': '1'});
    });

    test('anything that is not a list is no pairs', () {
      expect(redisPairs('nope'), isEmpty);
      expect(redisPairs(null), isEmpty);
    });
  });
}
