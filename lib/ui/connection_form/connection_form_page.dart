import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/capabilities.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../../state/connections_provider.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'forms/firestore_form.dart';
import 'forms/graphql_form.dart';
import 'forms/mongo_form.dart';
import 'forms/mysql_form.dart';
import 'forms/postgres_form.dart';
import 'forms/rest_form.dart';
import 'forms/s3_form.dart';
import 'forms/sqlite_form.dart';
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

  Future<void> _saveSqlite(SqliteFormResult r) async {
    final record = ConnectionRecord(
      id: _recordId,
      name: r.name,
      kind: DataSourceKind.sqlite,
      config: {'filePath': r.filePath},
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
      config: {
        'endpoint': r.endpoint,
        if (r.port != null) 'port': r.port,
        'region': r.region,
        'useSSL': r.useSSL,
      },
      secretsRef: secretsRef,
    );
    await ref.read(secretsStoreProvider).write(
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
      config: {
        'host': r.host,
        'port': r.port,
        'database': r.database,
        if (r.username.isNotEmpty) 'username': r.username,
        'tls': r.tls,
      },
      secretsRef: secretsRef,
    );
    await ref.read(secretsStoreProvider).write(
          secretsRef,
          ConnectionSecrets(
            password: r.password.isEmpty ? null : r.password,
          ),
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
      config: {
        'projectId': r.projectId,
        'databaseId': r.databaseId,
        'mode': r.mode,
        if (r.emulatorHost != null) 'emulatorHost': r.emulatorHost,
      },
      secretsRef: secretsRef,
    );
    await ref.read(secretsStoreProvider).write(
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
      config: {
        'host': r.host,
        'port': r.port,
        'database': r.database,
        'username': r.username,
        'secure': r.secure,
      },
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
      config: {
        'host': r.host,
        'port': r.port,
        'database': r.database,
        'username': r.username,
        'sslMode': r.sslMode,
      },
      secretsRef: secretsRef,
    );
    await ref
        .read(secretsStoreProvider)
        .write(secretsRef, ConnectionSecrets(password: r.password));
    await ref.read(connectionsProvider.notifier).upsert(record);
    await _afterSave();
  }

  // --- Prefill builders (edit mode) ----------------------------------------

  SqliteFormResult get _initSqlite => SqliteFormResult(
        name: widget.editing!.name,
        filePath: _cfgStr('filePath'),
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
        secure: _cfgBool('secure', false),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit connection' : 'New connection'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/'),
        ),
      ),
      body: _loadingSecrets
          ? const Center(child: CircularProgressIndicator())
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(Spacing.lg),
                children: [
                  Text('Backend kind', style: theme.textTheme.titleSmall),
                  const SizedBox(height: Spacing.sm),
                  // Kind is immutable once a connection exists — editing it
                  // would invalidate the stored config shape.
                  IgnorePointer(
                    ignoring: _isEdit,
                    child: Opacity(
                      opacity: _isEdit ? 0.6 : 1,
                      child: KindPicker(
                        selected: _kind,
                        onChanged: (k) => setState(() => _kind = k),
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.xl),
                  Text('Configuration', style: theme.textTheme.titleSmall),
                  const SizedBox(height: Spacing.sm),
                  Card(
                    margin: EdgeInsets.zero,
                    child: switch (_kind) {
                      DataSourceKind.sqlite => SqliteForm(
                          onSubmit: _saveSqlite,
                          initial: _isEdit ? _initSqlite : null,
                        ),
                      DataSourceKind.postgres => PostgresForm(
                          onSubmit: _savePostgres,
                          initial: _isEdit ? _initPostgres : null,
                        ),
                      DataSourceKind.mysql => MysqlForm(
                          onSubmit: _saveMysql,
                          initial: _isEdit ? _initMysql : null,
                        ),
                      DataSourceKind.firestore => FirestoreForm(
                          onSubmit: _saveFirestore,
                          initial: _isEdit ? _initFirestore : null,
                        ),
                      DataSourceKind.mongo => MongoForm(
                          onSubmit: _saveMongo,
                          initial: _isEdit ? _initMongo : null,
                        ),
                      DataSourceKind.s3 => S3Form(
                          onSubmit: _saveS3,
                          initial: _isEdit ? _initS3 : null,
                        ),
                      DataSourceKind.rest => RestForm(
                          onSubmit: _saveRest,
                          initial: _isEdit ? _initRest : null,
                        ),
                      DataSourceKind.graphql => GraphqlForm(
                          onSubmit: _saveGraphql,
                          initial: _isEdit ? _initGraphql : null,
                        ),
                    },
                  ),
                ],
              ),
            ),
    );
  }
}
