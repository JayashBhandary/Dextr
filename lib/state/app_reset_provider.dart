import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_reset.dart';
import 'active_source_provider.dart';
import 'connections_provider.dart';
import 'providers.dart';
import 'rail_provider.dart';
import 'settings_provider.dart';
import 'workspace_provider.dart';

final appResetProvider = Provider<AppResetService>(
  (ref) => AppResetService(
    connectionsRepo: ref.watch(connectionsRepoProvider),
    settingsRepo: ref.watch(settingsRepoProvider),
    secretsStore: ref.watch(secretsStoreProvider),
    connectionManager: ref.watch(connectionManagerProvider),
  ),
);

/// Wipes everything Dextr has stored and puts the running session back to what
/// a first launch looks like, without needing a restart.
///
/// A function rather than a notifier because a reset has no state of its own:
/// it is one pass over storage followed by one pass over the providers that were
/// holding what storage used to say.
Future<AppResetReport> resetApplication(WidgetRef ref) async {
  final report = await ref.read(appResetProvider).run();

  // In-memory state after the disk, and settings by way of `resetInMemory`
  // rather than `reset`: every ordinary mutation persists, so resetting the
  // usual way would write a settings file straight back over the one that was
  // just deleted.
  ref.read(settingsProvider.notifier).resetInMemory();
  ref.read(workspaceProvider.notifier).closeAllTabs();
  ref.read(activeConnectionIdProvider.notifier).state = null;
  ref.read(railCollapsedProvider.notifier).state = false;

  // Last, and awaited: this reloads from the file that is now gone, which is
  // what empties the rail. Doing it before the wipe would refill it.
  await ref.read(connectionsProvider.notifier).refresh();

  return report;
}
