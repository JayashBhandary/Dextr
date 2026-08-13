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
import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/theme/app_theme.dart';
import 'package:dextr/ui/connection_form/kind_picker.dart';
import 'package:dextr/ui/shell/sidebar_connections.dart';
import 'package:dextr/ui/shell/window_frame.dart';
import 'package:dextr/ui/widgets/dextr_icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Geometry, not content: the things that look wrong on screen while every
/// widget is present and every test above still passes. A control that fills a
/// row it should hug, or an icon half a line below its neighbours, is only
/// visible in the numbers.
void main() {
  late Directory tmp;
  late ConnectionRecord record;

  const windowWidth = 1280.0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_alignment_test');
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
    await seed.dispose();

    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async => tmp.delete(recursive: true));

  void sizeWindow(WidgetTester tester) {
    final view = tester.view;
    view.physicalSize = const Size(windowWidth, 900);
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('the connection menu hangs off its trigger, not off the window', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('catalogue.db').first);
    await settle(tester);

    await tester.tap(find.bySemanticsLabel('Connection actions').first);
    await settle(tester);

    expect(find.text('Edit connection'), findsOneWidget);
    final row = tester.getRect(find.text('Delete connection'));
    // The trigger sits at the end of the view bar, so a menu sized to its own
    // content starts well into the right-hand half. One sized to the viewport
    // starts at the window's edge.
    expect(row.left, greaterThan(windowWidth / 2));
  });

  testWidgets('every backend card puts its icon on the same line', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/connection/new'));
    await settle(tester);

    final icons = find.descendant(
      of: find.byType(KindPicker),
      matching: find.byType(DextrIcon),
    );
    expect(icons, findsNWidgets(DataSourceKind.values.length));

    // Cards on one row of the grid share a row of the screen, so their icons
    // share a top edge — whatever the description below them does.
    final tops = <double, List<double>>{};
    for (var i = 0; i < tester.widgetList(icons).length; i++) {
      final rect = tester.getRect(icons.at(i));
      // Group by the row the card is on, to the nearest 50 logical pixels.
      tops.putIfAbsent((rect.top / 50).roundToDouble(), () => <double>[]);
      tops[(rect.top / 50).roundToDouble()]!.add(rect.top);
    }
    expect(tops.length, greaterThan(1), reason: 'expected more than one row');
    for (final row in tops.values) {
      expect(row.toSet(), hasLength(1));
    }
  });

  testWidgets('the file field does not say "Choose file" twice', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/connection/new'));
    await settle(tester);

    expect(find.text('No file chosen'), findsOneWidget);
    expect(find.text('Choose file'), findsOneWidget);
  });

  testWidgets('accent swatches sit several to a row', (tester) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/settings'));
    await settle(tester);

    final first = tester.getRect(find.text('Theme default'));
    final second = tester.getRect(find.text('Indigo'));

    // Side by side, not stacked: same line, different column.
    expect(second.top, closeTo(first.top, 1));
    expect(second.left, greaterThan(first.left));
  });

  testWidgets('the close button sits at the end of the header', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/settings'));
    await settle(tester);

    final close = tester.getRect(find.bySemanticsLabel('Close settings'));
    // Hard against the trailing edge, give or take the page's own inset —
    // not stranded mid-row by a spacer that only got half the free space.
    expect(close.right, greaterThan(windowWidth - 60));
  });

  testWidgets('the rail paints to the top and insets its own rows', (
    tester,
  ) async {
    sizeWindow(tester);
    const inset = 40.0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionsRepoProvider.overrideWithValue(
            ConnectionsRepo(overridePath: tmp.path),
          ),
          settingsRepoProvider.overrideWithValue(
            SettingsRepo(overridePath: tmp.path),
          ),
          secretsStoreProvider.overrideWithValue(_NoSecrets()),
        ],
        child: AstryxApp(
          theme: buildDextrTheme(theme: DextrTheme.neutral),
          home: const WindowCaptionScope(
            inset: inset,
            child: ConnectionsRail(),
          ),
        ),
      ),
    );
    await settle(tester);

    final fill = tester.getRect(
      find
          .descendant(
            of: find.byType(ConnectionsRail),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    // The colour starts at the window's edge; the rows start below the
    // window's buttons. That gap is the whole point of the inset.
    expect(fill.top, 0);
    expect(
      tester.getRect(find.text('Connections').first).top,
      greaterThanOrEqualTo(inset),
    );
  });

  testWidgets('the segmented controls carry a label that is drawn', (
    tester,
  ) async {
    sizeWindow(tester);
    await tester.pumpWidget(app(location: '/settings'));
    await settle(tester);

    // Not just an accessible name — text on screen, like every other field in
    // the group.
    expect(find.text('Colour mode'), findsOneWidget);
    expect(find.text('Density'), findsOneWidget);
  });
}

class _NoSecrets implements SecretsStore {
  @override
  Future<void> delete(String ref) async {}

  @override
  Future<ConnectionSecrets?> read(String ref) async => null;

  @override
  Future<void> write(String ref, ConnectionSecrets secrets) async {}
}
