import '../../core/capabilities.dart';
import '../sql_common/pg_wire_data_source.dart';

/// Amazon Redshift, over the Postgres wire protocol.
///
/// Redshift forked from PostgreSQL 8.0 and still answers the same handshake, so
/// the driver, the quoting and the `information_schema` queries all come from
/// [PgWireDataSource] unchanged. What twenty years of divergence did change is
/// the SQL, and the two overrides below are the parts of that divergence this
/// application would otherwise walk into:
///
/// * **No `RETURNING`.** Redshift's `INSERT` has no `RETURNING` clause at all,
///   so an insert cannot report the row as stored. [supportsInsertReturning]
///   turns the clause off rather than sending a statement the server rejects.
/// * **Almost no `ALTER COLUMN`.** A Redshift column's type can be changed only
///   in a few narrow cases — widening a `varchar`, mostly — and never for a
///   column in a sort or distribution key. Rather than emit an `ALTER COLUMN
///   ... TYPE` that fails on most tables, the connector says what the operation
///   actually is on Redshift: add a column, copy into it, drop the old one.
///
/// Its system catalogue is larger than Postgres's, too: `pg_internal` and
/// `catalog_history` hold Redshift's own bookkeeping and are excluded from the
/// rail for the same reason `pg_catalog` is.
class RedshiftDataSource extends PgWireDataSource {
  RedshiftDataSource({required super.record, required super.secrets});

  @override
  DataSourceKind get kind => DataSourceKind.redshift;

  /// Redshift's own port. Not 5432 — a cluster is created on 5439 unless
  /// somebody changed it.
  @override
  int get defaultPort => 5439;

  /// The database every cluster is created with.
  @override
  String get defaultDatabase => 'dev';

  /// The superuser a provisioned cluster is created with.
  @override
  String get defaultUsername => 'awsuser';

  /// A cluster is reached across a VPC boundary or the public internet, never
  /// over a loopback socket, so the default is encrypted.
  @override
  String get defaultSslMode => 'require';

  @override
  List<String> get systemSchemas => const <String>[
        'pg_catalog',
        'information_schema',
        'pg_internal',
        'catalog_history',
      ];

  @override
  bool get supportsInsertReturning => false;

  @override
  String? get alterColumnTypeError =>
      'Redshift cannot change a column type in place except to widen a '
      'varchar, and never for a column in the sort or distribution key. '
      'Change it in the Query pane instead: ADD a new column, UPDATE it from '
      'the old one, DROP the old one, then RENAME.';
}
