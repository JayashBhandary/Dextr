import 'dart:io';

import 'package:dextr/connectors/sqlite/sqlite_data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/errors.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/services/file_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Stands in for the macOS sandbox so these run anywhere. It records the
/// balance of grants and revokes, which is the part that leaks if it is wrong.
class FakeFileAccess extends FileAccess {
  FakeFileAccess({this.resolvesTo, this.refreshed});

  /// Where the bookmark resolves, or null to refuse the grant.
  final String? resolvesTo;

  /// A replacement bookmark, as a stale one produces.
  final String? refreshed;

  final List<String> granted = <String>[];
  final List<String> revoked = <String>[];
  int issued = 0;

  @override
  bool get isSupported => true;

  @override
  Future<String?> bookmark(String path) async => 'bookmark-for:$path';

  @override
  Future<FileGrant?> grant(String bookmark) async {
    granted.add(bookmark);
    final path = resolvesTo;
    if (path == null) return null;
    issued++;
    return FileGrant(
      token: 'token-$issued',
      path: path,
      bookmark: refreshed,
    );
  }

  @override
  Future<void> revoke(String? token) async {
    if (token != null) revoked.add(token);
  }
}

void main() {
  late Directory tmp;
  late String dbPath;

  ConnectionRecord recordFor(String path, {String? bookmark}) =>
      ConnectionRecord(
        id: 'test-sqlite',
        name: 'Test SQLite',
        kind: DataSourceKind.sqlite,
        config: {
          FileAccess.pathKey: path,
          FileAccess.bookmarkKey: ?bookmark,
        },
        secretsRef: 'none',
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_file_access_test');
    dbPath = p.join(tmp.path, 'test.db');
    // Give the bookmarked file real contents so opening it can succeed.
    final seed = SqliteDataSource(record: recordFor(dbPath));
    await seed.connect();
    await seed.runRawQuery('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await seed.dispose();
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('a record without a bookmark never asks for a grant', () async {
    final access = FakeFileAccess(resolvesTo: dbPath);
    final src = SqliteDataSource(
      record: recordFor(dbPath),
      fileAccess: access,
    );
    await src.connect();
    await src.dispose();
    expect(access.granted, isEmpty);
  });

  test('a bookmarked record is granted access and releases it on close',
      () async {
    final access = FakeFileAccess(resolvesTo: dbPath);
    final src = SqliteDataSource(
      record: recordFor(dbPath, bookmark: 'saved'),
      fileAccess: access,
    );
    await src.connect();
    expect(access.granted, ['saved']);
    expect(access.revoked, isEmpty);

    await src.dispose();
    expect(access.revoked, ['token-1']);
  });

  test('a moved file is opened where the bookmark says it now lives', () async {
    final moved = p.join(tmp.path, 'moved.db');
    await File(dbPath).rename(moved);
    final access = FakeFileAccess(resolvesTo: moved, refreshed: 'fresh');
    final src = SqliteDataSource(
      // The stored path is the one the file has left.
      record: recordFor(dbPath, bookmark: 'stale'),
      fileAccess: access,
    );
    await src.connect();
    expect(await src.listContainers(), isNotEmpty);
    expect(src.correctedConfig, {
      FileAccess.pathKey: moved,
      FileAccess.bookmarkKey: 'fresh',
    });
    await src.dispose();
  });

  test('a refused grant still tries the path, and says why it failed',
      () async {
    // A path sqlite cannot open at all — it creates a missing *file*, but not
    // a missing directory to put it in.
    final unopenable = p.join(tmp.path, 'no-such-dir', 'test.db');
    final access = FakeFileAccess();
    final src = SqliteDataSource(
      record: recordFor(unopenable, bookmark: 'revoked'),
      fileAccess: access,
    );
    await expectLater(
      src.connect(),
      throwsA(
        isA<ConnectError>().having(
          (e) => e.message,
          'message',
          contains('pick the file again'),
        ),
      ),
    );
    // Nothing was ever granted, so nothing must be released.
    expect(access.revoked, isEmpty);
  });

  test('a successful connect reports no corrections', () async {
    final access = FakeFileAccess(resolvesTo: dbPath);
    final src = SqliteDataSource(
      record: recordFor(dbPath, bookmark: 'saved'),
      fileAccess: access,
    );
    await src.connect();
    expect(src.correctedConfig, isEmpty);
    await src.dispose();
  });
}
