import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../connectors/data_source.dart';
import '../core/errors.dart';
import 'active_source_provider.dart';

class QueryExecution {
  const QueryExecution({this.result, this.error, this.running = false});
  final QueryResult? result;
  final Object? error;
  final bool running;
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
      final res = await src.runRawQuery(sql);
      state = QueryExecution(result: res);
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
