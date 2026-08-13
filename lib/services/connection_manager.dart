import '../connectors/data_source.dart';
import '../connectors/registry.dart';
import '../core/logger.dart';
import '../domain/connection_record.dart';
import 'connections_repo.dart';
import 'secrets_store.dart';

/// Caches live [DataSource] instances by connection id.
class ConnectionManager {
  ConnectionManager({required this.secretsStore, this.connectionsRepo});

  final SecretsStore secretsStore;

  /// Where corrections a connect turned up get written back. Optional so a
  /// throwaway manager (tests, the form's Test button) needs no storage.
  final ConnectionsRepo? connectionsRepo;

  final Map<String, DataSource> _live = {};

  bool isOpen(String connectionId) => _live.containsKey(connectionId);

  DataSource? peek(String connectionId) => _live[connectionId];

  Future<DataSource> open(ConnectionRecord record) async {
    final existing = _live[record.id];
    if (existing != null) return existing;
    final secrets = await secretsStore.read(record.secretsRef);
    final source = ConnectorRegistry.instance.create(record, secrets);
    await source.connect();
    _live[record.id] = source;
    await _persistCorrections(record, source);
    return source;
  }

  /// Writes back config a connect had to correct, straight through the repo.
  ///
  /// Deliberately not routed through the connections provider: `open` runs
  /// inside a provider build, and pushing new state from there would rebuild
  /// the very thing that is awaiting this call.
  Future<void> _persistCorrections(
    ConnectionRecord record,
    DataSource source,
  ) async {
    final repo = connectionsRepo;
    final corrected = source.correctedConfig;
    if (repo == null || corrected.isEmpty) return;
    try {
      await repo.upsert(
        record.copyWith(config: {...record.config, ...corrected}),
      );
    } catch (e) {
      // The connection is open and usable; failing to write the correction
      // only costs us a redundant correction on the next launch.
      log.w('Could not save corrected config for ${record.name}: $e');
    }
  }

  Future<void> close(String connectionId) async {
    final s = _live.remove(connectionId);
    if (s != null) await s.dispose();
  }

  Future<void> closeAll() async {
    for (final s in _live.values) {
      await s.dispose();
    }
    _live.clear();
  }
}
