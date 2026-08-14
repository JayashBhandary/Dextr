import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../connectors/data_source.dart';
import '../core/logger.dart';
import '../core/sql/sql_completion.dart';
import 'active_source_provider.dart';

/// What the query editor is allowed to know about the open connection.
///
/// The containers arrive with the connection, because the rail has already
/// asked for them. Columns do not: a database with four hundred tables would be
/// four hundred round trips to open one query tab. They are fetched per table,
/// when a statement names one — see [warm] — and kept until the connection
/// changes.
class SqlCatalogueNotifier extends StateNotifier<SqlCatalogue> {
  SqlCatalogueNotifier(this._ref) : super(SqlCatalogue.empty) {
    _ref.listen<String?>(activeConnectionIdProvider, (previous, next) {
      if (previous == next) return;
      // Another connection's columns are not this one's, and a stale table
      // list would offer names that are not there.
      _pending.clear();
      state = SqlCatalogue.empty;
    });

    _ref.listen<AsyncValue<List<ContainerRef>>>(activeContainersProvider, (
      previous,
      next,
    ) {
      final containers = next.value;
      if (containers == null) return;
      state = state.copyWith(
        tables: containers.map((c) => c.qualified).toList(),
      );
    }, fireImmediately: true);
  }

  final Ref _ref;

  /// Tables whose schema is on its way, so a caret resting in one statement
  /// does not ask twice.
  final Set<String> _pending = <String>{};

  /// Fetches the columns of [tables], skipping the ones already known.
  ///
  /// Failures are swallowed on purpose: a table the user cannot read the schema
  /// of is a table with no suggestions, which is what the list already shows
  /// for anything it does not know. An error banner over the editor because a
  /// *hint* could not be fetched would be worse than the missing hint.
  Future<void> warm(Iterable<String> tables) async {
    final source = _ref.read(activeDataSourceProvider).value;
    if (source is! SchemaReadable) return;
    final containers =
        _ref.read(activeContainersProvider).value ?? const <ContainerRef>[];

    for (final table in tables) {
      final key = table.toLowerCase();
      if (state.columns.containsKey(key) || !_pending.add(key)) continue;

      final container = containers.cast<ContainerRef?>().firstWhere(
        (c) =>
            c!.qualified.toLowerCase() == key || c.name.toLowerCase() == key,
        orElse: () => null,
      );
      if (container == null) continue;

      try {
        final schema = await source.getSchema(container);
        if (!mounted) return;
        state = state.copyWith(
          columns: <String, List<SqlColumnInfo>>{
            ...state.columns,
            key: <SqlColumnInfo>[
              for (final column in schema.columns)
                SqlColumnInfo(
                  name: column.name,
                  type: column.typeLabel,
                  nullable: column.nullable,
                  primaryKey: column.isPrimaryKey,
                ),
            ],
          },
        );
      } on Object catch (e) {
        log.d('No schema for ${container.qualified}: $e');
      }
    }
  }
}

final sqlCatalogueProvider =
    StateNotifierProvider<SqlCatalogueNotifier, SqlCatalogue>(
      SqlCatalogueNotifier.new,
    );
