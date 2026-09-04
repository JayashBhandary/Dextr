import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../data_source.dart';
import '../sql_common/sql_query_builder.dart';
import 'snowflake_types.dart';

/// Snowflake, over the SQL REST API.
///
/// There is no Snowflake wire-protocol driver for Dart, and there is no way to
/// write one: the protocol the official drivers speak is not documented for
/// third parties. `/api/v2/statements` is the documented alternative, and it is
/// a good fit for what this application does — one statement, one result — but
/// it is worth knowing what the transport costs, because two of the things a
/// connector normally offers are missing for a reason and not by oversight:
///
/// * **No transactions.** A transaction is a session, and every POST here is
///   its own session; there is nowhere for a `BEGIN` to live between two
///   requests. `Transactional` is therefore not mixed in, so the UI never
///   offers a transaction that would silently not be one.
/// * **No key-pair authentication.** See [SnowflakeAuth] — it needs RSA
///   signing, which Dart has no primitive for.
///
/// A statement that takes longer than the API's synchronous window comes back
/// as `202 Accepted` with a handle instead of a result, and is then polled;
/// [_poll] is that loop.
class SnowflakeDataSource extends DataSource
    with RawQueryable, Writable, SchemaReadable, SchemaMutable {
  SnowflakeDataSource({required this.record, required this.secrets});

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;
  Dio? _dio;

  static const _uuid = Uuid();

  /// How long a statement is given before Snowflake cancels it, in seconds.
  /// Also the ceiling on [_poll]: past this the server has given up too.
  static const _statementTimeout = 120;

  /// How many rows are read out of a multi-partition result.
  ///
  /// A REST result arrives in partitions: the first inline, the rest one HTTP
  /// request each. A `SELECT` over a warehouse table can be a hundred million
  /// rows, and fetching all of them to render in a grid is neither possible nor
  /// useful, so the read stops here. Browse pages with `LIMIT`/`OFFSET` and
  /// never reaches this; a raw query that does should say `LIMIT` itself.
  static const _maxRawRows = 10000;

  static final _builder = SqlQueryBuilder(quote: ansiQuoteIdent);

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.snowflake;
  @override
  Set<Capability> get capabilities => const {
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
        Capability.schemaMutate,
      };

  String get _account => (record.config['account'] as String?) ?? '';
  String? get _warehouse => _nonEmpty(record.config['warehouse']);
  String? get _database => _nonEmpty(record.config['database']);
  String? get _schema => _nonEmpty(record.config['schema']);
  String? get _role => _nonEmpty(record.config['role']);
  SnowflakeAuth get _auth => SnowflakeAuth.fromName(record.config['authMode']);

  static String? _nonEmpty(Object? raw) {
    final s = raw as String?;
    if (s == null || s.trim().isEmpty) return null;
    return s.trim();
  }

  Dio get _open {
    final d = _dio;
    if (d == null) throw const ConnectError('Not connected');
    return d;
  }

  @override
  Future<void> connect() async {
    if (_account.isEmpty) {
      throw const ConnectError('Snowflake account identifier missing');
    }
    final token = secrets?.bearerToken;
    if (token == null || token.isEmpty) {
      throw const ConnectError('Snowflake token missing');
    }
    _dio = Dio(BaseOptions(
      baseUrl: 'https://${snowflakeHost(_account)}/api/v2/',
      headers: <String, Object?>{
        'Authorization': 'Bearer $token',
        'X-Snowflake-Authorization-Token-Type': _auth.tokenTypeHeader,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': 'Dextr',
      },
      // Every status is read by hand: Snowflake puts a usable message in the
      // body of a 4xx, and a 202 is a success that is not finished yet.
      validateStatus: (_) => true,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: _statementTimeout + 30),
    ));
    await ping();
  }

  @override
  Future<void> disconnect() async {
    _dio?.close(force: true);
    _dio = null;
  }

  @override
  Future<void> ping() async {
    await _statement('SELECT 1');
  }

  @override
  Future<void> dispose() => disconnect();

  // --- The API -------------------------------------------------------------

  /// Run one statement and return everything the API said about it.
  Future<_SfResult> _statement(
    String sql, {
    List<Object?> params = const [],
    int maxRows = _maxRawRows,
  }) async {
    final body = <String, Object?>{
      'statement': sql,
      'timeout': _statementTimeout,
      if (_warehouse != null) 'warehouse': _warehouse,
      if (_database != null) 'database': _database,
      if (_schema != null) 'schema': _schema,
      if (_role != null) 'role': _role,
      if (params.isNotEmpty)
        'bindings': <String, Object?>{
          for (var i = 0; i < params.length; i++)
            '${i + 1}': snowflakeBinding(params[i]),
        },
    };

    final Response<dynamic> res;
    try {
      res = await _open.post<dynamic>(
        'statements',
        // A request id makes the POST idempotent on Snowflake's side, so a
        // retried request cannot run the statement a second time.
        queryParameters: <String, Object?>{'requestId': _uuid.v4()},
        data: body,
      );
    } on DioException catch (e, st) {
      throw QueryError('Snowflake request failed: ${e.message}',
          cause: e, stack: st);
    }

    final payload = _payloadOrThrow(res);
    if (res.statusCode == 202) {
      final handle = payload['statementHandle'] as String?;
      if (handle == null) {
        throw const QueryError(
            'Snowflake accepted the statement but returned no handle');
      }
      return _readResult(await _poll(handle), handle, maxRows);
    }
    return _readResult(
        payload, payload['statementHandle'] as String?, maxRows);
  }

  /// Wait for an asynchronous statement, then return its finished payload.
  Future<Map<String, Object?>> _poll(String handle) async {
    final deadline = DateTime.now().add(
      const Duration(seconds: _statementTimeout),
    );
    var wait = const Duration(milliseconds: 500);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(wait);
      // Backs off to two seconds: a query that is going to take a minute is
      // not helped by being asked about it a hundred and twenty times.
      wait = wait * 2 > const Duration(seconds: 2)
          ? const Duration(seconds: 2)
          : wait * 2;
      final res = await _open.get<dynamic>('statements/$handle');
      final payload = _payloadOrThrow(res);
      if (res.statusCode != 202) return payload;
    }
    throw QueryError(
      'Snowflake did not finish the statement within '
      '${_statementTimeout}s. It may still be running; the handle is $handle.',
    );
  }

  /// The body of a response, or the error it describes.
  Map<String, Object?> _payloadOrThrow(Response<dynamic> res) {
    final data = res.data;
    final payload = data is Map
        ? Map<String, Object?>.from(data)
        : <String, Object?>{'message': data?.toString()};
    final status = res.statusCode ?? 0;
    if (status == 200 || status == 202) return payload;

    final message = payload['message'] as String? ?? 'HTTP $status';
    final code = payload['code'] as String?;
    final detail = code == null ? message : '$message (code $code)';
    if (status == 401 || status == 403) {
      throw ConnectError('Snowflake rejected the token: $detail');
    }
    throw QueryError('Snowflake: $detail');
  }

  /// Turn a finished payload into columns and rows, following partitions.
  Future<_SfResult> _readResult(
    Map<String, Object?> payload,
    String? handle,
    int maxRows,
  ) async {
    final meta = payload['resultSetMetaData'] as Map?;
    final rowType = (meta?['rowType'] as List?) ?? const [];
    final columns = <SnowflakeColumn>[
      for (final c in rowType)
        SnowflakeColumn.fromJson(Map<String, Object?>.from(c as Map)),
    ];
    final rows = <RowData>[];
    _appendRows(rows, payload['data'], columns, maxRows);

    // Partition 0 came inline; the rest are one GET each.
    final partitions = (meta?['partitionInfo'] as List?)?.length ?? 1;
    for (var p = 1; p < partitions && rows.length < maxRows; p++) {
      if (handle == null) break;
      final res = await _open.get<dynamic>(
        'statements/$handle',
        queryParameters: <String, Object?>{'partition': p},
      );
      _appendRows(
          rows, _payloadOrThrow(res)['data'], columns, maxRows);
    }

    return _SfResult(
      columns: columns,
      rows: rows,
      numRows: (meta?['numRows'] as num?)?.toInt(),
    );
  }

  void _appendRows(
    List<RowData> into,
    Object? data,
    List<SnowflakeColumn> columns,
    int maxRows,
  ) {
    if (data is! List) return;
    for (final raw in data) {
      if (into.length >= maxRows) return;
      if (raw is! List) continue;
      final row = <String, CellValue>{};
      for (var i = 0; i < columns.length; i++) {
        row[columns[i].name] =
            snowflakeCell(i < raw.length ? raw[i] : null, columns[i]);
      }
      into.add(row);
    }
  }

  // --- Containers and rows -------------------------------------------------

  String _qualified(ContainerRef c) => <String>[
        if (_database != null) ansiQuoteIdent(_database!),
        ansiQuoteIdent(c.namespace ?? _schema ?? 'PUBLIC'),
        ansiQuoteIdent(c.name),
      ].join('.');

  @override
  Future<List<ContainerRef>> listContainers() async {
    final result = await _statement(
      'SELECT table_schema, table_name, table_type '
      'FROM information_schema.tables '
      "WHERE table_schema <> 'INFORMATION_SCHEMA' "
      'ORDER BY table_schema, table_name',
    );
    return [
      for (final row in result.rows)
        ContainerRef(
          name: row['TABLE_NAME']?.display() ?? '',
          namespace: row['TABLE_SCHEMA']?.display(),
          subtype: (row['TABLE_TYPE']?.display() ?? '').contains('VIEW')
              ? 'view'
              : 'table',
        ),
    ];
  }

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    final built = _builder.buildSelect(_qualified(container), spec);
    final result =
        await _statement(built.sql, params: built.params, maxRows: spec.limit);
    final more = result.rows.length == spec.limit;
    return Page(
      items: result.rows,
      nextCursor: more ? (spec.offset + spec.limit).toString() : null,
      totalHint: result.numRows,
    );
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    if (id.fields.isEmpty) return null;
    final preds = <String>[];
    final params = <Object?>[];
    for (final e in id.fields.entries) {
      preds.add('${ansiQuoteIdent(e.key)} = ?');
      params.add(e.value.toBindable());
    }
    final result = await _statement(
      'SELECT * FROM ${_qualified(container)} '
      'WHERE ${preds.join(' AND ')} LIMIT 1',
      params: params,
      maxRows: 1,
    );
    return result.rows.isEmpty ? null : result.rows.first;
  }

  @override
  Future<QueryResult> runRawQuery(String text,
      [List<Object?> params = const []]) async {
    final sw = Stopwatch()..start();
    final result = await _statement(text, params: params);
    return QueryResult(
      columns: [for (final c in result.columns) c.name],
      rows: result.rows,
      affectedRows: result.affectedRows,
      elapsed: sw.elapsed,
    );
  }

  // --- Writes --------------------------------------------------------------

  @override
  Future<RowId> insertRow(
      ContainerRef container, Map<String, CellValue> values) async {
    if (values.isEmpty) {
      throw const QueryError('No values supplied for insert');
    }
    final cols = values.keys.map(ansiQuoteIdent).join(', ');
    final phs = List.filled(values.length, '?').join(', ');
    await _statement(
      'INSERT INTO ${_qualified(container)} ($cols) VALUES ($phs)',
      params: values.values.map((v) => v.toBindable()).toList(),
    );
    // Snowflake's INSERT has no RETURNING, so the id is what was sent — the
    // same honesty Redshift needs, for the same reason.
    return RowId(Map.of(values));
  }

  @override
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values) async {
    if (values.isEmpty) return 0;
    final setExpr =
        values.keys.map((c) => '${ansiQuoteIdent(c)} = ?').join(', ');
    final whereExpr =
        id.fields.keys.map((c) => '${ansiQuoteIdent(c)} = ?').join(' AND ');
    final result = await _statement(
      'UPDATE ${_qualified(container)} SET $setExpr WHERE $whereExpr',
      params: [
        ...values.values.map((v) => v.toBindable()),
        ...id.fields.values.map((v) => v.toBindable()),
      ],
    );
    return result.affectedRows ?? 0;
  }

  @override
  Future<int> deleteRow(ContainerRef container, RowId id) async {
    final whereExpr =
        id.fields.keys.map((c) => '${ansiQuoteIdent(c)} = ?').join(' AND ');
    final result = await _statement(
      'DELETE FROM ${_qualified(container)} WHERE $whereExpr',
      params: id.fields.values.map((v) => v.toBindable()).toList(),
    );
    return result.affectedRows ?? 0;
  }

  // --- Schema --------------------------------------------------------------

  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async {
    final schema = container.namespace ?? _schema ?? 'PUBLIC';
    final cols = await _statement(
      'SELECT column_name, data_type, is_nullable, column_default '
      'FROM information_schema.columns '
      'WHERE table_schema = ? AND table_name = ? '
      'ORDER BY ordinal_position',
      params: [schema, container.name],
    );
    final pks = await _primaryKeys(container);
    return ContainerSchema(
      container: container,
      columns: [
        for (final row in cols.rows)
          ColumnSchema(
            name: row['COLUMN_NAME']?.display() ?? '',
            typeLabel: row['DATA_TYPE']?.display() ?? '',
            nullable: (row['IS_NULLABLE']?.display() ?? 'YES').toUpperCase() ==
                'YES',
            isPrimaryKey: pks.contains(row['COLUMN_NAME']?.display()),
            defaultExpr: switch (row['COLUMN_DEFAULT']) {
              null || NullCell() => null,
              final CellValue v => v.display(),
            },
          ),
      ],
    );
  }

  /// The primary-key columns, from `SHOW PRIMARY KEYS`.
  ///
  /// Snowflake's `information_schema` has no `key_column_usage`, so a `SHOW` is
  /// the only way to ask. It needs a privilege the reader may not have, and a
  /// missing answer costs a key marker in the schema pane rather than the
  /// schema itself — so a failure here is swallowed instead of failing the
  /// whole read.
  Future<Set<String>> _primaryKeys(ContainerRef container) async {
    try {
      final result = await _statement(
        'SHOW PRIMARY KEYS IN TABLE ${_qualified(container)}',
      );
      return {
        for (final row in result.rows)
          if (row['column_name'] != null) row['column_name']!.display(),
      };
    } on DextrError {
      return const <String>{};
    }
  }

  @override
  Future<void> createContainer(ContainerSchema schema) async {
    final cols = schema.columns.map((c) {
      final parts = <String>[ansiQuoteIdent(c.name), c.typeLabel];
      if (!c.nullable) parts.add('NOT NULL');
      if (c.isPrimaryKey) parts.add('PRIMARY KEY');
      if (c.defaultExpr != null) parts.add('DEFAULT ${c.defaultExpr}');
      return parts.join(' ');
    }).join(', ');
    await _statement('CREATE TABLE ${_qualified(schema.container)} ($cols)');
  }

  @override
  Future<void> dropContainer(ContainerRef container) async {
    await _statement('DROP TABLE ${_qualified(container)}');
  }

  @override
  Future<void> alterColumn(
      ContainerRef container, String columnName, ColumnSchema newDef) async {
    final table = _qualified(container);
    if (columnName != newDef.name) {
      await _statement('ALTER TABLE $table RENAME COLUMN '
          '${ansiQuoteIdent(columnName)} TO ${ansiQuoteIdent(newDef.name)}');
    }
    final column = ansiQuoteIdent(newDef.name);
    await _statement(
        'ALTER TABLE $table ALTER COLUMN $column SET DATA TYPE ${newDef.typeLabel}');
    await _statement('ALTER TABLE $table ALTER COLUMN $column '
        '${newDef.nullable ? 'DROP NOT NULL' : 'SET NOT NULL'}');
  }
}

/// One finished statement: its columns, its rows, and what it counted.
class _SfResult {
  const _SfResult({
    required this.columns,
    required this.rows,
    this.numRows,
  });

  final List<SnowflakeColumn> columns;
  final List<RowData> rows;
  final int? numRows;

  /// The row count a DML statement reports.
  ///
  /// Snowflake answers an `INSERT` with a one-cell result set whose column is
  /// called "number of rows inserted", so the count is read out of the result
  /// rather than from a field of its own.
  int? get affectedRows {
    if (columns.length != 1 || rows.length != 1) return null;
    final name = columns.first.name.toLowerCase();
    if (!name.startsWith('number of rows')) return null;
    final cell = rows.first.values.first;
    return cell is NumCell ? cell.value.toInt() : null;
  }
}
