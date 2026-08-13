import 'dart:io';

import 'package:dextr/app.dart';
import 'package:dextr/connectors/sqlite/sqlite_data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/ui/widgets/page_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Mounts every screen against a real SQLite connection.
///
/// This is a layout test, not a behaviour one. A rewritten screen fails here by
/// throwing during layout — an unbounded height given to something that scrolls,
/// a row that overflows its box — and those are the failures that do not show up
/// in an analyzer run and do not show up until the pane is on screen.
void main() {
  late Directory tmp;
  late ConnectionRecord record;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_ui_test');
    final dbPath = p.join(tmp.path, 'catalogue.db');

    record = ConnectionRecord(
      id: 'sqlite-1',
      name: 'catalogue.db',
      kind: DataSourceKind.sqlite,
      config: <String, Object?>{'filePath': dbPath},
      secretsRef: 'none',
    );

    final seed = SqliteDataSource(record: record);
    await seed.connect();
    await seed.runRawQuery(
      'CREATE TABLE tracks ('
      'id INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'seconds INTEGER, '
      'price REAL)',
    );
    await seed.runRawQuery(
      'INSERT INTO tracks (id, name, seconds, price) VALUES '
      "(1, 'Intro', 30, 0.99), "
      "(2, 'Verse', 95, 1.29), "
      "(3, 'Outro', 48, NULL)",
    );
    await seed.dispose();

    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// A desktop-sized window: the shell hides its rail below 820.
  void sizeWindow(WidgetTester tester, {double width = 1280}) {
    final view = tester.view;
    view.physicalSize = Size(width, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  }

  ProviderScope app({String location = '/'}) => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      routerProvider.overrideWith(
        (ref) => buildRouter(initialLocation: location),
      ),
    ],
    child: const DextrApp(),
  );

  /// Pumps until the connection has opened and the first listing has arrived.
  ///
  /// `runAsync` is what lets the real work happen: reading connections.json and
  /// opening the database are actual file I/O, and `pump` alone only advances
  /// the fake clock, so without this the providers never leave their loading
  /// state and the rail stays empty.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('the workspace lists the tables and browses one', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    // The page surface is installed on the router path too, not just when
    // AstryxApp is given a `home`.
    expect(find.byType(DextrPageSurface), findsOneWidget);

    // The rail found the connection. Select it, then the table under it.
    expect(find.text('catalogue.db'), findsWidgets);

    await tester.tap(find.text('catalogue.db').first);
    await settle(tester);

    expect(find.text('tracks'), findsWidgets);
    await tester.tap(find.text('tracks').first);
    await settle(tester);

    // The browse pane rendered real rows through the table.
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('rows 1–3'), findsOneWidget);
    expect(find.text('Intro'), findsOneWidget);
    expect(find.text('Outro'), findsOneWidget);
    // A null price is drawn as NULL rather than as an empty cell.
    expect(find.text('NULL'), findsWidgets);
  });

  testWidgets('the schema and query views render for the same tab', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('catalogue.db').first);
    await settle(tester);
    await tester.tap(find.text('tracks').first);
    await settle(tester);

    await tester.tap(find.text('Schema'));
    await settle(tester);
    expect(find.text('4 columns'), findsOneWidget);
    expect(find.text('NOT NULL'), findsWidgets);

    await tester.tap(find.text('Query'));
    await settle(tester);
    expect(find.text('No results yet'), findsOneWidget);
  });

  testWidgets('the settings page renders every group', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/settings'));
    await settle(tester);

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme'), findsWidgets);
    expect(find.text('Accent'), findsWidgets);
    expect(find.text('Rows per page'), findsWidgets);
    expect(find.text('Reset to defaults'), findsOneWidget);
  });

  testWidgets('the new-connection form renders each backend', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/connection/new'));
    await settle(tester);

    expect(find.text('New connection'), findsWidgets);

    // Every backend's form has to lay out: they are the screens with the most
    // fields in them, and the ones a picker can reach in one tap.
    for (final kind in DataSourceKind.values) {
      await tester.tap(find.text(kind.label).first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Connection name'),
        findsWidgets,
        reason: 'the ${kind.label} form did not render',
      );
    }
  });
}

/// A secrets store that answers without a keychain.
class _NoSecrets extends SecretsStore {
  final Map<String, ConnectionSecrets> _store = <String, ConnectionSecrets>{};

  @override
  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {
    _store[secretsRef] = secrets;
  }

  @override
  Future<ConnectionSecrets?> read(String secretsRef) async =>
      _store[secretsRef];

  @override
  Future<void> delete(String secretsRef) async {
    _store.remove(secretsRef);
  }
}
