import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/logger.dart';
import '../domain/connection_secrets.dart';

class SecretsStore {
  // flutter_secure_storage 11 encrypts on Android unconditionally, so the
  // opt-in flag this used to pass no longer exists.
  SecretsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Prefix every key this application owns carries.
  ///
  /// Named because [sweepOrphans] has to tell our entries apart from anything
  /// else sharing the same keychain service.
  static const String keyPrefix = 'dextr.secret.';

  String _key(String secretsRef) => '$keyPrefix$secretsRef';

  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {
    if (secrets.isEmpty) {
      await _storage.delete(key: _key(secretsRef));
      return;
    }
    await _storage.write(key: _key(secretsRef), value: secrets.encode());
  }

  Future<ConnectionSecrets?> read(String secretsRef) async {
    final raw = await _storage.read(key: _key(secretsRef));
    if (raw == null) return null;
    return ConnectionSecrets.decode(raw);
  }

  Future<void> delete(String secretsRef) async {
    await _storage.delete(key: _key(secretsRef));
  }

  /// Deletes every stored secret no live connection refers to any more.
  ///
  /// Needed because a `secretsRef` exists only on the connection record that
  /// points at it: a release that removed a record without removing its secret
  /// left a credential in the keychain that nothing can name, and so nothing
  /// could ever reach to delete. Sweeping is the only way those come back.
  ///
  /// Returns how many were removed, so a caller can say so out loud once.
  Future<int> sweepOrphans(Iterable<String> liveRefs) async {
    // Whether the keychain could be read at all is deliberately dropped here: a
    // locked or unavailable keystore is not a reason to fail a launch, and the
    // sweep is idempotent, so the next one picks up whatever is left.
    final result = await _deleteExcept(liveRefs.map(_key).toSet());
    if (result.removed > 0) {
      // Counted, never named: the ref is all we have and it identifies a
      // credential.
      log.i(
        'Removed ${result.removed} orphaned credential(s) from the keychain',
      );
    }
    return result.removed;
  }

  /// Deletes every credential this application owns, for a factory reset.
  ///
  /// [complete] is the part a caller must not ignore: a locked or unavailable
  /// keystore is survivable for the orphan sweep, which runs again next launch,
  /// but a reset that quietly left credentials behind has told the user
  /// something untrue. Reported so the UI can say so.
  Future<({int removed, bool complete})> deleteAll() async {
    final result = await _deleteExcept(const <String>{});
    if (result.removed > 0) {
      log.i('Removed ${result.removed} stored credential(s) from the keychain');
    }
    return result;
  }

  /// Deletes every key this application owns except those in [keep].
  ///
  /// [complete] is false when the keychain could not be enumerated at all, or
  /// when an individual delete failed — either way, entries may survive.
  Future<({int removed, bool complete})> _deleteExcept(Set<String> keep) async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } on Exception catch (e) {
      log.w('Could not enumerate stored secrets: $e');
      return (removed: 0, complete: false);
    }

    var removed = 0;
    var complete = true;
    for (final key in all.keys) {
      if (!key.startsWith(keyPrefix) || keep.contains(key)) continue;
      try {
        await _storage.delete(key: key);
        removed++;
      } on Exception catch (e) {
        complete = false;
        log.w('Could not delete stored secret: $e');
      }
    }
    return (removed: removed, complete: complete);
  }
}
