import '../../core/capabilities.dart';
import '../sql_common/pg_wire_data_source.dart';

/// PostgreSQL itself: the wire protocol with none of its dialect withheld.
///
/// Everything is in [PgWireDataSource]; what is left here is the three
/// defaults a form leaves blank and the name the errors are reported under.
/// Amazon Redshift sits beside this as `RedshiftDataSource`, sharing the driver
/// and overriding what it cannot do.
class PostgresDataSource extends PgWireDataSource {
  PostgresDataSource({required super.record, required super.secrets});

  @override
  DataSourceKind get kind => DataSourceKind.postgres;

  @override
  int get defaultPort => 5432;
  @override
  String get defaultDatabase => 'postgres';
  @override
  String get defaultUsername => 'postgres';
}
