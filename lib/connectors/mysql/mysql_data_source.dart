import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart';

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../data_source.dart';
import '../sql_common/sql_query_builder.dart';
import 'mysql_dialect.dart';
import 'mysql_ssl.dart';

class MysqlDataSource extends DataSource
    with RawQueryable, Writable, SchemaReadable, SchemaMutable, Transactional {
  MysqlDataSource({required this.record, required this.secrets});

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;
  MySQLConnection? _conn;
  String? _activeDb;

  static final _builder = SqlQueryBuilder(
    quote: myQuoteIdent,
    paramPlaceholder: myPlaceholder,
  );

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.mysql;
  @override
  Set<Capability> get capabilities => const {
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
        Capability.schemaMutate,
        Capability.transactions,
      };

  MySQLConnection get _c {
    final c = _conn;
    if (c == null) throw const ConnectError('Not connected');
    return c;
  }

  /// How this connection is configured to treat transport security.
  ///
  /// See [MysqlSslMode] for why there are two modes rather than three.
  MysqlSslMode get sslMode => MysqlSslMode.fromConfig(
    record.config['sslMode'],
    legacySecure: record.config['secure'],
  );

  @override
  Future<void> connect() async {
    final host = record.config['host'] as String? ?? 'localhost';
    final port = (record.config['port'] as num?)?.toInt() ?? 3306;
    final database = record.config['database'] as String?;
    final username = record.config['username'] as String? ?? 'root';
    final ssl = sslMode;
    try {
      _conn = await MySQLConnection.createConnection(
        host: host,
        port: port,
        userName: username,
        password: secrets?.password ?? '',
        databaseName: database,
        // `secure: true` gets TLS without certificate verification, and that is
        // all this driver has — the form says so where the mode is chosen, and
        // [MysqlSslMode] records why. Do not read this as verified transport.
        secure: ssl.encrypts,
      );
      await _conn!.connect();
      _activeDb = database;
    } catch (e, st) {
      throw ConnectError('MySQL connect failed: $e', cause: e, stack: st);
    }
  }

  @override
  Future<void> disconnect() async {
    final c = _conn;
    _conn = null;
    if (c != null) await c.close();
  }

  @override
  Future<void> ping() async {
    await _c.execute('SELECT 1');
  }

  @override
  Future<void> dispose() => disconnect();

  Future<IResultSet> _exec(String sql, [List<Object?> params = const []]) async {
    if (params.isEmpty) {
      return _c.execute(sql);
    }
    final stmt = await _c.prepare(sql);
    try {
      return await stmt.execute(params);
    } finally {
      await stmt.deallocate();
    }
  }

  RowData _rowToData(ResultSetRow row, List<String> cols) {
    final typed = row.typedAssoc();
    return {
      for (final c in cols) c: CellValue.fromDynamic(typed[c]),
    };
  }

  List<String> _colsOf(IResultSet r) => r.cols.map((c) => c.name).toList();

  @override
  Future<List<ContainerRef>> listContainers() async {
    final r = await _exec(
      'SELECT table_schema, table_name, table_type '
      'FROM information_schema.tables '
      'WHERE table_schema = DATABASE() '
      'ORDER BY table_name',
    );
    return [
      for (final row in r.rows)
        ContainerRef(
          name: row.colByName('table_name') ?? row.colAt(1) ?? '?',
          namespace: row.colByName('table_schema') ?? _activeDb,
          subtype: (row.colByName('table_type') ?? '').contains('VIEW')
              ? 'view'
              : 'table',
        ),
    ];
  }

  String _qualifiedFor(ContainerRef c) => myQuoteQualified(c.namespace, c.name);

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    final built = _builder.buildSelect(_qualifiedFor(container), spec);
    final r = await _exec(built.sql, built.params);
    final cols = _colsOf(r);
    final rows = [for (final row in r.rows) _rowToData(row, cols)];
    final more = rows.length == spec.limit;
    return Page(
      items: rows,
      nextCursor: more ? (spec.offset + spec.limit).toString() : null,
    );
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    final preds = id.fields.keys.map((c) => '${myQuoteIdent(c)} = ?').join(' AND ');
    final params = id.fields.values.map((v) => v.toBindable()).toList();
    final r = await _exec(
      'SELECT * FROM ${_qualifiedFor(container)} WHERE $preds LIMIT 1',
      params,
    );
    if (r.rows.isEmpty) return null;
    final cols = _colsOf(r);
    return _rowToData(r.rows.first, cols);
  }

  @override
  Future<QueryResult> runRawQuery(String text,
      [List<Object?> params = const []]) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _exec(text, params);
      final cols = _colsOf(r);
      if (cols.isEmpty) {
        return QueryResult(
          columns: const [],
          rows: const [],
          affectedRows: r.affectedRows.toInt(),
          elapsed: sw.elapsed,
        );
      }
      return QueryResult(
        columns: cols,
        rows: [for (final row in r.rows) _rowToData(row, cols)],
        affectedRows: r.affectedRows.toInt(),
        elapsed: sw.elapsed,
      );
    } on MySQLServerException catch (e, st) {
      throw QueryError(e.message, cause: e, stack: st);
    } catch (e, st) {
      throw QueryError(e.toString(), cause: e, stack: st);
    }
  }

  @override
  Future<RowId> insertRow(
      ContainerRef container, Map<String, CellValue> values) async {
    if (values.isEmpty) {
      throw const QueryError('No values supplied for insert');
    }
    final cols = values.keys.map(myQuoteIdent).join(', ');
    final phs = List.filled(values.length, '?').join(', ');
    final params = values.values.map((v) => v.toBindable()).toList();
    final r = await _exec(
      'INSERT INTO ${_qualifiedFor(container)} ($cols) VALUES ($phs)',
      params,
    );
    final lastId = r.lastInsertID;
    if (lastId > BigInt.zero) {
      return RowId({'id': NumCell(lastId.toInt())});
    }
    return const RowId({});
  }

  @override
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values) async {
    if (values.isEmpty) return 0;
    final setExpr =
        values.keys.map((c) => '${myQuoteIdent(c)} = ?').join(', ');
    final whereExpr =
        id.fields.keys.map((c) => '${myQuoteIdent(c)} = ?').join(' AND ');
    final params = [
      ...values.values.map((v) => v.toBindable()),
      ...id.fields.values.map((v) => v.toBindable()),
    ];
    final r = await _exec(
      'UPDATE ${_qualifiedFor(container)} SET $setExpr WHERE $whereExpr',
      params,
    );
    return r.affectedRows.toInt();
  }

  @override
  Future<int> deleteRow(ContainerRef container, RowId id) async {
    final whereExpr =
        id.fields.keys.map((c) => '${myQuoteIdent(c)} = ?').join(' AND ');
    final params = id.fields.values.map((v) => v.toBindable()).toList();
    final r = await _exec(
      'DELETE FROM ${_qualifiedFor(container)} WHERE $whereExpr',
      params,
    );
    return r.affectedRows.toInt();
  }

  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async {
    final ns = container.namespace ?? _activeDb;
    if (ns == null) {
      throw const QueryError('No active database for schema lookup');
    }
    final cols = await _exec(
      'SELECT column_name, column_type, is_nullable, column_default, column_key '
      'FROM information_schema.columns '
      'WHERE table_schema = ? AND table_name = ? '
      'ORDER BY ordinal_position',
      [ns, container.name],
    );
    return ContainerSchema(
      container: container,
      columns: [
        for (final row in cols.rows)
          ColumnSchema(
            name: row.colByName('column_name') ?? row.colAt(0) ?? '?',
            typeLabel: row.colByName('column_type') ?? row.colAt(1) ?? '',
            nullable:
                (row.colByName('is_nullable') ?? 'YES').toUpperCase() == 'YES',
            isPrimaryKey: (row.colByName('column_key') ?? '') == 'PRI',
            defaultExpr: row.colByName('column_default'),
          ),
      ],
    );
  }

  @override
  Future<void> createContainer(ContainerSchema schema) async {
    final cols = schema.columns.map((c) {
      final parts = <String>[myQuoteIdent(c.name), c.typeLabel];
      if (!c.nullable) parts.add('NOT NULL');
      if (c.isPrimaryKey) parts.add('PRIMARY KEY');
      if (c.defaultExpr != null) parts.add('DEFAULT ${c.defaultExpr}');
      return parts.join(' ');
    }).join(', ');
    await _c.execute('CREATE TABLE ${_qualifiedFor(schema.container)} ($cols)');
  }

  @override
  Future<void> dropContainer(ContainerRef container) async {
    await _c.execute('DROP TABLE ${_qualifiedFor(container)}');
  }

  @override
  Future<void> alterColumn(
      ContainerRef container, String columnName, ColumnSchema newDef) async {
    final nullPart = newDef.nullable ? 'NULL' : 'NOT NULL';
    await _c.execute(
      'ALTER TABLE ${_qualifiedFor(container)} '
      'CHANGE COLUMN ${myQuoteIdent(columnName)} '
      '${myQuoteIdent(newDef.name)} ${newDef.typeLabel} $nullPart'
      '${newDef.defaultExpr != null ? ' DEFAULT ${newDef.defaultExpr}' : ''}',
    );
  }

  @override
  Future<void> beginTx() async => _c.execute('START TRANSACTION');
  @override
  Future<void> commit() async => _c.execute('COMMIT');
  @override
  Future<void> rollback() async => _c.execute('ROLLBACK');
}
