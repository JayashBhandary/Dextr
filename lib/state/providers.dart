import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/connection_manager.dart';
import '../services/connections_repo.dart';
import '../services/export_service.dart';
import '../services/external_open.dart';
import '../services/secrets_store.dart';
import '../services/settings_repo.dart';

final secretsStoreProvider = Provider<SecretsStore>((ref) => SecretsStore());

final connectionsRepoProvider = Provider<ConnectionsRepo>(
  (ref) => ConnectionsRepo(),
);

final settingsRepoProvider = Provider<SettingsRepo>((ref) => SettingsRepo());

/// Overridden in tests, which is the whole reason it is a provider: a widget
/// test must never open a real save dialog.
final exportServiceProvider = Provider<ExportService>(
  (ref) => ExportService(),
);

/// Likewise: a test must never launch the machine's PDF viewer.
final externalOpenProvider = Provider<ExternalOpen>((ref) => ExternalOpen());

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final mgr = ConnectionManager(
    secretsStore: ref.watch(secretsStoreProvider),
    connectionsRepo: ref.watch(connectionsRepoProvider),
  );
  ref.onDispose(() => mgr.closeAll());
  return mgr;
});
