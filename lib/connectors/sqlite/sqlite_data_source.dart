import 'package:sqlite3/sqlite3.dart' hide Row;

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../services/file_access.dart';
import '../data_source.dart';
import '../sql_common/sql_query_builder.dart';

class SqliteDataSource extends DataSource
    with RawQueryable, Writable, SchemaReadable, SchemaMutable, Transactional {
  SqliteDataSource({required this.record, FileAccess? fileAccess})
      : fileAccess = fileAccess ?? FileAccess.instance;

  final ConnectionRecord record;
  final FileAccess fileAccess;
  Database? _db;

  /// Set while a sandbox grant is held open, and the argument to the revoke
  /// that has to follow it.
  String? _accessToken;

  final Map<String, Object?> _corrected = {};

  @override
  Map<String, Object?> get correctedConfig => Map.unmodifiable(_corrected);

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.sqlite;
  @override
  Set<Capability> get capabilities => const {
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
        Capability.schemaMutate,
        Capability.transactions,
      };

  String get _configuredPath {
    final p = record.config[FileAccess.pathKey];
    if (p is! String || p.isEmpty) {
      throw const ConnectError('SQLite filePath missing');
    }
    return p;
  }

  String get _bookmark {
    final b = record.config[FileAccess.bookmarkKey];
    return b is String ? b : '';
  }

  Database get _open {
    final db = _db;
    if (db == null) throw const ConnectError('Not connected');
    return db;
  }

  @override
  Future<void> connect() async {
    final path = await _acquirePath();
    try {
      _db = sqlite3.open(path);
      // Validate readability.
      _db!.select('SELECT 1');
    } catch (e, st) {
      await _release();
      // A file the sandbox would not re-grant reads as a plain open failure,
      // which sends people looking at the file instead of at the permission.
      final hint = _accessDenied
          ? ' — permission to reopen it was not granted, so edit the '
              'connection and pick the file again'
          : '';
      throw ConnectError('Failed to open $path$hint', cause: e, stack: st);
    }
  }

  /// Whether a stored bookmark existed but would not produce access.
  bool _accessDenied = false;

  /// Resolves the path to open, re-acquiring sandbox access first where that is
  /// a thing. A connection saved on a previous launch has a bookmark but no
  /// live permission; without redeeming it the open fails on macOS even though
  /// the path is perfectly correct.
  ///
  /// A bookmark that will not resolve is not treated as fatal on its own: the
  /// file may be reachable anyway — an unsandboxed build, or a path the app can
  /// always read — and it costs nothing to let the open be the judge of that.
  Future<String> _acquirePath() async {
    final configured = _configuredPath;
    final bookmark = _bookmark;
    if (bookmark.isEmpty || !fileAccess.isSupported) return configured;
    final grant = await fileAccess.grant(bookmark);
    if (grant == null) {
      log.w('SQLite ${record.name}: bookmark for $configured did not resolve');
      _accessDenied = true;
      return configured;
    }
    _accessDenied = false;
    _accessToken = grant.token;
    // The bookmark, not the path, is the authority on where the file lives: a
    // moved file resolves to its new home, and the saved path is then simply
    // wrong. Report both corrections so the record can catch up.
    if (grant.path != configured) {
      log.i('SQLite ${record.name}: file moved to ${grant.path}');
      _corrected[FileAccess.pathKey] = grant.path;
    }
    if (grant.bookmark != null) {
      _corrected[FileAccess.bookmarkKey] = grant.bookmark;
    }
    return grant.path;
  }

  Future<void> _release() async {
    final token = _accessToken;
    _accessToken = null;
    await fileAccess.revoke(token);
  }

  @override
  Future<void> disconnect() async {
    _db?.dispose();
    _db = null;
    await _release();
  }

  @override
  Future<void> ping() async {
    _open.select('SELECT 1');
  }

  @override
  Future<void> dispose() => disconnect();

  static final _builder =
      SqlQueryBuilder(quote: (i) => '"${i.replaceAll('"', '""')}"');

  @override
  Future<List<ContainerRef>> listContainers() async {
    final rs = _open.select(
      'SELECT name, type FROM sqlite_master '
      "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
      'ORDER BY type, name',
    );
    return rs
        .map((r) => ContainerRef(name: r['name'] as String, subtype: r['type'] as String))
        .toList();
  }

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    final built = _builder.buildSelect(
      '"${container.name.replaceAll('"', '""')}"',
      spec,
    );
    final rs = _open.select(built.sql, built.params);
    final rows = rs.map(_toRow).toList();
    final more = rows.length == spec.limit;
    return Page(
      items: rows,
      nextCursor: more ? (spec.offset + spec.limit).toString() : null,
    );
  }

  RowData _toRow(dynamic resultRow) {
    final map = (resultRow as Map).cast<String, Object?>();
    return {
      for (final e in map.entries) e.key: CellValue.fromDynamic(e.value),
    };
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    final preds = id.fields.entries.map((e) => '"${e.key}" = ?').join(' AND ');
    final params = id.fields.values.map((v) => v.toBindable()).toList();
    final rs = _open.select(
      'SELECT * FROM "${container.name}" WHERE $preds LIMIT 1',
      params,
    );
    if (rs.isEmpty) return null;
    return _toRow(rs.first);
  }

  @override
  Future<QueryResult> runRawQuery(String text, [List<Object?> params = const []]) async {
    final sw = Stopwatch()..start();
    try {
      final stmt = _open.prepare(text);
      try {
        if (stmt.parameterCount > 0 || params.isNotEmpty) {
          final rs = stmt.select(params);
          return QueryResult(
            columns: rs.columnNames,
            rows: rs.map(_toRow).toList(),
            elapsed: sw.elapsed,
          );
        }
        // Try as SELECT first; if it has rows, return them; else execute.
        if (text.trimLeft().toUpperCase().startsWith('SELECT') ||
            text.trimLeft().toUpperCase().startsWith('WITH') ||
            text.trimLeft().toUpperCase().startsWith('PRAGMA')) {
          final rs = stmt.select();
          return QueryResult(
            columns: rs.columnNames,
            rows: rs.map(_toRow).toList(),
            elapsed: sw.elapsed,
          );
        }
        stmt.execute();
        return QueryResult(
          columns: const [],
          rows: const [],
          affectedRows: _open.updatedRows,
          elapsed: sw.elapsed,
        );
      } finally {
        stmt.dispose();
      }
    } on SqliteException catch (e, st) {
      throw QueryError(e.message, cause: e, stack: st);
    }
  }

  @override
  Future<RowId> insertRow(ContainerRef container, Map<String, CellValue> values) async {
    if (values.isEmpty) {
      throw const QueryError('No values supplied for insert');
    }
    final cols = values.keys.map((c) => '"$c"').join(', ');
    final ph = List.filled(values.length, '?').join(', ');
    final params = values.values.map((v) => v.toBindable()).toList();
    _open.execute(
      'INSERT INTO "${container.name}" ($cols) VALUES ($ph)',
      params,
    );
    final rowId = _open.lastInsertRowId;
    // Best effort: return rowid for tables with an INTEGER PRIMARY KEY alias.
    return RowId({'rowid': NumCell(rowId)});
  }

  @override
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values) async {
    if (values.isEmpty) return 0;
    final setExpr = values.keys.map((c) => '"$c" = ?').join(', ');
    final whereExpr = id.fields.keys.map((c) => '"$c" = ?').join(' AND ');
    final params = [
      ...values.values.map((v) => v.toBindable()),
      ...id.fields.values.map((v) => v.toBindable()),
    ];
    _open.execute(
      'UPDATE "${container.name}" SET $setExpr WHERE $whereExpr',
      params,
    );
    return _open.updatedRows;
  }

  @override
  Future<int> deleteRow(ContainerRef container, RowId id) async {
    final whereExpr = id.fields.keys.map((c) => '"$c" = ?').join(' AND ');
    final params = id.fields.values.map((v) => v.toBindable()).toList();
    _open.execute(
      'DELETE FROM "${container.name}" WHERE $whereExpr',
      params,
    );
    return _open.updatedRows;
  }

  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async {
    final cols = _open.select('PRAGMA table_info("${container.name}")');
    final columns = cols.map((r) {
      return ColumnSchema(
        name: r['name'] as String,
        typeLabel: (r['type'] as String?) ?? '',
        nullable: (r['notnull'] as int? ?? 0) == 0,
        isPrimaryKey: (r['pk'] as int? ?? 0) > 0,
        defaultExpr: r['dflt_value']?.toString(),
      );
    }).toList();
    return ContainerSchema(container: container, columns: columns);
  }

  @override
  Future<void> createContainer(ContainerSchema schema) async {
    final cols = schema.columns.map((c) {
      final parts = <String>['"${c.name}"', c.typeLabel];
      if (!c.nullable) parts.add('NOT NULL');
      if (c.isPrimaryKey) parts.add('PRIMARY KEY');
      if (c.defaultExpr != null) parts.add('DEFAULT ${c.defaultExpr}');
      return parts.join(' ');
    }).join(', ');
    _open.execute('CREATE TABLE "${schema.container.name}" ($cols)');
  }

  @override
  Future<void> dropContainer(ContainerRef container) async {
    _open.execute('DROP TABLE "${container.name}"');
  }

  @override
  Future<void> alterColumn(
      ContainerRef container, String columnName, ColumnSchema newDef) async {
    // SQLite ALTER is limited; only rename + add column are widely safe.
    if (columnName == newDef.name) {
      // Type changes require table rebuild — out of scope for v0.1.
      throw const QueryError(
          'SQLite cannot alter a column in place; rebuild the table.');
    }
    _open.execute(
      'ALTER TABLE "${container.name}" RENAME COLUMN "$columnName" TO "${newDef.name}"',
    );
  }

  @override
  Future<void> beginTx() async => _open.execute('BEGIN');
  @override
  Future<void> commit() async => _open.execute('COMMIT');
  @override
  Future<void> rollback() async => _open.execute('ROLLBACK');
}
