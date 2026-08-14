import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/logger.dart';
import '../domain/connection_record.dart';
import 'providers.dart';

class ConnectionsNotifier
    extends StateNotifier<AsyncValue<List<ConnectionRecord>>> {
  ConnectionsNotifier(this._ref) : super(const AsyncValue.loading()) {
    refresh();
  }

  final Ref _ref;

  /// Whether the one-time orphan sweep has run in this session.
  bool _sweptOrphans = false;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final repo = _ref.read(connectionsRepoProvider);
      final all = await repo.load();
      state = AsyncValue.data(all);
      await _sweepOrphanedSecretsOnce(all);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Clears credentials left behind by a release that deleted a connection
  /// without deleting its secret.
  ///
  /// Runs after the first successful load rather than on every refresh: it is
  /// a migration, not a routine, and enumerating the keychain is not free. It
  /// deliberately cannot fail the load — the connections are usable either way.
  Future<void> _sweepOrphanedSecretsOnce(List<ConnectionRecord> records) async {
    if (_sweptOrphans) return;
    _sweptOrphans = true;
    try {
      await _ref
          .read(secretsStoreProvider)
          .sweepOrphans(records.map((r) => r.secretsRef));
    } on Exception catch (e) {
      log.w('Orphaned-secret sweep did not complete: $e');
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
