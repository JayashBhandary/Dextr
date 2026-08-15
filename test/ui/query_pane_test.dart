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
import 'package:dextr/state/workspace_provider.dart';
import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/ui/widgets/data_grid.dart';
import 'package:dextr/ui/widgets/sql_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The query tab against a real connection: what it suggests comes from the
/// schema of the database that is actually open, and typing does not drag the
/// results table through a rebuild behind it.
void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_query_test');
    final dbPath = p.join(tmp.path, 'catalogue.db');

    final record = ConnectionRecord(
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
      'seconds INTEGER)',
    );
    await seed.runRawQuery(
      "INSERT INTO tracks (id, name, seconds) VALUES (1, 'Intro', 30)",
    );
    await seed.dispose();

    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async => tmp.delete(recursive: true));

  Widget app() {
    container = ProviderContainer(
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
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: const DextrApp(),
    );
  }

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  /// Opens the connection, the table, and the query view over it.
  Future<void> openQueryView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('catalogue.db').first);
    await settle(tester);
    await tester.tap(find.text('tracks').first);
    await settle(tester);
    await tester.tap(find.text('Query'));
    await settle(tester);
  }

  Future<void> typeQuery(WidgetTester tester, String sql) async {
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), sql);
    await settle(tester);
  }

  testWidgets('the tables of the open connection are suggested', (
    tester,
  ) async {
    await openQueryView(tester);
    await typeQuery(tester, 'SELECT * FROM tra');

    // 'tracks' is in the rail as well, so the suggestion is the one inside the
    // list that just opened over the editor.
    expect(find.text('tracks'), findsWidgets);
    expect(find.text('table'), findsWidgets);
  });

  testWidgets('the columns of a named table are suggested, from its schema', (
    tester,
  ) async {
    await openQueryView(tester);
    await typeQuery(tester, 'SELECT * FROM tracks WHERE ');
    // The schema is a round trip: it arrives a beat after the statement names
    // the table.
    await settle(tester);

    expect(find.text('seconds'), findsWidgets);
    expect(find.textContaining('INTEGER'), findsWidgets);
  });

  testWidgets('the selected table is suggested from without being named', (
    tester,
  ) async {
    // The rail opened `tracks` and the view switched to Query over it, so the
    // schema is fetched by the pane rather than waiting for the text to name
    // the table.
    await openQueryView(tester);
    await typeQuery(tester, 'SELECT ');
    await settle(tester);

    // Every column of `tracks`, with no FROM clause anywhere in the editor.
    expect(find.text('id'), findsWidgets);
    expect(find.text('name'), findsWidgets);
    expect(find.text('seconds'), findsWidgets);
    // And their types, which is what the round trip to the schema was for.
    expect(find.textContaining('INTEGER'), findsWidgets);
  });

  testWidgets('the selected table leads the list after FROM', (tester) async {
    await openQueryView(tester);
    await typeQuery(tester, 'SELECT * FROM ');
    await settle(tester);

    // The list says which table the rail is on, so picking it is a glance
    // rather than a search.
    expect(find.text('table · selected'), findsOneWidget);
  });

  testWidgets('typing does not write through the workspace on every key', (
    tester,
  ) async {
    await openQueryView(tester);
    final tabId = container.read(workspaceProvider).activeTabId!;

    await typeQuery(tester, 'SELECT 1');

    // Nothing yet: the write is debounced, which is the whole point.
    expect(
      container
          .read(workspaceProvider)
          .tabs
          .firstWhere((t) => t.id == tabId)
          .queryText,
      '',
    );
    await tester.pump(const Duration(milliseconds: 500));

    // The store is written to when the typing stops. Between keystrokes it is
    // deliberately behind, because every write of it rebuilds the workspace —
    // results table included — and that is what made the editor unusable once
    // a query had returned any real number of rows.
    final tab = container
        .read(workspaceProvider)
        .tabs
        .firstWhere((t) => t.id == tabId);
    expect(tab.queryText, 'SELECT 1');
  });

  testWidgets('running from the editor puts rows in the grid', (tester) async {
    await openQueryView(tester);
    await typeQuery(tester, 'SELECT name FROM tracks');

    await tester.tap(find.text('Run'));
    await settle(tester);

    expect(find.byType(DextrDataGrid), findsOneWidget);
    expect(find.text('Intro'), findsWidgets);
    expect(find.textContaining('1 row'), findsWidgets);
  });

  testWidgets('only the statement at the caret is run', (tester) async {
    await openQueryView(tester);
    await typeQuery(
      tester,
      "SELECT 'first' AS which; SELECT 'second' AS which",
    );

    // The caret is left at the end by the typing, which is inside the second
    // statement.
    await tester.tap(find.text('Run'));
    await settle(tester);

    expect(find.text('second'), findsWidgets);
    expect(find.text('first'), findsNothing);
  });

  testWidgets('the handle between the query and the result moves the split', (
    tester,
  ) async {
    await openQueryView(tester);

    final handle = find.byType(AstryxResizeHandle);
    expect(handle, findsOneWidget);

    double editorHeight() => tester.getSize(find.byType(SqlEditor)).height;
    // Where the seam sits, which is the other half's ceiling.
    double seam() => tester.getTopLeft(handle).dy;

    final before = editorHeight();
    final seamBefore = seam();

    // Down grows the query half, which is the half the handle sits under.
    // No touch slop: the drag is measured against the pointer, and the default
    // slop would eat the first 20 of the 120 before the handle saw any of it.
    await tester.drag(handle, const Offset(0, 120), touchSlopY: 0);
    await tester.pump();

    expect(editorHeight(), closeTo(before + 120, 1));
    // The seam moved with it rather than the card growing: what the query half
    // took, the result half gave up.
    expect(seam(), closeTo(seamBefore + 120, 1));

    // Back up again, past the floor, to check the query half cannot be dragged
    // out of existence.
    await tester.drag(handle, const Offset(0, -4000), touchSlopY: 0);
    await tester.pump();
    expect(editorHeight(), greaterThan(0));
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
