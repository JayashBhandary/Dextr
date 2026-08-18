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
import 'package:dextr/state/rail_provider.dart';
import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/ui/docs/docs_chapters.dart';
import 'package:dextr/ui/docs/docs_page.dart';
import 'package:dextr/ui/shell/sidebar_connections.dart';
import 'package:dextr/ui/shell/window_frame.dart';
import 'package:dextr/ui/widgets/connection_actions.dart';
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

  testWidgets('every connection in the rail carries its own actions', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    // Nothing is open: the rail's menu is the point — these actions are
    // reachable without opening the connection first.
    expect(find.byType(ConnectionActionsMenu), findsOneWidget);

    // Tapped by widget rather than by semantics label: a nav row wraps its
    // whole content in `ExcludeSemantics`, so the trigger inside one has no
    // semantics node of its own to find it by.
    await tester.tap(find.byType(ConnectionActionsMenu));
    await settle(tester);

    expect(find.text('Edit connection'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Delete connection'), findsOneWidget);

    // The row is a button too, and the press belongs to the menu: opening the
    // actions must not also open the connection.
    expect(find.text('tracks'), findsNothing);
  });

  testWidgets('the rail collapses to its icons and back', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    final wide = tester.getSize(find.byType(ConnectionsRail)).width;
    expect(wide, railExpandedWidth);
    expect(find.text('catalogue.db'), findsWidgets);

    // The button the rail offers, named by what it would do.
    await tester.tap(find.bySemanticsLabel('Collapse the navigation'));
    await settle(tester);

    expect(tester.getSize(find.byType(ConnectionsRail)).width, lessThan(wide));
    // The label is gone from the row and the connection is still reachable —
    // the row keeps its name for a screen reader, and the icon is what is
    // drawn.
    expect(find.text('catalogue.db'), findsNothing);
    expect(find.bySemanticsLabel('catalogue.db'), findsWidgets);
    // The one action a rail this narrow still has to carry.
    expect(find.bySemanticsLabel('New connection'), findsWidgets);

    await tester.tap(find.bySemanticsLabel('Expand the navigation'));
    await settle(tester);

    expect(tester.getSize(find.byType(ConnectionsRail)).width, wide);
    expect(find.text('catalogue.db'), findsWidgets);
  });

  testWidgets('the window frame has an overlay of its own', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    // The band is built above the router, so the navigator's overlay is below
    // it, not above: without one of its own, the first tooltip its window
    // buttons open throws `No Overlay widget found`.
    expect(
      find.ancestor(
        of: find.byType(WindowFrame),
        matching: find.byType(Overlay),
      ),
      findsOneWidget,
    );
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

  testWidgets('the docs page renders every chapter', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/docs'));
    await settle(tester);

    // A table, a key cap and a code block all drew: those are the blocks a
    // prose page fails on, and a section heading alone would also be found in
    // the outline beside it.
    await tester.tap(find.text('SQLite, PostgreSQL, MySQL').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('verifyFull'), findsWidgets);
    expect(
      find.text('postgresql://reader:secret@db.example.com:5432/analytics'),
      findsOneWidget,
    );

    final keysChapter = find.text('Keyboard and pointer').first;
    await tester.ensureVisible(keysChapter);
    await tester.pump();
    await tester.tap(keysChapter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AstryxKbd), findsWidgets);

    await tester.tap(find.text(docsHome.title).first);
    await tester.pump(const Duration(milliseconds: 100));

    // The first chapter, its outline, and the rail that reaches the rest.
    expect(find.text(docsHome.title), findsWidgets);
    expect(find.bySemanticsLabel('On this page'), findsWidgets);

    // Every chapter has to lay out: they carry the tables, the key caps and the
    // code blocks, which is where a prose page overflows if it is going to.
    for (final chapter in docsChapters) {
      // The rail scrolls: a chapter far enough down it is off screen until the
      // list is brought to it.
      final row = find.text(chapter.title).first;
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text(chapter.summary),
        findsOneWidget,
        reason: 'the ${chapter.id} chapter did not render',
      );
      for (final section in chapter.sections) {
        expect(
          find.text(section.title),
          findsWidgets,
          reason: 'the ${chapter.id}/${section.id} section did not render',
        );
      }
    }
  });

  testWidgets('a narrow window puts the chapter list behind a drawer', (
    tester,
  ) async {
    sizeWindow(tester, width: 900);
    await tester.pumpWidget(app(location: '/docs'));
    await settle(tester);

    // The rail is off screen, so the way to it has to be on the page.
    final open = find.bySemanticsLabel('Show the chapter list');
    expect(open, findsOneWidget);

    await tester.tap(open);
    await settle(tester);
    expect(find.text(docsChapters.last.title), findsWidgets);
  });

  testWidgets('the rail reaches the docs', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);

    await tester.tap(find.text('Docs'));
    await settle(tester);

    expect(find.byType(DocsPage), findsOneWidget);
    expect(find.text(docsHome.title), findsWidgets);
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
