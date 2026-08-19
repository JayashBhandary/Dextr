import 'dart:io';

import 'package:dextr/core/capabilities.dart';
import 'package:dextr/domain/app_settings.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/services/app_reset.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// An in-memory keychain shared with something else, so the reset has to be
/// shown to take only what belongs to Dextr.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage([Map<String, String>? seed])
    : entries = <String, String>{...?seed};

  final Map<String, String> entries;

  /// Set to make [readAll] throw, as a locked keystore does.
  bool failReadAll = false;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      entries.remove(key);
      return;
    }
    entries[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => entries[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    entries.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReadAll) throw PlatformException(code: 'locked');
    return Map<String, String>.from(entries);
  }
}

/// What a factory reset must and must not remove.
///
/// The point of pinning this is the "must not": the reset is one press away
/// from a keychain that other applications share and from database files the
/// connections only point at, and neither is Dextr's to delete.
void main() {
  late Directory tmp;
  late ConnectionsRepo connections;
  late SettingsRepo settings;
  late _FakeSecureStorage keychain;
  late SecretsStore secrets;

  ConnectionRecord record(String id, String secretsRef) => ConnectionRecord(
    id: id,
    name: id,
    kind: DataSourceKind.sqlite,
    config: <String, Object?>{'filePath': p.join(tmp.path, '$id.db')},
    secretsRef: secretsRef,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_reset_test');
    connections = ConnectionsRepo(overridePath: tmp.path);
    settings = SettingsRepo(overridePath: tmp.path);
    keychain = _FakeSecureStorage(<String, String>{
      // Something else's entry in the same keychain.
      'other.app.token': 'not ours',
    });
    secrets = SecretsStore(storage: keychain);

    await connections.upsert(record('one', 'ref-one'));
    await connections.upsert(record('two', 'ref-two'));
    await secrets.write(
      'ref-one',
      const ConnectionSecrets(password: 'hunter2'),
    );
    await secrets.write(
      'ref-two',
      const ConnectionSecrets(password: 'hunter3'),
    );
    await settings.save(const AppSettings(pageSize: 500));
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  AppResetService service() => AppResetService(
    connectionsRepo: connections,
    settingsRepo: settings,
    secretsStore: secrets,
  );

  test('removes both files, every credential, and nothing else', () async {
    final report = await service().run();

    expect(report.connectionsRemoved, 2);
    expect(report.credentialsRemoved, 2);
    expect(report.isClean, isTrue);
    expect(report.failures, isEmpty);

    // No file, rather than an empty one: a first launch has neither.
    expect(File(p.join(tmp.path, 'connections.json')).existsSync(), isFalse);
    expect(File(p.join(tmp.path, 'settings.json')).existsSync(), isFalse);

    // Another application's entry in the same keychain is not ours to take.
    expect(keychain.entries, <String, String>{'other.app.token': 'not ours'});
  });

  test('a later load returns the defaults, not the saved settings', () async {
    await service().run();

    // Fresh repos: the ones above cache the file handle, and what matters is
    // what the next launch reads.
    expect(await ConnectionsRepo(overridePath: tmp.path).load(), isEmpty);
    expect(
      (await SettingsRepo(overridePath: tmp.path).load()).pageSize,
      const AppSettings().pageSize,
    );
  });

  test('a locked keychain is reported rather than swallowed', () async {
    keychain.failReadAll = true;

    final report = await service().run();

    // The files still go — half a reset is the worst outcome — but the user is
    // told the credentials are still on the machine.
    expect(File(p.join(tmp.path, 'connections.json')).existsSync(), isFalse);
    expect(File(p.join(tmp.path, 'settings.json')).existsSync(), isFalse);
    expect(report.credentialsRemoved, 0);
    expect(report.credentialsComplete, isFalse);
    expect(report.isClean, isFalse);
    expect(report.failures, isNotEmpty);
    expect(keychain.entries.containsKey('dextr.secret.ref-one'), isTrue);
  });

  test('running twice is not an error', () async {
    await service().run();
    final second = await service().run();

    expect(second.connectionsRemoved, 0);
    expect(second.credentialsRemoved, 0);
    expect(second.isClean, isTrue);
  });
}
