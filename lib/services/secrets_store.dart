import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/connection_secrets.dart';

class SecretsStore {
  // flutter_secure_storage 11 encrypts on Android unconditionally, so the
  // opt-in flag this used to pass no longer exists.
  SecretsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String secretsRef) => 'dextr.secret.$secretsRef';

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
}
