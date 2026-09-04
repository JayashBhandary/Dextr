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
import 'package:dextr/ui/shell/tab_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// How a tab is closed: the button on the tab, the shortcut, and the menu.
///
/// The shortcut is exercised from inside the query editor as well as from the
/// bare page, because that is where the caret actually is when someone reaches
/// for ⌘W — and the editor has hotkeys and a key handler of its own between the
/// caret and the scope that owns closing.
void main() {
  late Directory tmp;
  late ConnectionRecord record;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_tabs_test');
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
    await seed.runRawQuery('CREATE TABLE tracks (id INTEGER PRIMARY KEY)');
    await seed.runRawQuery('CREATE TABLE albums (id INTEGER PRIMARY KEY)');
    await seed.dispose();

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

  Finder inTabs(String text) => find.descendant(
    of: find.byType(WorkspaceTabBar),
    matching: find.text(text),
  );

  /// Opens the connection and a tab on each of the two tables.
  Future<void> openTwoTabs(WidgetTester tester) async {
    final view = tester.view;
    view.physicalSize = const Size(1280, 900);
    view.devicePixelRatio = 1;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('catalogue.db').first);
    await settle(tester);
    await tester.tap(find.text('albums').first);
    await settle(tester);
    await tester.tap(find.text('tracks').first);
    await settle(tester);

    expect(inTabs('albums'), findsOneWidget);
    expect(inTabs('tracks'), findsOneWidget);
  }

  /// The platform's own close chord. `mod` is Control on the test platform.
  Future<void> pressCloseTab(WidgetTester tester, {bool all = false}) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (all) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    if (all) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  testWidgets('every tab carries a close button that closes that tab', (
    tester,
  ) async {
    await openTwoTabs(tester);

    // Named after the tab, so eight open tabs are not eight identical
    // announcements of "Close".
    expect(find.bySemanticsLabel('Close albums'), findsOneWidget);
    expect(find.bySemanticsLabel('Close tracks'), findsOneWidget);

    // The button closes its own tab, not whichever one is selected: `tracks`
    // is the active tab here and `albums` is the one pressed.
    await tester.tap(find.bySemanticsLabel('Close albums'));
    await settle(tester);

    expect(inTabs('albums'), findsNothing);
    expect(inTabs('tracks'), findsOneWidget);
  });

  testWidgets('the close shortcut works with the query editor focused', (
    tester,
  ) async {
    await openTwoTabs(tester);

    // A query tab, and the caret inside its editor: the editor binds hotkeys of
    // its own and handles keys of its own, and neither may eat this one.
    await tester.tap(find.bySemanticsLabel('New query tab'));
    await settle(tester);
    expect(inTabs('Query'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Query').first);
    await settle(tester);

    await pressCloseTab(tester);

    expect(inTabs('Query'), findsNothing);
    expect(inTabs('tracks'), findsOneWidget);
  });

  testWidgets('the shortcut closes the active tab, and all of them with Alt', (
    tester,
  ) async {
    await openTwoTabs(tester);

    await pressCloseTab(tester);
    expect(inTabs('tracks'), findsNothing);
    expect(inTabs('albums'), findsOneWidget);

    await tester.tap(find.text('albums').first);
    await settle(tester);
    await tester.tap(find.text('tracks').first);
    await settle(tester);
    expect(inTabs('tracks'), findsOneWidget);

    await pressCloseTab(tester, all: true);
    expect(find.text('No objects open'), findsOneWidget);
  });

  testWidgets('the close shortcut still reaches the tabs from another page', (
    tester,
  ) async {
    await openTwoTabs(tester);

    // Settings is a route of its own: the shell — and any hotkey scope inside
    // it — is not mounted at all while it is on screen. The binding lives above
    // the router for exactly this, so the shortcut is not dead on every page
    // that is not the workspace.
    await tester.tap(find.bySemanticsLabel('Settings'));
    await settle(tester);
    expect(find.byType(WorkspaceTabBar), findsNothing);

    await pressCloseTab(tester);

    await tester.tap(find.bySemanticsLabel('Close settings'));
    await settle(tester);

    expect(inTabs('tracks'), findsNothing);
    expect(inTabs('albums'), findsOneWidget);
  });

  testWidgets('the menu closes one tab and then all of them', (tester) async {
    await openTwoTabs(tester);

    await tester.tap(find.bySemanticsLabel('Tab actions'));
    await settle(tester);
    await tester.tap(find.text('Close tab'));
    await settle(tester);

    expect(inTabs('tracks'), findsNothing);
    expect(inTabs('albums'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Tab actions'));
    await settle(tester);
    await tester.tap(find.text('Close all tabs'));
    await settle(tester);

    expect(find.text('No objects open'), findsOneWidget);
  });
}

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

  @override
  Future<int> sweepOrphans(Iterable<String> liveRefs) async => 0;

  @override
  Future<({int removed, bool complete})> deleteAll() async =>
      (removed: 0, complete: true);
}
