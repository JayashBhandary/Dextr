import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory keychain, so the credential lifecycle is testable without one.
///
/// Records deletions separately from the surviving map: "was it removed" and
/// "is it absent" are different questions, and the bug this guards against was
/// an entry that was never asked to go away.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage([Map<String, String>? seed])
      : entries = <String, String>{...?seed};

  final Map<String, String> entries;
  final List<String> deleted = <String>[];

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
      await delete(key: key);
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
    deleted.add(key);
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
    if (failReadAll) throw Exception('keystore is locked');
    return Map<String, String>.from(entries);
  }
}

String keyFor(String ref) => '${SecretsStore.keyPrefix}$ref';

void main() {
  test('a written secret round-trips', () async {
    final storage = FakeSecureStorage();
    final store = SecretsStore(storage: storage);

    await store.write('ref-1', const ConnectionSecrets(password: 'hunter2'));
    expect((await store.read('ref-1'))?.password, 'hunter2');
  });

  test('writing an empty set deletes rather than storing an empty blob',
      () async {
    final storage = FakeSecureStorage({keyFor('ref-1'): '{"password":"x"}'});
    final store = SecretsStore(storage: storage);

    await store.write('ref-1', const ConnectionSecrets());
    expect(storage.deleted, [keyFor('ref-1')]);
    expect(storage.entries, isEmpty);
  });

  test('delete removes the entry for that ref and nothing else', () async {
    final storage = FakeSecureStorage({
      keyFor('keep'): '{"password":"a"}',
      keyFor('drop'): '{"password":"b"}',
    });
    final store = SecretsStore(storage: storage);

    await store.delete('drop');
    expect(storage.entries.keys, [keyFor('keep')]);
  });

  group('sweepOrphans', () {
    test('removes entries no live connection refers to', () async {
      final storage = FakeSecureStorage({
        keyFor('live-1'): '{"password":"a"}',
        keyFor('orphan-1'): '{"password":"b"}',
        keyFor('orphan-2'): '{"secretAccessKey":"c"}',
        keyFor('live-2'): '{"bearerToken":"d"}',
      });
      final store = SecretsStore(storage: storage);

      final removed = await store.sweepOrphans(<String>['live-1', 'live-2']);

      expect(removed, 2);
      expect(
        storage.entries.keys.toSet(),
        {keyFor('live-1'), keyFor('live-2')},
      );
    });

    test('leaves keys belonging to anything else in the keychain alone',
        () async {
      final storage = FakeSecureStorage({
        'some.other.app.token': 'not ours',
        keyFor('orphan'): '{"password":"b"}',
      });
      final store = SecretsStore(storage: storage);

      await store.sweepOrphans(const <String>[]);

      expect(storage.entries.keys, ['some.other.app.token']);
    });

    test('is a no-op when every stored secret is still referenced', () async {
      final storage = FakeSecureStorage({keyFor('live'): '{"password":"a"}'});
      final store = SecretsStore(storage: storage);

      expect(await store.sweepOrphans(<String>['live']), 0);
      expect(storage.deleted, isEmpty);
    });

    test('reports nothing removed when the keystore cannot be enumerated',
        () async {
      final storage = FakeSecureStorage({keyFor('orphan'): '{"password":"b"}'})
        ..failReadAll = true;
      final store = SecretsStore(storage: storage);

      // A locked keystore must not fail a launch, and must not be mistaken for
      // an empty one — deleting on that basis would remove live credentials.
      expect(await store.sweepOrphans(const <String>[]), 0);
      expect(storage.deleted, isEmpty);
      expect(storage.entries, hasLength(1));
    });
  });
}
