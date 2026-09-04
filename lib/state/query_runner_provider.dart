import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../connectors/data_source.dart';
import '../core/errors.dart';
import '../core/sql/sql_row_cap.dart';
import 'active_source_provider.dart';

class QueryExecution {
  const QueryExecution({
    this.result,
    this.error,
    this.running = false,
    this.truncated = false,
  });
  final QueryResult? result;
  final Object? error;
  final bool running;

  /// Whether the source had more rows than the run kept.
  ///
  /// What is in [result] is the first [maxQueryRows] of them. Said out loud
  /// wherever the count is, because a row count that is silently a ceiling is
  /// worse than no count: it reads as the answer to `COUNT(*)`.
  final bool truncated;
}

class QueryRunnerNotifier extends StateNotifier<QueryExecution> {
  QueryRunnerNotifier(this._ref) : super(const QueryExecution());

  final Ref _ref;

  Future<void> run(String sql) async {
    state = const QueryExecution(running: true);
    try {
      final src = await _ref.read(activeDataSourceProvider.future);
      if (src == null) {
        throw const QueryError('No active connection');
      }
      if (src is! RawQueryable) {
        throw const CapabilityError('This source does not support raw queries');
      }

      // The ceiling is pushed into the statement where the dialect can carry
      // it, so the rows never leave the server. Where it cannot — a Redis
      // command, a Mongo pipeline — the trim below is all there is, and it at
      // least keeps the grid and the exporter off the far end of the result.
      final capped = dialectTakesLimitClause(src.kind)
          ? sqlWithRowCap(sql)
          : null;
      final res = await src.runRawQuery(capped ?? sql);

      state = QueryExecution(
        result: res.rows.length > maxQueryRows
            ? QueryResult(
                columns: res.columns,
                rows: res.rows.sublist(0, maxQueryRows),
                affectedRows: res.affectedRows,
                elapsed: res.elapsed,
              )
            : res,
        truncated: res.rows.length > maxQueryRows,
      );
    } catch (e) {
      state = QueryExecution(error: e);
    }
  }

  void clear() => state = const QueryExecution();
}

final queryRunnerProvider =
    StateNotifierProvider.autoDispose<QueryRunnerNotifier, QueryExecution>(
      QueryRunnerNotifier.new,
    );
