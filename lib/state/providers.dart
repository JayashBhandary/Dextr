import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/connection_manager.dart';
import '../services/connections_repo.dart';
import '../services/secrets_store.dart';
import '../services/settings_repo.dart';

final secretsStoreProvider = Provider<SecretsStore>((ref) => SecretsStore());

final connectionsRepoProvider = Provider<ConnectionsRepo>(
  (ref) => ConnectionsRepo(),
);

final settingsRepoProvider = Provider<SettingsRepo>((ref) => SettingsRepo());

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final mgr = ConnectionManager(
    secretsStore: ref.watch(secretsStoreProvider),
    connectionsRepo: ref.watch(connectionsRepoProvider),
  );
  ref.onDispose(() => mgr.closeAll());
  return mgr;
});
