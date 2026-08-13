import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../domain/connection_record.dart';
import 'providers.dart';

class ConnectionsNotifier
    extends StateNotifier<AsyncValue<List<ConnectionRecord>>> {
  ConnectionsNotifier(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }

  final Ref _ref;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final repo = _ref.read(connectionsRepoProvider);
      final all = await repo.load();
      state = AsyncValue.data(all);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> upsert(ConnectionRecord record) async {
    final repo = _ref.read(connectionsRepoProvider);
    final updated = await repo.upsert(record);
    state = AsyncValue.data(updated);
  }

  Future<void> remove(String id) async {
    final repo = _ref.read(connectionsRepoProvider);
    final updated = await repo.remove(id);
    state = AsyncValue.data(updated);
  }
}

final connectionsProvider =
    StateNotifierProvider<
      ConnectionsNotifier,
      AsyncValue<List<ConnectionRecord>>
    >(ConnectionsNotifier.new);
