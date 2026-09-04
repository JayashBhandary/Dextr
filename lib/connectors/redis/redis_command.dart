/// Turning what someone typed into a Redis command, and a Redis reply back
/// into rows.
///
/// Redis has no query language: the Query pane here takes one command per run,
/// written the way `redis-cli` takes it. Splitting that line is not a `split(' ')`
/// — `SET greeting "hello world"` is three arguments and one of them has a
/// space in it — so it is a real tokeniser, and being pure it is the part of
/// this connector that can be tested without a server.
library;

import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../data_source.dart';

/// Split a command line into arguments, honouring quotes and backslashes.
///
/// Follows `redis-cli`: single and double quotes both group, a backslash inside
/// double quotes escapes the next character, and an unterminated quote is an
/// error rather than a guess.
List<String> parseRedisCommand(String line) {
  final args = <String>[];
  final buffer = StringBuffer();
  var inArg = false;
  String? quote;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];

    if (quote != null) {
      if (ch == r'\' && quote == '"' && i + 1 < line.length) {
        buffer.write(_unescape(line[++i]));
        continue;
      }
      if (ch == quote) {
        quote = null;
        continue;
      }
      buffer.write(ch);
      continue;
    }

    if (ch == '"' || ch == "'") {
      quote = ch;
      inArg = true;
      continue;
    }

    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      if (inArg) {
        args.add(buffer.toString());
        buffer.clear();
        inArg = false;
      }
      continue;
    }

    buffer.write(ch);
    inArg = true;
  }

  if (quote != null) {
    throw const QueryError('Unbalanced quote in the command.');
  }
  if (inArg) args.add(buffer.toString());
  return args;
}

String _unescape(String ch) => switch (ch) {
      'n' => '\n',
      'r' => '\r',
      't' => '\t',
      'b' => '\b',
      'a' => '\x07',
      _ => ch,
    };

/// Why a command cannot be run here, or null when it can.
///
/// A short list, and none of it is about protecting the server from its owner —
/// `FLUSHALL` is allowed, because somebody typing it into a database client
/// means it. What is refused is the handful of commands that break the
/// *connection* rather than the data:
///
/// * `SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE` and `MONITOR` put the socket into
///   a mode where it streams forever and answers nothing. There is no reply to
///   render and no way back out; the connection would simply stop working.
/// * `HELLO` renegotiates the protocol. The client here speaks RESP2, and a
///   server switched to RESP3 answers in a shape it cannot parse — every
///   command after it fails.
/// * `RESET` and `QUIT` tear down the session this connection is holding.
String? redisCommandRefusal(List<String> argv) {
  if (argv.isEmpty) return 'Type a Redis command, such as GET mykey.';
  final name = argv.first.toUpperCase();
  return switch (name) {
    'SUBSCRIBE' || 'PSUBSCRIBE' || 'SSUBSCRIBE' =>
      '$name turns the connection into a subscriber that streams messages '
          'and answers no commands, and there is no way back out of it. Use '
          'redis-cli for pub/sub.',
    'MONITOR' =>
      'MONITOR streams every command the server runs and never returns, so '
          'the connection would stop answering. Use redis-cli for it.',
    'HELLO' =>
      'HELLO renegotiates the protocol version. This client speaks RESP2, and '
          'a server switched to RESP3 replies in a shape it cannot read.',
    'RESET' || 'QUIT' =>
      '$name ends the session this connection is holding. Disconnect from the '
          'rail instead.',
    _ => null,
  };
}

/// The databases an `INFO keyspace` reply says exist.
///
/// The section lists only databases that currently hold keys — `db0:keys=3,…`
/// — which is why it is a floor and not the answer: an empty database is real
/// and still worth opening. The caller unions this with what `CONFIG GET
/// databases` said and with the one the connection selected.
Set<int> redisKeyspaceDatabases(String info) {
  final out = <int>{};
  for (final line in info.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('db')) continue;
    final colon = trimmed.indexOf(':');
    if (colon < 0) continue;
    final index = int.tryParse(trimmed.substring(2, colon));
    if (index != null) out.add(index);
  }
  return out;
}

/// Render a Redis reply as a result table.
///
/// Redis answers with a scalar, an array, or an array of arrays, and none of
/// those is a row set. One column, `value`, holds a scalar; an array becomes
/// one row per element with its position beside it, which is what makes a flat
/// `HGETALL` reply — field, value, field, value — readable at all.
QueryResult redisReplyToResult(Object? reply, Duration elapsed) {
  if (reply is List) {
    return QueryResult(
      columns: const <String>['#', 'value'],
      rows: <RowData>[
        for (var i = 0; i < reply.length; i++)
          <String, CellValue>{
            '#': NumCell(i),
            'value': redisCell(reply[i]),
          },
      ],
      elapsed: elapsed,
    );
  }
  return QueryResult(
    columns: const <String>['value'],
    rows: <RowData>[
      <String, CellValue>{'value': redisCell(reply)},
    ],
    elapsed: elapsed,
  );
}

/// One value out of a Redis reply.
///
/// The RESP2 parser hands back strings, integers, nulls and lists, and a list
/// inside a cell becomes JSON rather than being flattened — a stream entry is
/// a list of a list, and flattening it loses which field went with which value.
CellValue redisCell(Object? value) {
  if (value == null) return const NullCell();
  if (value is List) return JsonCell(_plain(value)!);
  return CellValue.fromDynamic(value);
}

Object? _plain(Object? value) {
  if (value is List) return <Object?>[for (final v in value) _plain(v)];
  if (value is String || value is num || value is bool || value == null) {
    return value;
  }
  return value.toString();
}

/// A flat `[field, value, field, value]` reply as a map.
///
/// `HGETALL`, `HSCAN` and `ZRANGE … WITHSCORES` all answer in this shape, and
/// all three mean pairs.
Map<String, Object?> redisPairs(Object? reply) {
  if (reply is! List) return const <String, Object?>{};
  final out = <String, Object?>{};
  for (var i = 0; i + 1 < reply.length; i += 2) {
    out['${reply[i]}'] = _plain(reply[i + 1]);
  }
  return out;
}
