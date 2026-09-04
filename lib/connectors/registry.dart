import '../core/capabilities.dart';
import '../domain/connection_record.dart';
import '../domain/connection_secrets.dart';
import 'bigquery/bigquery_data_source.dart';
import 'data_source.dart';
import 'firestore/firestore_data_source.dart';
import 'graphql/graphql_data_source.dart';
import 'mongo/mongo_data_source.dart';
import 'mysql/mysql_data_source.dart';
import 'postgres/postgres_data_source.dart';
import 'redis/redis_data_source.dart';
import 'redshift/redshift_data_source.dart';
import 'rest/rest_data_source.dart';
import 's3/s3_data_source.dart';
import 'snowflake/snowflake_data_source.dart';
import 'sqlite/sqlite_data_source.dart';
import 'vector/vector_data_source.dart';

typedef DataSourceFactory = DataSource Function(
    ConnectionRecord record, ConnectionSecrets? secrets);

class ConnectorRegistry {
  ConnectorRegistry._();
  static final ConnectorRegistry instance = ConnectorRegistry._();

  final Map<DataSourceKind, DataSourceFactory> _factories = {
    DataSourceKind.sqlite: (r, s) => SqliteDataSource(record: r),
    DataSourceKind.postgres: (r, s) => PostgresDataSource(record: r, secrets: s),
    DataSourceKind.mysql: (r, s) => MysqlDataSource(record: r, secrets: s),
    // Redshift speaks the Postgres wire protocol, so this is a different set
    // of defaults over the same driver rather than a different driver.
    DataSourceKind.redshift: (r, s) =>
        RedshiftDataSource(record: r, secrets: s),
    DataSourceKind.snowflake: (r, s) =>
        SnowflakeDataSource(record: r, secrets: s),
    DataSourceKind.bigquery: (r, s) =>
        BigqueryDataSource(record: r, secrets: s),
    DataSourceKind.firestore: (r, s) =>
        FirestoreDataSource(record: r, secrets: s),
    DataSourceKind.mongo: (r, s) => MongoDataSource(record: r, secrets: s),
    DataSourceKind.redis: (r, s) => RedisDataSource(record: r, secrets: s),
    DataSourceKind.s3: (r, s) => S3DataSource(record: r, secrets: s),
    DataSourceKind.rest: (r, s) => RestDataSource(record: r, secrets: s),
    DataSourceKind.graphql: (r, s) =>
        GraphqlDataSource(record: r, secrets: s),
    // One factory for four engines: which of them a record means is `provider`
    // in its config, and the data source picks the backend at connect.
    DataSourceKind.vector: (r, s) => VectorDataSource(record: r, secrets: s),
  };

  /// Kinds supported on the current platform (web caveats applied at UI level).
  Iterable<DataSourceKind> get registeredKinds => _factories.keys;

  bool isSupported(DataSourceKind kind) => _factories.containsKey(kind);

  DataSource create(ConnectionRecord record, ConnectionSecrets? secrets) {
    final factory = _factories[record.kind];
    if (factory == null) {
      throw StateError('No connector registered for ${record.kind}');
    }
    return factory(record, secrets);
  }
}
