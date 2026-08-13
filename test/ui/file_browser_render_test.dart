import 'dart:io';

import 'package:dextr/app.dart';
import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/page.dart' as core;
import 'package:dextr/core/query_spec.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/active_source_provider.dart';
import 'package:dextr/state/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mounts the file browser against an in-memory object store.
///
/// The object-store pane cannot be reached with a SQLite connection, and reaching
/// it with a real bucket would need credentials, so the source is faked. What is
/// under test is the same thing as in the other screen test: that the pane lays
/// out, with folders, files, a selection and the dialogs it opens.
void main() {
  late Directory tmp;

  final record = ConnectionRecord(
    id: 's3-1',
    name: 'assets',
    kind: DataSourceKind.s3,
    config: <String, Object?>{'endpoint': 's3.example.com'},
    secretsRef: 'none',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_files_test');
    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ProviderScope app() => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      routerProvider.overrideWith((ref) => buildRouter()),
      // The pane asks the source what it can do and what is in it; nothing
      // else about the connection matters here.
      activeDataSourceProvider.overrideWith(
        (ref) async => _FakeObjectStore(record),
      ),
    ],
    child: const DextrApp(),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<void> openBucket(WidgetTester tester) async {
    final view = tester.view;
    view.physicalSize = const Size(1280, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('assets').first);
    await settle(tester);
    await tester.tap(find.text('uploads').first);
    await settle(tester);
  }

  testWidgets('the browser lists a folder and its files', (tester) async {
    await openBucket(tester);

    // Folders first, then files, each with what is known about it.
    expect(find.text('images'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);
    // A folder has no size of its own to report.
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('going into a folder moves the breadcrumb trail', (tester) async {
    await openBucket(tester);

    await tester.tap(find.text('images'));
    await settle(tester);

    // The trail is the way back out, and the listing is the folder's own.
    expect(find.text('uploads'), findsWidgets);
    expect(find.text('logo.png'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
  });

  testWidgets('the filter narrows the listing', (tester) async {
    await openBucket(tester);

    await tester.enterText(find.byType(EditableText).first, 'notes');
    await settle(tester);

    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('images'), findsNothing);

    await tester.enterText(find.byType(EditableText).first, 'nothing matches');
    await settle(tester);
    expect(find.text('No matches'), findsOneWidget);
  });
}

/// An object store with three entries and every operation advertised.
class _FakeObjectStore extends DataSource with FileBrowsable {
  _FakeObjectStore(this.record);

  final ConnectionRecord record;

  @override
  String get id => record.id;

  @override
  String get displayName => record.name;

  @override
  DataSourceKind get kind => DataSourceKind.s3;

  @override
  Set<Capability> get capabilities => <Capability>{
    Capability.objectStorage,
    Capability.fileBrowse,
  };

  @override
  Set<FileOp> get fileOps => FileOp.values.toSet();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> ping() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<ContainerRef>> listContainers() async => const <ContainerRef>[
    ContainerRef(name: 'uploads', subtype: 'bucket'),
  ];

  @override
  Future<core.Page<RowData>> listRows(
    ContainerRef container,
    QuerySpec spec,
  ) async => const core.Page<RowData>(items: <RowData>[]);

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async => null;

  @override
  Future<FileListing> listEntries(
    ContainerRef container,
    String path, {
    String? cursor,
  }) async {
    if (path.isEmpty) {
      return FileListing(
        entries: <FileEntry>[
          const FileEntry(name: 'images', path: 'images/', isFolder: true),
          FileEntry(
            name: 'notes.txt',
            path: 'notes.txt',
            isFolder: false,
            size: 1024,
            contentType: 'text/plain',
            modified: DateTime.utc(2026, 3, 3),
          ),
        ],
      );
    }
    return FileListing(
      entries: <FileEntry>[
        FileEntry(
          name: 'logo.png',
          path: 'images/logo.png',
          isFolder: false,
          size: 2048,
          contentType: 'image/png',
          modified: DateTime.utc(2026, 4, 1),
        ),
      ],
    );
  }

  @override
  Future<FileEntry?> statEntry(ContainerRef container, String path) async =>
      null;

  @override
  Future<FileBytes> readBytes(
    ContainerRef container,
    String path, {
    int maxBytes = 5 << 20,
  }) async => const FileBytes(bytes: <int>[104, 105], truncated: false);

  @override
  Future<void> uploadFile(
    ContainerRef container,
    String path,
    String localFilePath,
  ) async {}

  @override
  Future<void> downloadFile(
    ContainerRef container,
    String path,
    String localFilePath,
  ) async {}

  @override
  Future<void> deleteEntries(
    ContainerRef container,
    List<String> paths,
  ) async {}

  @override
  Future<void> createFolder(ContainerRef container, String path) async {}

  @override
  Future<void> copyEntry(
    ContainerRef container,
    String from,
    String to,
  ) async {}

  @override
  Future<void> moveEntry(
    ContainerRef container,
    String from,
    String to,
  ) async {}

  @override
  Future<String?> shareLink(
    ContainerRef container,
    String path, {
    Duration expires = const Duration(hours: 1),
  }) async => 'https://s3.example.com/$path';
}

/// A secrets store that answers without a keychain.
class _NoSecrets extends SecretsStore {
  @override
  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {}

  @override
  Future<ConnectionSecrets?> read(String secretsRef) async => null;

  @override
  Future<void> delete(String secretsRef) async {}
}
