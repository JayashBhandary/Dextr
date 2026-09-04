import 'package:redis/redis.dart' as r;

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../data_source.dart';
import 'redis_command.dart';

/// Redis, as a grid of keys.
///
/// Redis has no tables and no rows, so the first job of this connector is to
/// decide what a container and a row are going to be. A **container is one of
/// the server's numbered databases** — `db0`, `db1` — because that is the only
/// grouping Redis itself has, and a **row is one key**: its name, its type, how
/// long it has left, how big it is, and as much of its value as is worth
/// looking at.
///
/// Three consequences worth knowing before reading the rest:
///
/// * **Paging is a walk, not a jump.** `SCAN` has a cursor and no offset, so
///   asking for page five means scanning past the first four. That is Redis's
///   guarantee — a cursor survives keys being added and removed mid-scan, an
///   index does not — and it is why the row count is not shown: nothing short
///   of a full scan knows it.
/// * **A page of keys costs several commands per key.** A key's type, TTL, size
///   and value are four different commands, and none of them is batched by
///   Redis. They are pipelined instead: every command for the page goes out
///   before any reply is read, so a hundred keys is two network round trips
///   rather than four hundred.
/// * **Values are previewed, not loaded.** A string can be half a gigabyte and
///   a list can be millions of elements. The grid reads a capped prefix of
///   each — `GETRANGE`, `LRANGE 0 n`, `HSCAN … COUNT n` — and says so in the
///   size column, which is the real length.
///
/// Writes cover the shapes a grid cell can honestly round-trip: the value of a
/// string, the TTL of anything, a rename, and a delete. Editing the value of a
/// hash or a list would mean deleting the key and rebuilding it from a JSON
/// preview that may be truncated — a data loss dressed up as an edit — so it is
/// refused with the command to use instead.
class RedisDataSource extends DataSource
    with RawQueryable, Writable, SchemaReadable {
  RedisDataSource({required this.record, required this.secrets});

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;

  r.RedisConnection? _conn;
  r.Command? _cmd;

  /// The database currently selected on the socket. Redis `SELECT` is
  /// connection state, so this is tracked to avoid re-selecting per command.
  int? _selectedDb;

  /// The columns every key row has.
  static const _key = 'key';
  static const _type = 'type';
  static const _ttl = 'ttl';
  static const _size = 'size';
  static const _value = 'value';

  /// How much of a value is read for the preview.
  static const _previewBytes = 512;
  static const _previewElements = 20;

  /// A cap on how many `SCAN` round trips one page is allowed, so a keyspace
  /// full of misses cannot spin forever.
  static const _maxScanCalls = 50;

  static const _connectTimeout = Duration(seconds: 15);

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.redis;
  @override
  Set<Capability> get capabilities => const {
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
      };

  String get _host => (record.config['host'] as String?) ?? 'localhost';
  int get _port => (record.config['port'] as num?)?.toInt() ?? 6379;
  int get _db => (record.config['db'] as num?)?.toInt() ?? 0;
  bool get _tls => (record.config['tls'] as bool?) ?? false;
  String? get _username {
    final raw = record.config['username'] as String?;
    return raw == null || raw.trim().isEmpty ? null : raw.trim();
  }

  r.Command get _open {
    final c = _cmd;
    if (c == null) throw const ConnectError('Not connected');
    return c;
  }

  // --- Connection ----------------------------------------------------------

  @override
  Future<void> connect() async {
    final conn = r.RedisConnection();
    try {
      // The driver's connect has no timeout of its own, so a host that
      // silently drops packets would hang here until the OS gave up — minutes.
      _cmd = await (_tls
              ? conn.connectSecure(_host, _port)
              : conn.connect(_host, _port))
          .timeout(_connectTimeout);
      _conn = conn;
    } on Object catch (e, st) {
      throw ConnectError('Redis connect failed: $e', cause: e, stack: st);
    }

    final password = secrets?.password;
    if (password != null && password.isNotEmpty) {
      // Two forms of AUTH: the one-argument form for a `requirepass` server,
      // and the two-argument form for a Redis 6 ACL user.
      await _send(<String>['AUTH', ?_username, password]);
    } else if (_username != null) {
      throw const ConnectError(
        'A username needs a password: Redis ACL authentication sends both.',
      );
    }

    await _select(_db);
    await ping();
  }

  @override
  Future<void> disconnect() async {
    final conn = _conn;
    _conn = null;
    _cmd = null;
    _selectedDb = null;
    if (conn != null) {
      try {
        await conn.close();
      } on Object {
        // Already gone. Nothing to reclaim, and nothing the caller can do.
      }
    }
  }

  @override
  Future<void> ping() async {
    await _send(<String>['PING']);
  }

  @override
  Future<void> dispose() => disconnect();

  /// Send one command, turning a Redis error reply into a [QueryError].
  Future<Object?> _send(List<String> argv) async {
    try {
      return await _open.send_object(argv);
    } on r.RedisError catch (e, st) {
      throw QueryError(e.error, cause: e, stack: st);
    } on DextrError {
      rethrow;
    } on Object catch (e, st) {
      throw QueryError('Redis: $e', cause: e, stack: st);
    }
  }

  /// Queue a command without waiting for it, and treat its failure as an
  /// absent answer.
  ///
  /// The driver serialises replies in the order the commands were sent, so
  /// issuing a batch and awaiting them afterwards is a pipeline: one write per
  /// command, one round trip for the lot.
  ///
  /// A failure becomes null rather than an exception because these are the
  /// per-key describe commands, and one key that cannot answer — a module type
  /// that has no `STRLEN`, a key that expired between the scan and the read —
  /// should leave one cell empty rather than fail the whole page. It also
  /// keeps a rejected command in a batch from surfacing as an unhandled
  /// asynchronous error once [Future.wait] has already thrown for another.
  Future<Object?> _queue(List<String> argv) => _open
      .send_object(argv)
      .then<Object?>((v) => v, onError: (Object _) => null);

  Future<void> _select(int db) async {
    if (_selectedDb == db) return;
    await _send(<String>['SELECT', db.toString()]);
    _selectedDb = db;
  }

  // --- Containers ----------------------------------------------------------

  @override
  Future<List<ContainerRef>> listContainers() async {
    final databases = <int>{_db};

    // How many databases the server has. Managed Redis usually forbids CONFIG,
    // so this is attempted and not required.
    try {
      final reply = await _send(<String>['CONFIG', 'GET', 'databases']);
      if (reply is List && reply.length >= 2) {
        final count = int.tryParse('${reply[1]}');
        if (count != null && count > 0 && count <= 64) {
          databases.addAll(List<int>.generate(count, (i) => i));
        }
      }
    } on DextrError {
      // No CONFIG. The keyspace section below still finds the ones in use.
    }

    try {
      final info = await _send(<String>['INFO', 'keyspace']);
      if (info is String) databases.addAll(redisKeyspaceDatabases(info));
    } on DextrError {
      // No INFO either — a heavily restricted server. The selected database is
      // still known, and that is the one the reader asked for.
    }

    final sorted = databases.toList()..sort();
    return [
      for (final index in sorted)
        ContainerRef(
          name: 'db$index',
          path: index.toString(),
          subtype: 'keyspace',
        ),
    ];
  }

  int _dbOf(ContainerRef container) =>
      int.tryParse(container.path ?? '') ??
      int.tryParse(container.name.replaceFirst('db', '')) ??
      _db;

  // --- Rows ----------------------------------------------------------------

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    await _select(_dbOf(container));
    final pattern = _matchFor(spec);

    // SCAN walks from a cursor and cannot skip, so an offset is scanned past
    // rather than jumped to. The keys walked over are counted and discarded.
    final wanted = spec.offset + spec.limit;
    final keys = <String>[];
    var cursor = spec.cursor ?? '0';
    var calls = 0;
    do {
      final reply = await _send(<String>[
        'SCAN',
        cursor,
        if (pattern != null) ...<String>['MATCH', pattern],
        'COUNT',
        // COUNT is a hint about work done per call, not a limit on what comes
        // back. Asking for the whole page at once keeps the round trips down.
        (spec.limit * 2).clamp(10, 1000).toString(),
      ]);
      if (reply is! List || reply.length < 2) break;
      cursor = '${reply[0]}';
      final batch = reply[1];
      if (batch is List) {
        for (final k in batch) {
          keys.add('$k');
        }
      }
      calls++;
    } while (cursor != '0' && keys.length < wanted && calls < _maxScanCalls);

    final page = keys.skip(spec.offset).take(spec.limit).toList();
    return Page(
      items: await _describeKeys(page),
      // A cursor of 0 means the walk finished. Offset paging re-walks from the
      // start, so the cursor is offered for a caller that would rather not.
      nextCursor: cursor == '0' ? null : cursor,
    );
  }

  /// The `MATCH` glob a filter on the key column becomes.
  String? _matchFor(QuerySpec spec) {
    if (spec.where.isEmpty) return null;
    String? pattern;
    for (final clause in spec.where) {
      if (clause.field != _key) {
        throw QueryError(
          'Redis can only narrow a scan by key name. There is no index on '
          '"${clause.field}", so a filter on it cannot be answered without '
          'reading every key in the database.',
        );
      }
      final text = clause.value?.display() ?? '';
      pattern = switch (clause.op) {
        FilterOp.eq => text,
        FilterOp.contains => '*$text*',
        FilterOp.like => text.replaceAll('%', '*').replaceAll('_', '?'),
        _ => throw QueryError(
            'Redis matches a key name by glob, so ${clause.op.name} is not '
            'something a scan can express.',
          ),
      };
    }
    return pattern;
  }

  /// Type, TTL, size and a value preview for each key, in two pipelined rounds.
  Future<List<RowData>> _describeKeys(List<String> keys) async {
    if (keys.isEmpty) return const <RowData>[];

    // Round one: what each key is, and how long it has left. Both are needed
    // before the right size and value commands can even be named.
    _open.pipe_start();
    final meta = <Future<Object?>>[];
    for (final key in keys) {
      meta.add(_queue(<String>['TYPE', key]));
      meta.add(_queue(<String>['PTTL', key]));
    }
    final metaReplies = await Future.wait(meta);
    _open.pipe_end();

    final types = <String>[];
    final ttls = <int>[];
    for (var i = 0; i < keys.length; i++) {
      types.add('${metaReplies[i * 2] ?? 'none'}');
      ttls.add(int.tryParse('${metaReplies[i * 2 + 1]}') ?? -1);
    }

    // Round two: the size and the preview, which are different commands for
    // every type.
    _open.pipe_start();
    final detail = <Future<Object?>>[];
    for (var i = 0; i < keys.length; i++) {
      final sizeArgs = _sizeCommand(types[i], keys[i]);
      final valueArgs = _previewCommand(types[i], keys[i]);
      detail.add(sizeArgs == null ? Future.value() : _queue(sizeArgs));
      detail.add(valueArgs == null ? Future.value() : _queue(valueArgs));
    }
    final detailReplies = await Future.wait(detail);
    _open.pipe_end();

    return <RowData>[
      for (var i = 0; i < keys.length; i++)
        <String, CellValue>{
          _key: StringCell(keys[i]),
          _type: StringCell(types[i]),
          _ttl: ttls[i] < 0
              // -1 is "no expiry" and -2 is "gone since the scan saw it".
              // Neither is a duration, so neither is a number.
              ? const NullCell()
              : NumCell(ttls[i] / 1000),
          _size: switch (detailReplies[i * 2]) {
            final int n => NumCell(n),
            final String s => NumCell(int.tryParse(s) ?? s.length),
            _ => const NullCell(),
          },
          _value: _previewCell(types[i], detailReplies[i * 2 + 1]),
        },
    ];
  }

  /// The command that reports a key's real length, by type.
  List<String>? _sizeCommand(String type, String key) => switch (type) {
        'string' => <String>['STRLEN', key],
        'list' => <String>['LLEN', key],
        'set' => <String>['SCARD', key],
        'hash' => <String>['HLEN', key],
        'zset' => <String>['ZCARD', key],
        'stream' => <String>['XLEN', key],
        _ => null,
      };

  /// The command that reads a capped prefix of a key's value, by type.
  List<String>? _previewCommand(String type, String key) => switch (type) {
        // GETRANGE rather than GET: a string value can be 512MB, and the grid
        // shows the first line of it.
        'string' => <String>['GETRANGE', key, '0', '${_previewBytes - 1}'],
        'list' => <String>['LRANGE', key, '0', '${_previewElements - 1}'],
        // SSCAN and HSCAN rather than SMEMBERS and HGETALL, which read the
        // whole collection however large it is.
        'set' => <String>['SSCAN', key, '0', 'COUNT', '$_previewElements'],
        'hash' => <String>['HSCAN', key, '0', 'COUNT', '$_previewElements'],
        'zset' => <String>[
            'ZRANGE',
            key,
            '0',
            '${_previewElements - 1}',
            'WITHSCORES',
          ],
        'stream' => <String>[
            'XRANGE',
            key,
            '-',
            '+',
            'COUNT',
            '$_previewElements',
          ],
        // A module type — ReJSON, a time series, a bloom filter — has no
        // command this connector knows. Better an empty cell with the type
        // named beside it than a guess.
        _ => null,
      };

  CellValue _previewCell(String type, Object? reply) {
    if (reply == null) return const NullCell();
    return switch (type) {
      'string' => StringCell('$reply'),
      'hash' || 'zset' => JsonCell(redisPairs(
          // SSCAN and HSCAN answer [cursor, [flat pairs]]; ZRANGE answers the
          // flat pairs directly.
          type == 'hash' && reply is List && reply.length == 2
              ? reply[1]
              : reply,
        )),
      'set' => redisCell(reply is List && reply.length == 2 ? reply[1] : reply),
      _ => redisCell(reply),
    };
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    final key = id.fields[_key]?.display();
    if (key == null || key.isEmpty) return null;
    await _select(_dbOf(container));
    final rows = await _describeKeys(<String>[key]);
    if (rows.isEmpty) return null;
    // "none" is Redis's answer for a key that is not there.
    return rows.first[_type]?.display() == 'none' ? null : rows.first;
  }

  // --- Raw commands --------------------------------------------------------

  @override
  Future<QueryResult> runRawQuery(String text,
      [List<Object?> params = const []]) async {
    final argv = parseRedisCommand(text);
    final refusal = redisCommandRefusal(argv);
    if (refusal != null) throw QueryError(refusal);
    final sw = Stopwatch()..start();
    final reply = await _send(<String>[
      ...argv,
      for (final p in params) '$p',
    ]);
    // A command may have selected another database, or created one. Forgetting
    // the tracked selection means the next browse re-selects rather than
    // trusting a stale value.
    if (argv.first.toUpperCase() == 'SELECT') _selectedDb = null;
    return redisReplyToResult(reply, sw.elapsed);
  }

  // --- Writes --------------------------------------------------------------

  @override
  Future<RowId> insertRow(
      ContainerRef container, Map<String, CellValue> values) async {
    final key = values[_key]?.display() ?? '';
    if (key.isEmpty) {
      throw const QueryError('A key name is required.');
    }
    await _select(_dbOf(container));
    final ttl = _ttlMillis(values[_ttl]);
    await _send(<String>[
      'SET',
      key,
      values[_value]?.display() ?? '',
      if (ttl != null) ...<String>['PX', '$ttl'],
    ]);
    return RowId(<String, CellValue>{_key: StringCell(key)});
  }

  @override
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values) async {
    var key = id.fields[_key]?.display() ?? '';
    if (key.isEmpty) {
      throw const QueryError('A key name is required to update a key.');
    }
    await _select(_dbOf(container));

    // A rename first, so everything after it names the key that now exists.
    final renamed = values[_key]?.display();
    if (renamed != null && renamed.isNotEmpty && renamed != key) {
      await _send(<String>['RENAME', key, renamed]);
      key = renamed;
    }

    if (values.containsKey(_value)) {
      final type = '${await _send(<String>['TYPE', key])}';
      if (type != 'string' && type != 'none') {
        throw QueryError(
          'This key is a $type, and the grid shows only a capped preview of '
          'it — writing that back would replace the whole $type with what is '
          'on screen. Change it in the Query pane instead, with the command '
          'for one element: ${_writeCommandFor(type)}.',
        );
      }
      await _send(<String>['SET', key, values[_value]?.display() ?? '']);
    }

    if (values.containsKey(_ttl)) {
      final ttl = _ttlMillis(values[_ttl]);
      // An emptied TTL cell means "no expiry", which is PERSIST rather than an
      // expiry of zero — and an expiry of zero deletes the key.
      await _send(ttl == null
          ? <String>['PERSIST', key]
          : <String>['PEXPIRE', key, '$ttl']);
    }

    if (values.containsKey(_type) || values.containsKey(_size)) {
      throw const QueryError(
        'A key\'s type and size are what it is, not settings. Change the '
        'value and they follow.',
      );
    }

    return 1;
  }

  @override
  Future<int> deleteRow(ContainerRef container, RowId id) async {
    final key = id.fields[_key]?.display() ?? '';
    if (key.isEmpty) {
      throw const QueryError('A key name is required to delete a key.');
    }
    await _select(_dbOf(container));
    final reply = await _send(<String>['DEL', key]);
    return reply is int ? reply : 0;
  }

  /// The TTL cell as milliseconds, or null for "no expiry".
  int? _ttlMillis(CellValue? cell) {
    if (cell == null || cell is NullCell) return null;
    final seconds = switch (cell) {
      NumCell(:final value) => value.toDouble(),
      _ => double.tryParse(cell.display()),
    };
    if (seconds == null) {
      throw QueryError('"${cell.display()}" is not a number of seconds.');
    }
    if (seconds <= 0) {
      throw const QueryError(
        'A TTL of zero or less would delete the key. Clear the cell for no '
        'expiry, or delete the row to delete the key.',
      );
    }
    return (seconds * 1000).round();
  }

  String _writeCommandFor(String type) => switch (type) {
        'list' => 'LSET, LPUSH or RPUSH',
        'set' => 'SADD or SREM',
        'hash' => 'HSET or HDEL',
        'zset' => 'ZADD or ZREM',
        'stream' => 'XADD',
        _ => 'the one for its module',
      };

  // --- Schema --------------------------------------------------------------

  /// The five things known about every key.
  ///
  /// Not inferred from a sample the way Mongo's is: Redis tells you a key's
  /// type and length directly, so this shape is the same for every database on
  /// every server, and it is fixed rather than discovered.
  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async =>
      ContainerSchema(
        container: container,
        columns: const <ColumnSchema>[
          ColumnSchema(
            name: _key,
            typeLabel: 'key',
            nullable: false,
            isPrimaryKey: true,
          ),
          ColumnSchema(name: _type, typeLabel: 'type', nullable: false),
          ColumnSchema(name: _ttl, typeLabel: 'seconds'),
          ColumnSchema(name: _size, typeLabel: 'length'),
          ColumnSchema(name: _value, typeLabel: 'preview'),
        ],
      );
}
