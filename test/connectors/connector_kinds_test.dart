import 'package:dextr/connectors/postgres/postgres_data_source.dart';
import 'package:dextr/connectors/redis/redis_data_source.dart';
import 'package:dextr/connectors/redshift/redshift_data_source.dart';
import 'package:dextr/connectors/registry.dart';
import 'package:dextr/connectors/snowflake/snowflake_data_source.dart';
import 'package:dextr/connectors/bigquery/bigquery_data_source.dart';
import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// What each connector claims about itself, checked without a server.
///
/// A connector's capability set and its dialect overrides decide what the UI
/// offers before anything is connected, so getting them wrong shows up as a
/// button that fails rather than a button that is missing — which is the
/// failure worth catching here.
void main() {
  ConnectionRecord record(DataSourceKind kind,
          [Map<String, Object?> config = const {}]) =>
      ConnectionRecord(
        id: 'test',
        name: 'test',
        kind: kind,
        config: config,
        secretsRef: 'test',
      );

  group('registry', () {
    test('every kind in the enum has a connector', () {
      // The picker renders one card per enum value and disables the ones with
      // no factory, so a kind added without a connector is a dead card.
      for (final kind in DataSourceKind.values) {
        expect(ConnectorRegistry.instance.isSupported(kind), isTrue,
            reason: '${kind.name} has no registered factory');
      }
    });

    test('each new kind builds its own connector', () {
      final registry = ConnectorRegistry.instance;
      expect(registry.create(record(DataSourceKind.redshift), null),
          isA<RedshiftDataSource>());
      expect(registry.create(record(DataSourceKind.snowflake), null),
          isA<SnowflakeDataSource>());
      expect(registry.create(record(DataSourceKind.bigquery), null),
          isA<BigqueryDataSource>());
      expect(registry.create(record(DataSourceKind.redis), null),
          isA<RedisDataSource>());
    });

    test('every kind has a label of its own', () {
      final labels = <String>{
        for (final kind in DataSourceKind.values) kind.label,
      };
      expect(labels, hasLength(DataSourceKind.values.length));
    });
  });

  group('Redshift over the Postgres wire', () {
    final source = RedshiftDataSource(record: record(DataSourceKind.redshift),
        secrets: null);

    test('reports itself as Redshift, not as Postgres', () {
      expect(source.kind, DataSourceKind.redshift);
    });

    test('defaults to a cluster, not to a local Postgres', () {
      expect(source.defaultPort, 5439);
      expect(source.defaultDatabase, 'dev');
      expect(source.defaultUsername, 'awsuser');
      // A cluster is always across a network, so plain TCP is never the
      // default the way it can be for a database on this machine.
      expect(source.defaultSslMode, 'require');
    });

    test('does not use RETURNING, which Redshift has no clause for', () {
      expect(source.supportsInsertReturning, isFalse);
      expect(
        PostgresDataSource(record: record(DataSourceKind.postgres),
                secrets: null)
            .supportsInsertReturning,
        isTrue,
      );
    });

    test('refuses a column type change and says what to do instead', () {
      final error = source.alterColumnTypeError;
      expect(error, isNotNull);
      // The message has to carry the workaround: the operation is possible on
      // Redshift, just not as one statement.
      expect(error, contains('ADD'));
      expect(error, contains('DROP'));
    });

    test('hides the Redshift-only catalogue schemas as well as Postgres\'s',
        () {
      expect(source.systemSchemas, containsAll(<String>['pg_catalog',
        'information_schema', 'pg_internal', 'catalog_history']));
    });

    test('keeps the full Postgres capability set', () {
      expect(source.capabilities, <Capability>{
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
        Capability.schemaMutate,
        Capability.transactions,
      });
    });
  });

  group('Snowflake over REST', () {
    final source = SnowflakeDataSource(
        record: record(DataSourceKind.snowflake), secrets: null);

    test('offers no transactions, because a request is not a session', () {
      expect(source.capabilities, isNot(contains(Capability.transactions)));
      expect(source, isNot(isA<Transactional>()));
    });

    test('still reads, writes and changes schema', () {
      expect(source.capabilities, <Capability>{
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
        Capability.schemaMutate,
      });
      expect(source, isA<RawQueryable>());
      expect(source, isA<Writable>());
    });

    test('an unconfigured account is refused before any request', () {
      expect(source.connect(), throwsA(isA<Object>()));
    });
  });

  group('BigQuery', () {
    final source = BigqueryDataSource(
        record: record(DataSourceKind.bigquery), secrets: null);

    test('is read-only in the grid', () {
      // No enforced primary key means no WHERE clause identifies one row, so
      // an editable grid would be an edit that might hit two.
      expect(source.capabilities, isNot(contains(Capability.write)));
      expect(source, isNot(isA<Writable>()));
    });

    test('still queries and reads schema', () {
      expect(source.capabilities,
          <Capability>{Capability.rawQuery, Capability.schemaRead});
    });
  });

  group('Redis', () {
    final source =
        RedisDataSource(record: record(DataSourceKind.redis), secrets: null);

    test('browses, writes and describes keys', () {
      expect(source.capabilities, <Capability>{
        Capability.rawQuery,
        Capability.write,
        Capability.schemaRead,
      });
    });

    test('a keyspace has the same five columns however it is reached', () async {
      // Not inferred from a sample the way Mongo's schema is: Redis reports a
      // key's type and length directly, so the shape is fixed.
      final schema = await source.getSchema(
        const ContainerRef(name: 'db0', path: '0', subtype: 'keyspace'),
      );
      expect([for (final c in schema.columns) c.name],
          <String>['key', 'type', 'ttl', 'size', 'value']);
      expect(schema.pkColumns, <String>['key']);
    });
  });
}
