import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../connectors/mysql/mysql_ssl.dart';
import '../../connectors/registry.dart';
import '../../connectors/vector/vector_types.dart';
import '../../core/capabilities.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../../services/file_access.dart';
import '../../state/connections_provider.dart';
import '../../state/providers.dart';
import 'forms/firestore_form.dart';
import 'forms/graphql_form.dart';
import 'forms/mongo_form.dart';
import 'forms/mysql_form.dart';
import 'forms/postgres_form.dart';
import 'forms/rest_form.dart';
import 'forms/s3_form.dart';
import 'forms/sqlite_form.dart';
import 'forms/vector_form.dart';
import 'kind_picker.dart';

class ConnectionFormPage extends ConsumerStatefulWidget {
  const ConnectionFormPage({super.key, this.editing});

  /// When non-null, the page edits this connection in place instead of
  /// creating a new one.
  final ConnectionRecord? editing;

  @override
  ConsumerState<ConnectionFormPage> createState() => _ConnectionFormPageState();
}

class _ConnectionFormPageState extends ConsumerState<ConnectionFormPage> {
  DataSourceKind _kind = DataSourceKind.sqlite;
  static const _uuid = Uuid();

  bool get _isEdit => widget.editing != null;

  // In edit mode we preload the stored secrets so fields can be prefilled.
  bool _loadingSecrets = false;
  ConnectionSecrets? _secrets;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    if (editing != null) {
      _kind = editing.kind;
      _loadingSecrets = true;
      _loadSecrets(editing.secretsRef);
    }
  }

  Future<void> _loadSecrets(String secretsRef) async {
    final s = await ref.read(secretsStoreProvider).read(secretsRef);
    if (!mounted) return;
    setState(() {
      _secrets = s;
      _loadingSecrets = false;
    });
  }

  String _cfgStr(String key, [String fallback = '']) =>
      widget.editing?.config[key] as String? ?? fallback;

  int? _cfgInt(String key) => (widget.editing?.config[key] as num?)?.toInt();

  bool _cfgBool(String key, bool fallback) =>
      (widget.editing?.config[key] as bool?) ?? fallback;

  String get _recordId => widget.editing?.id ?? _uuid.v4();
  String get _secretsRefId => widget.editing?.secretsRef ?? _uuid.v4();

  /// On edit, drop the cached live connection so it reconnects with the
  /// updated config/secrets next time it's opened.
  Future<void> _afterSave() async {
    final editing = widget.editing;
    if (editing != null) {
      await ref.read(connectionManagerProvider).close(editing.id);
    }
    if (mounted) context.go('/');
  }

  // --- Test connection ------------------------------------------------------

  /// Opens a throwaway data source with the given config/secrets, pings it and
  /// tears it down. Throws (ConnectError etc.) on failure.
  Future<void> _testRecord(
    ConnectionRecord record,
    ConnectionSecrets? secrets,
  ) async {
    final source = ConnectorRegistry.instance.create(record, secrets);
    try {
      await source.connect();
      await source.ping();
    } finally {
      await source.dispose();
    }
  }

  ConnectionRecord _testStub(
    DataSourceKind kind,
    Map<String, Object?> config,
  ) => ConnectionRecord(
    id: '_test',
    name: 'test',
    kind: kind,
    config: config,
    secretsRef: '_test',
  );

  Map<String, Object?> _sqliteConfig(SqliteFormResult r) => {
    FileAccess.pathKey: r.filePath,
    FileAccess.bookmarkKey: ?r.bookmark,
  };

  Map<String, Object?> _postgresConfig(PostgresFormResult r) => {
    'host': r.host,
    'port': r.port,
    'database': r.database,
    'username': r.username,
    'sslMode': r.sslMode,
  };

  Map<String, Object?> _mysqlConfig(MysqlFormResult r) => {
    'host': r.host,
    'port': r.port,
    'database': r.database,
    'username': r.username,
    // Replaces the old `secure` bool. Not written any more, and not carried
    // forward either: `MysqlSslMode.fromConfig` reads whichever is present, so
    // a record saved by an older build keeps working until it is next saved.
    'sslMode': r.sslMode.name,
  };

  Map<String, Object?> _mongoConfig(MongoFormResult r) => {
    'host': r.host,
    'port': r.port,
    'database': r.database,
    if (r.username.isNotEmpty) 'username': r.username,
    'tls': r.tls,
  };

  Map<String, Object?> _firestoreConfig(FirestoreFormResult r) => {
    'projectId': r.projectId,
    'databaseId': r.databaseId,
    'mode': r.mode,
    if (r.emulatorHost != null) 'emulatorHost': r.emulatorHost,
  };

  Map<String, Object?> _s3Config(S3FormResult r) => {
    'endpoint': r.endpoint,
    if (r.port != null) 'port': r.port,
    'region': r.region,
    'useSSL': r.useSSL,
  };

  /// One config shape for four engines: `provider` says which one, `mode` says
  /// how it is reached, and the rest is whichever of those two needed it.
  Map<String, Object?> _vectorConfig(VectorFormResult r) => {
    'provider': r.provider.name,
    'mode': r.mode.name,
    if (r.mode != VectorMode.file) 'url': r.url,
    if (r.tenant != null && r.tenant!.isNotEmpty) 'tenant': r.tenant,
    if (r.database != null && r.database!.isNotEmpty) 'database': r.database,
    if (r.namespace != null && r.namespace!.isNotEmpty)
      'namespace': r.namespace,
    if (r.mode == VectorMode.file) ...{
      FileAccess.pathKey: r.directoryPath ?? '',
      FileAccess.bookmarkKey: ?r.bookmark,
    },
  };

  Future<void> _testSqlite(SqliteFormResult r) =>
      _testRecord(_testStub(DataSourceKind.sqlite, _sqliteConfig(r)), null);

  Future<void> _testPostgres(PostgresFormResult r) => _testRecord(
    _testStub(DataSourceKind.postgres, _postgresConfig(r)),
    ConnectionSecrets(password: r.password),
  );

  Future<void> _testMysql(MysqlFormResult r) => _testRecord(
    _testStub(DataSourceKind.mysql, _mysqlConfig(r)),
    ConnectionSecrets(password: r.password),
  );

  Future<void> _testMongo(MongoFormResult r) => _testRecord(
    _testStub(DataSourceKind.mongo, _mongoConfig(r)),
    ConnectionSecrets(password: r.password.isEmpty ? null : r.password),
  );

  Future<void> _testFirestore(FirestoreFormResult r) => _testRecord(
    _testStub(DataSourceKind.firestore, _firestoreConfig(r)),
    ConnectionSecrets(serviceAccountJson: r.serviceAccountJson),
  );

  Future<void> _testS3(S3FormResult r) => _testRecord(
    _testStub(DataSourceKind.s3, _s3Config(r)),
    ConnectionSecrets(
      accessKeyId: r.accessKeyId,
      secretAccessKey: r.secretAccessKey,
      sessionToken: r.sessionToken,
    ),
  );

  Future<void> _testVector(VectorFormResult r) => _testRecord(
    _testStub(DataSourceKind.vector, _vectorConfig(r)),
    ConnectionSecrets(apiKey: r.apiKey),
  );

  // --- Save -----------------------------------------------------------------

  Future<void> _saveSqlite(SqliteFormResult r) async {
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.sqlite,
      config: _sqliteConfig(r),
      secretsRef: _secretsRefId,
    );
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  ConnectionSecrets _httpSecrets({
    String authMode = 'none',
    String? bearer,
    String? apiKey,
    String? basic,
  }) {
    return ConnectionSecrets(
      bearerToken: authMode == 'bearer' ? bearer : null,
      apiKey: authMode == 'apiKey' ? apiKey : null,
      basicAuth: authMode == 'basic' ? basic : null,
    );
  }

  Future<void> _saveRest(RestFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.rest,
      config: {
        'baseUrl': r.baseUrl,
        'authMode': r.authMode,
        if (r.apiKeyHeader != null) 'apiKeyHeader': r.apiKeyHeader,
        'operations': r.operationsJson,
      },
      secretsRef: secretsRef,
    );
    final secrets = _httpSecrets(
      authMode: r.authMode,
      bearer: r.bearerToken,
      apiKey: r.apiKey,
      basic: r.basicAuth,
    );
    await ref.read(secretsStoreProvider).write(secretsRef, secrets);
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveGraphql(GraphqlFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.graphql,
      config: {
        'endpoint': r.endpoint,
        'authMode': r.authMode,
        if (r.apiKeyHeader != null) 'apiKeyHeader': r.apiKeyHeader,
        'operations': r.operationsJson,
      },
      secretsRef: secretsRef,
    );
    final secrets = _httpSecrets(
      authMode: r.authMode,
      bearer: r.bearerToken,
      apiKey: r.apiKey,
      basic: r.basicAuth,
    );
    await ref.read(secretsStoreProvider).write(secretsRef, secrets);
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveS3(S3FormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.s3,
      config: _s3Config(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(
          secretsRef,
          ConnectionSecrets(
            accessKeyId: r.accessKeyId,
            secretAccessKey: r.secretAccessKey,
            sessionToken: r.sessionToken,
          ),
        );
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveMongo(MongoFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.mongo,
      config: _mongoConfig(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(
          secretsRef,
          ConnectionSecrets(password: r.password.isEmpty ? null : r.password),
        );
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveFirestore(FirestoreFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.firestore,
      config: _firestoreConfig(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(
          secretsRef,
          ConnectionSecrets(serviceAccountJson: r.serviceAccountJson),
        );
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveMysql(MysqlFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.mysql,
      config: _mysqlConfig(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(secretsRef, ConnectionSecrets(password: r.password));
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _savePostgres(PostgresFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.postgres,
      config: _postgresConfig(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(secretsRef, ConnectionSecrets(password: r.password));
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  Future<void> _saveVector(VectorFormResult r) async {
    final secretsRef = _secretsRefId;
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.vector,
      config: _vectorConfig(r),
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(secretsRef, ConnectionSecrets(apiKey: r.apiKey));
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  // --- Prefill builders (edit mode) ----------------------------------------

  SqliteFormResult get _initSqlite => SqliteFormResult(
    name: widget.editing!.name,
    filePath: _cfgStr(FileAccess.pathKey),
    bookmark: widget.editing!.config[FileAccess.bookmarkKey] as String?,
  );

  PostgresFormResult get _initPostgres => PostgresFormResult(
    name: widget.editing!.name,
    host: _cfgStr('host', 'localhost'),
    port: _cfgInt('port') ?? 5432,
    database: _cfgStr('database', 'postgres'),
    username: _cfgStr('username', 'postgres'),
    password: _secrets?.password ?? '',
    sslMode: _cfgStr('sslMode', 'require'),
  );

  MysqlFormResult get _initMysql => MysqlFormResult(
    name: widget.editing!.name,
    host: _cfgStr('host', 'localhost'),
    port: _cfgInt('port') ?? 3306,
    database: _cfgStr('database', 'dextr'),
    username: _cfgStr('username', 'root'),
    password: _secrets?.password ?? '',
    // Read through the same migration the connector uses, so editing an older
    // connection shows the transport it actually has rather than a default.
    sslMode: MysqlSslMode.fromConfig(
      widget.editing!.config['sslMode'],
      legacySecure: widget.editing!.config['secure'],
    ),
  );

  MongoFormResult get _initMongo => MongoFormResult(
    name: widget.editing!.name,
    host: _cfgStr('host', 'localhost'),
    port: _cfgInt('port') ?? 27017,
    database: _cfgStr('database', 'dextr'),
    username: _cfgStr('username'),
    password: _secrets?.password ?? '',
    tls: _cfgBool('tls', false),
  );

  FirestoreFormResult get _initFirestore => FirestoreFormResult(
    name: widget.editing!.name,
    projectId: _cfgStr('projectId'),
    databaseId: _cfgStr('databaseId', '(default)'),
    mode: _cfgStr('mode', 'serviceAccount'),
    emulatorHost: widget.editing!.config['emulatorHost'] as String?,
    serviceAccountJson: _secrets?.serviceAccountJson,
  );

  S3FormResult get _initS3 => S3FormResult(
    name: widget.editing!.name,
    endpoint: _cfgStr('endpoint', 's3.amazonaws.com'),
    port: _cfgInt('port'),
    region: _cfgStr('region', 'us-east-1'),
    useSSL: _cfgBool('useSSL', false),
    accessKeyId: _secrets?.accessKeyId ?? '',
    secretAccessKey: _secrets?.secretAccessKey ?? '',
    sessionToken: _secrets?.sessionToken,
  );

  RestFormResult get _initRest => RestFormResult(
    name: widget.editing!.name,
    baseUrl: _cfgStr('baseUrl'),
    authMode: _cfgStr('authMode', 'none'),
    apiKeyHeader: widget.editing!.config['apiKeyHeader'] as String?,
    bearerToken: _secrets?.bearerToken,
    apiKey: _secrets?.apiKey,
    basicAuth: _secrets?.basicAuth,
    operationsJson: _cfgStr('operations'),
  );

  GraphqlFormResult get _initGraphql => GraphqlFormResult(
    name: widget.editing!.name,
    endpoint: _cfgStr('endpoint'),
    authMode: _cfgStr('authMode', 'none'),
    apiKeyHeader: widget.editing!.config['apiKeyHeader'] as String?,
    bearerToken: _secrets?.bearerToken,
    apiKey: _secrets?.apiKey,
    basicAuth: _secrets?.basicAuth,
    operationsJson: _cfgStr('operations'),
  );

  VectorFormResult get _initVector => VectorFormResult(
    name: widget.editing!.name,
    provider: VectorProvider.fromName(widget.editing!.config['provider']),
    mode: VectorMode.fromName(widget.editing!.config['mode']),
    url: _cfgStr('url'),
    apiKey: _secrets?.apiKey,
    tenant: _cfgStr('tenant'),
    database: _cfgStr('database'),
    namespace: _cfgStr('namespace'),
    directoryPath: _cfgStr(FileAccess.pathKey),
    bookmark: widget.editing!.config[FileAccess.bookmarkKey] as String?,
  );

  void _cancel() => context.go('/');

  @override
  Widget build(BuildContext context) {
    return AstryxLayout(
      // A form is a single column of prose-width fields: one running the width
      // of a monitor is unreadable.
      maxContentWidth: 720,
      header: AstryxHStack(
        gap: AstryxSpacingToken.spacing3,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          // Expanded rather than Flexible plus a Spacer: the two would share
          // the free space and leave the close button mid-row.
          Expanded(
            child: AstryxHeading(
              _isEdit ? 'Edit connection' : 'New connection',
              level: 1,
            ),
          ),
          AstryxIconButton(
            icon: AstryxIconName.close,
            label: 'Close without saving',
            tooltip: 'Close',
            variant: AstryxButtonVariant.ghost,
            onPressed: _cancel,
          ),
        ],
      ),
      child: _loadingSecrets
          ? const AstryxCenter(
              minHeight: 240,
              child: AstryxSpinner(label: 'Reading the stored credentials'),
            )
          : AstryxVStack(
              gap: AstryxSpacingToken.spacing6,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                AstryxSection(
                  title: 'Backend',
                  description: _isEdit
                      ? 'Fixed once a connection exists: its stored settings '
                            'have the shape this backend expects.'
                      : 'What this connection talks to.',
                  child: _isEdit
                      ? AstryxHStack(
                          children: <Widget>[
                            AstryxBadge(
                              _kind.label,
                              variant: AstryxBadgeVariant.info,
                            ),
                          ],
                        )
                      : KindPicker(
                          selected: _kind,
                          onChanged: (kind) => setState(() => _kind = kind),
                        ),
                ),
                AstryxSection(
                  title: 'Configuration',
                  child: AstryxCard(
                    padding: AstryxSpacingToken.spacing5,
                    child: _formFor(_kind),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _formFor(DataSourceKind kind) => switch (kind) {
    DataSourceKind.sqlite => SqliteForm(
      onSubmit: _saveSqlite,
      onTest: _testSqlite,
      onCancel: _cancel,
      initial: _isEdit ? _initSqlite : null,
    ),
    DataSourceKind.postgres => PostgresForm(
      onSubmit: _savePostgres,
      onTest: _testPostgres,
      onCancel: _cancel,
      initial: _isEdit ? _initPostgres : null,
    ),
    DataSourceKind.mysql => MysqlForm(
      onSubmit: _saveMysql,
      onTest: _testMysql,
      onCancel: _cancel,
      initial: _isEdit ? _initMysql : null,
    ),
    DataSourceKind.firestore => FirestoreForm(
      onSubmit: _saveFirestore,
      onTest: _testFirestore,
      onCancel: _cancel,
      initial: _isEdit ? _initFirestore : null,
    ),
    DataSourceKind.mongo => MongoForm(
      onSubmit: _saveMongo,
      onTest: _testMongo,
      onCancel: _cancel,
      initial: _isEdit ? _initMongo : null,
    ),
    DataSourceKind.s3 => S3Form(
      onSubmit: _saveS3,
      onTest: _testS3,
      onCancel: _cancel,
      initial: _isEdit ? _initS3 : null,
    ),
    DataSourceKind.rest => RestForm(
      onSubmit: _saveRest,
      onCancel: _cancel,
      initial: _isEdit ? _initRest : null,
    ),
    DataSourceKind.graphql => GraphqlForm(
      onSubmit: _saveGraphql,
      onCancel: _cancel,
      initial: _isEdit ? _initGraphql : null,
    ),
    DataSourceKind.vector => VectorForm(
      onSubmit: _saveVector,
      onTest: _testVector,
      onCancel: _cancel,
      initial: _isEdit ? _initVector : null,
    ),
  };
}
