import 'package:googleapis/bigquery/v2.dart' as bq;
import 'package:googleapis_auth/auth_io.dart' as ga;
import 'package:http/http.dart' as http;

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../data_source.dart';
import '../sql_common/sql_query_builder.dart';
import 'bigquery_value.dart';

/// Google BigQuery, over the REST API with a service-account key — reached the
/// same way Firestore is, and for the same reason: there is no wire protocol to
/// speak, the REST API *is* the interface.
///
/// Two things about BigQuery shape this connector, and both are about money and
/// safety rather than about protocol.
///
/// **Browsing a table is free; querying it is not.** `tabledata.list` reads
/// rows straight out of storage and is not billed as a query at all, while a
/// `SELECT *` over the same table scans it and is billed by the byte. So an
/// unfiltered, unsorted browse — which is what opening a table in the rail does
/// — goes through `tabledata.list`, and SQL is only generated when the reader
/// asks for something storage cannot answer: a filter, or an order. The switch
/// is in [listRows], and it is the difference between opening a petabyte table
/// costing nothing and costing several thousand dollars.
///
/// **Every query is capped.** [_maximumBytesBilled] is sent with each query,
/// and BigQuery refuses — before running anything — a query that would scan
/// more than it. A typo in a `WHERE` clause against a partitioned table is a
/// bill, not a mistake, and the cap turns it back into a mistake. It is a field
/// on the connection so it can be raised deliberately.
///
/// The grid is read-only here. BigQuery has no enforced primary key, so there
/// is no expression that identifies exactly one row for an `UPDATE` or a
/// `DELETE` — a `WHERE` matching every column would happily rewrite two
/// identical rows. DML is still available in the Query pane, where what it
/// matches is written out and visible.
class BigqueryDataSource extends DataSource with RawQueryable, SchemaReadable {
  BigqueryDataSource({required this.record, required this.secrets});

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;

  http.Client? _client;
  bq.BigqueryApi? _api;

  /// How many datasets the rail lists. A project with more than this has more
  /// than a rail can show anyway, and each one costs a `tables.list` call.
  static const _maxDatasets = 200;
  static const _maxTablesPerDataset = 500;

  /// How long `jobs.query` waits inline before the job is polled instead.
  static const _inlineTimeout = Duration(seconds: 30);

  static final _builder = SqlQueryBuilder(quote: _backtick);

  /// BigQuery quotes an identifier with backticks, not double quotes, and a
  /// backtick cannot be escaped inside one — so a name containing one is
  /// rejected rather than smuggled into the SQL.
  static String _backtick(String identifier) {
    if (identifier.contains('`')) {
      throw QueryError('BigQuery cannot quote the name "$identifier": '
          'a backtick has no escape inside a quoted identifier.');
    }
    return '`$identifier`';
  }

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.bigquery;
  @override
  Set<Capability> get capabilities => const {
        Capability.rawQuery,
        Capability.schemaRead,
      };

  String get _projectId =>
      (record.config['projectId'] as String?) ??
      (throw const ConnectError('BigQuery project ID missing'));

  /// The region a query and its dataset must agree on. Null means BigQuery
  /// works it out from the tables, which is right until a query names none.
  String? get _location {
    final raw = record.config['location'] as String?;
    return raw == null || raw.trim().isEmpty ? null : raw.trim();
  }

  /// The scan a query is allowed before BigQuery refuses it, in bytes.
  String? get _maximumBytesBilled {
    final raw = (record.config['maximumBytesBilled'] as num?)?.toInt();
    if (raw == null || raw <= 0) return null;
    return raw.toString();
  }

  bq.BigqueryApi get _open {
    final a = _api;
    if (a == null) throw const ConnectError('Not connected');
    return a;
  }

  @override
  Future<void> connect() async {
    try {
      final saJson = secrets?.serviceAccountJson;
      if (saJson == null || saJson.isEmpty) {
        throw const ConnectError('Service account JSON missing');
      }
      final creds = ga.ServiceAccountCredentials.fromJson(saJson);
      _client = await ga.clientViaServiceAccount(
        creds,
        <String>[bq.BigqueryApi.bigqueryScope],
      );
      _api = bq.BigqueryApi(_client!);
      await ping();
    } catch (e, st) {
      if (e is DextrError) rethrow;
      throw ConnectError('BigQuery connect failed: $e', cause: e, stack: st);
    }
  }

  @override
  Future<void> disconnect() async {
    _client?.close();
    _client = null;
    _api = null;
  }

  @override
  Future<void> ping() async {
    // Listing one dataset proves the key, the project and the scope, and reads
    // no table data, so it is billed as nothing.
    await _open.datasets.list(_projectId, maxResults: 1);
  }

  @override
  Future<void> dispose() => disconnect();

  // --- Containers ----------------------------------------------------------

