import '../core/logger.dart';
import 'connection_manager.dart';
import 'connections_repo.dart';
import 'secrets_store.dart';
import 'settings_repo.dart';

/// What a reset actually managed to remove.
///
/// Reported rather than assumed: a keychain can be locked and a file can be
/// held open, and a reset that says "done" while a credential survived has told
/// the user something untrue about where their passwords are.
class AppResetReport {
  const AppResetReport({
    required this.connectionsRemoved,
    required this.credentialsRemoved,
    required this.credentialsComplete,
    this.failures = const <String>[],
  });

  /// How many connection records were on disk before the wipe.
  final int connectionsRemoved;

  /// How many credentials were deleted from the keychain.
  final int credentialsRemoved;

  /// Whether the keychain could be enumerated and emptied in full.
  final bool credentialsComplete;

  /// What went wrong, phrased for someone who has to decide what to do next.
  final List<String> failures;

  /// Whether nothing was left behind.
  bool get isClean => credentialsComplete && failures.isEmpty;
}

/// Puts Dextr back to how it was before anything was configured.
///
/// Only what this application wrote: the two JSON files in its own support
/// directory and the credentials under [SecretsStore.keyPrefix]. Deliberately
/// *not* anything a connection points at — a SQLite file, a Chroma directory, a
/// bucket — because those are the user's data and this is a settings reset, not
/// a delete of the databases the tool was pointed at.
class AppResetService {
  AppResetService({
    required this.connectionsRepo,
    required this.settingsRepo,
    required this.secretsStore,
    this.connectionManager,
  });

  final ConnectionsRepo connectionsRepo;
  final SettingsRepo settingsRepo;
  final SecretsStore secretsStore;

  /// The live sources to close first. Optional so a test can wipe storage
  /// without a manager.
  final ConnectionManager? connectionManager;

  /// Wipes stored state and reports what happened.
  ///
  /// Every step is attempted even if an earlier one failed: half a reset is the
  /// worst outcome, so a locked keychain must not leave the connection records
  /// in place as well.
  Future<AppResetReport> run() async {
    final failures = <String>[];

    // Live sources close first. One that is still open can write a corrected
    // config back through the repo on its own, and that would recreate the file
    // this is about to delete.
    try {
      await connectionManager?.closeAll();
    } on Exception catch (e) {
      failures.add('Some connections could not be closed cleanly.');
      log.w('Reset could not close every live connection: $e');
    }

    var connections = 0;
    try {
      connections = (await connectionsRepo.load()).length;
    } on Exception catch (e) {
      // Only the count is lost — a file too corrupt to read still gets deleted.
      log.w('Reset could not count the stored connections: $e');
    }

    // The keychain goes before the records, the same order a single delete
    // uses: a `secretsRef` is stored nowhere but on its record, so dropping the
    // records first would leave credentials nothing can name, and so nothing
    // could ever reach to delete.
    final credentials = await secretsStore.deleteAll();
    if (!credentials.complete) {
      failures.add(
        'Some stored credentials could not be removed from the keychain.',
      );
    }

    for (final (what, delete) in <(String, Future<void> Function())>[
      ('connections', connectionsRepo.delete),
      ('settings', settingsRepo.delete),
    ]) {
      try {
        await delete();
      } on Exception catch (e) {
        failures.add('The $what file could not be deleted.');
        log.w('Reset could not delete the $what file: $e');
      }
    }

    return AppResetReport(
      connectionsRemoved: connections,
      credentialsRemoved: credentials.removed,
      credentialsComplete: credentials.complete,
      failures: failures,
    );
  }
}