  @override
  Future<List<ContainerRef>> listContainers() async {
    final datasets = await _open.datasets.list(
      _projectId,
      maxResults: _maxDatasets,
    );
    final out = <ContainerRef>[];
    for (final dataset in datasets.datasets ?? const <bq.DatasetListDatasets>[]) {
      final datasetId = dataset.datasetReference?.datasetId;
      if (datasetId == null) continue;
      final tables = await _open.tables.list(
        _projectId,
        datasetId,
        maxResults: _maxTablesPerDataset,
      );
      for (final table in tables.tables ?? const <bq.TableListTables>[]) {
        final tableId = table.tableReference?.tableId;
        if (tableId == null) continue;
        out.add(ContainerRef(
          name: tableId,
          namespace: datasetId,
          subtype: switch (table.type) {
            'VIEW' || 'MATERIALIZED_VIEW' => 'view',
            _ => 'table',
          },
        ));
      }
    }
    out.sort((a, b) => a.qualified.compareTo(b.qualified));
    return out;
  }

  String _qualified(ContainerRef c) =>
      '`$_projectId`.${_backtick(c.namespace ?? '')}.${_backtick(c.name)}';

  // --- Rows ----------------------------------------------------------------

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    // Storage can answer "the next hundred rows" and nothing else. Anything
    // with a filter or an order in it needs a query, and a query is billed.
    if (spec.where.isEmpty && spec.orderBy.isEmpty) {
      return _listFromStorage(container, spec);
    }
    return _listFromQuery(container, spec);
  }

  /// The free path: rows read straight out of table storage.
  Future<Page<RowData>> _listFromStorage(
      ContainerRef container, QuerySpec spec) async {
    final datasetId = container.namespace ?? '';
    final fields = await _fieldsOf(container);
    final data = await _open.tabledata.list(
      _projectId,
      datasetId,
      container.name,
      maxResults: spec.limit,
      // A cursor, when the previous page gave one, is cheaper and more stable
      // than an index; startIndex is the fallback for a jump.
      pageToken: spec.cursor,
      startIndex: spec.cursor == null && spec.offset > 0
          ? spec.offset.toString()
          : null,
    );
    return Page(
      items: [
        for (final row in data.rows ?? const <bq.TableRow>[])
          bigqueryRow(row.toJson(), fields),
      ],
      nextCursor: data.pageToken,
      totalHint: int.tryParse(data.totalRows ?? ''),
    );
  }

  /// The billed path: a filter or an order, so SQL.
  Future<Page<RowData>> _listFromQuery(
      ContainerRef container, QuerySpec spec) async {
    final built = _builder.buildSelect(_qualified(container), spec);
    final result = await _runQuery(built.sql, built.params, spec.limit);
    final more = result.rows.length == spec.limit;
    return Page(
      items: result.rows,
      nextCursor: more ? (spec.offset + spec.limit).toString() : null,
      totalHint: result.totalRows,
    );
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    if (id.fields.isEmpty) return null;
    final preds = <String>[];
    final params = <Object?>[];
    for (final e in id.fields.entries) {
      preds.add('${_backtick(e.key)} = ?');
      params.add(e.value.toBindable());
    }
    final result = await _runQuery(
      'SELECT * FROM ${_qualified(container)} '
      'WHERE ${preds.join(' AND ')} LIMIT 1',
      params,
      1,
    );
    return result.rows.isEmpty ? null : result.rows.first;
  }

  @override
  Future<QueryResult> runRawQuery(String text,
      [List<Object?> params = const []]) async {
    final sw = Stopwatch()..start();
    final result = await _runQuery(text, params, null);
    return QueryResult(
      columns: [for (final f in result.fields) f.name],
      rows: result.rows,
      affectedRows: result.affectedRows,
      elapsed: sw.elapsed,
    );
  }

  /// Run standard SQL, waiting for the job if it does not finish inline.
  Future<_BqResult> _runQuery(
      String sql, List<Object?> params, int? maxResults) async {
    final request = bq.QueryRequest()
      ..query = sql
      ..useLegacySql = false
      ..timeoutMs = _inlineTimeout.inMilliseconds
      ..maxResults = maxResults
      ..location = _location
      ..maximumBytesBilled = _maximumBytesBilled;
    if (params.isNotEmpty) {
      // Positional `?` parameters, which is what SqlQueryBuilder emits.
      request.parameterMode = 'POSITIONAL';
      request.queryParameters = [for (final p in params) _parameter(p)];
    }

    final bq.QueryResponse response;
    try {
      response = await _open.jobs.query(request, _projectId);
    } on bq.DetailedApiRequestError catch (e, st) {
      throw QueryError(_apiMessage(e), cause: e, stack: st);
    }
    _throwForErrors(response.errors);

    var fields = _fieldsFrom(response.schema);
    var rows = <RowData>[
      for (final row in response.rows ?? const <bq.TableRow>[])
        bigqueryRow(row.toJson(), fields),
    ];
    var totalRows = int.tryParse(response.totalRows ?? '');
    var affected = int.tryParse(response.numDmlAffectedRows ?? '');

    // A query that outran the inline timeout leaves a job to be collected.
    final jobId = response.jobReference?.jobId;
    if (response.jobComplete != true && jobId != null) {
      final finished = await _awaitJob(jobId, maxResults);
      _throwForErrors(finished.errors);
      fields = _fieldsFrom(finished.schema);
      rows = <RowData>[
        for (final row in finished.rows ?? const <bq.TableRow>[])
          bigqueryRow(row.toJson(), fields),
      ];
      totalRows = int.tryParse(finished.totalRows ?? '');
      affected = int.tryParse(finished.numDmlAffectedRows ?? '');
    }

    return _BqResult(
      fields: fields,
      rows: rows,
      totalRows: totalRows,
      affectedRows: affected,
    );
  }

  /// Block on a running job by asking for its results with a timeout.
  ///
  /// `getQueryResults` holds the request open until the job finishes or
  /// [_inlineTimeout] passes, so this is a long poll rather than a spin.
  Future<bq.GetQueryResultsResponse> _awaitJob(
      String jobId, int? maxResults) async {
    // Six waits of thirty seconds: past three minutes this is not a query
    // somebody is sitting in front of, and the job keeps running in BigQuery
    // whatever this does.
    for (var attempt = 0; attempt < 6; attempt++) {
      final res = await _open.jobs.getQueryResults(
        _projectId,
        jobId,
        location: _location,
        maxResults: maxResults,
        timeoutMs: _inlineTimeout.inMilliseconds,
      );
      if (res.jobComplete == true) return res;
    }
    throw QueryError(
      'BigQuery job $jobId is still running after three minutes. It will '
      'finish on its own; check it in the console.',
    );
  }

  void _throwForErrors(List<bq.ErrorProto>? errors) {
    if (errors == null || errors.isEmpty) return;
    final first = errors.first;
    throw QueryError(
      [first.message, if (first.reason != null) '(${first.reason})']
          .whereType<String>()
          .join(' '),
    );
  }

  String _apiMessage(bq.DetailedApiRequestError e) {
    final detail = e.message ?? 'HTTP ${e.status}';
    // The bytes-billed refusal is the one error worth naming, because the
    // remedy is a setting on this connection rather than a fix to the SQL.
    if (detail.contains('bytesBilled') || detail.contains('bytes billed')) {
      return 'BigQuery refused the query: it would scan more than the '
          '"maximum bytes billed" set on this connection. Narrow the query, '
          'or raise the limit in the connection settings. ($detail)';
    }
    return 'BigQuery: $detail';
  }

  bq.QueryParameter _parameter(Object? value) {
    final (type, text) = switch (value) {
      null => ('STRING', null),
      final bool b => ('BOOL', b.toString()),
      final int i => ('INT64', i.toString()),
      final double d => ('FLOAT64', d.toString()),
      final DateTime t => ('TIMESTAMP', t.toUtc().toIso8601String()),
      final Object o => ('STRING', o.toString()),
    };
    return bq.QueryParameter()
      ..parameterType = (bq.QueryParameterType()..type = type)
      ..parameterValue = (bq.QueryParameterValue()..value = text);
  }

  // --- Schema --------------------------------------------------------------

  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async {
    final fields = await _fieldsOf(container);
    return ContainerSchema(
      container: container,
      columns: [
        for (final f in fields)
          ColumnSchema(
            name: f.name,
            typeLabel: f.typeLabel,
            nullable: !f.isRequired,
            // BigQuery's primary keys are unenforced metadata, so nothing here
            // marks one: a key that does not identify a row is not a key the
            // grid can edit by.
            isPrimaryKey: false,
          ),
      ],
    );
  }

  Future<List<BqField>> _fieldsOf(ContainerRef container) async {
    final table = await _open.tables.get(
      _projectId,
      container.namespace ?? '',
      container.name,
      selectedFields: 'schema',
    );
    return _fieldsFrom(table.schema);
  }

  List<BqField> _fieldsFrom(bq.TableSchema? schema) => <BqField>[
        for (final f in schema?.fields ?? const <bq.TableFieldSchema>[])
          BqField.fromJson(f.toJson()),
      ];
}

/// One finished query: what it returned and what it counted.
class _BqResult {
  const _BqResult({
    required this.fields,
    required this.rows,
    this.totalRows,
    this.affectedRows,
  });

  final List<BqField> fields;
  final List<RowData> rows;
  final int? totalRows;

  /// Rows an `INSERT`, `UPDATE`, `DELETE` or `MERGE` touched.
  final int? affectedRows;
}
