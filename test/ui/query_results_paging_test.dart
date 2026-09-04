import 'dart:io';

import 'package:dextr/app.dart';
import 'package:dextr/connectors/sqlite/sqlite_data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/sql/sql_row_cap.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/ui/widgets/data_grid.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// What an unqualified `SELECT *` does to the query pane.
///
/// The grid does not virtualise: rows on screen are row widgets, and the number
/// of them has to be bounded by something. Two things bound it — the pane pages
/// what it was given, and the run itself stops at [maxQueryRows] — and this is
/// where both are held to it. The table is seeded with more rows than a page so
/// that a regression shows up as a failure rather than as a slow test.
void main() {
  late Directory tmp;
  late ConnectionRecord record;

  /// Seeds `orders` with [rows] rows, all of them carrying a coupon code.
  Future<void> seedOrders(int rows) async {
    final seed = SqliteDataSource(record: record);
    await seed.connect();
    await seed.runRawQuery(
      'CREATE TABLE orders (id INTEGER PRIMARY KEY, coupon_code TEXT)',
    );
    // Generated in the database rather than in Dart: 10,000 round trips through
    // the connector is the slow way to write the same table.
    await seed.runRawQuery(
      'WITH RECURSIVE seq(n) AS ('
      '  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $rows'
      ') '
      "INSERT INTO orders (id, coupon_code) SELECT n, 'SUMMER' || n FROM seq",
    );
    await seed.dispose();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_paging_test');
    record = ConnectionRecord(
      id: 'sqlite-1',
      name: 'catalogue.db',
      kind: DataSourceKind.sqlite,
      config: <String, Object?>{'filePath': p.join(tmp.path, 'catalogue.db')},
      secretsRef: 'none',
    );
    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async => tmp.delete(recursive: true));

  Widget app() => ProviderScope(
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

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  /// Opens the connection, the table, the query view, and runs the query the
  /// pane got stuck on.
  Future<void> runSelectStar(WidgetTester tester) async {
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
    await tester.tap(find.text('orders').first);
    await settle(tester);
    await tester.tap(find.text('Query'));
    await settle(tester);

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(
      find.byType(EditableText),
      'SELECT * FROM orders WHERE coupon_code IS NOT NULL',
    );
    await settle(tester);
    await tester.tap(find.text('Run'));
    await settle(tester);
  }

  /// How many rows the grid was actually handed.
  int rowsInGrid(WidgetTester tester) =>
      tester.widget<DextrDataGrid>(find.byType(DextrDataGrid)).rows.length;

  testWidgets('a result larger than a page is paged, not drawn at once', (
    tester,
  ) async {
    await seedOrders(250);
    await runSelectStar(tester);

    // The default page size. The other 150 rows are in memory and not in the
    // widget tree, which is the whole point.
    expect(rowsInGrid(tester), 100);
    expect(find.text('rows 1–100 of 250'), findsOneWidget);
    expect(find.text('SUMMER1'), findsOneWidget);
    expect(find.text('SUMMER150'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Next rows'));
    await settle(tester);

    expect(find.text('rows 101–200 of 250'), findsOneWidget);
    expect(find.text('SUMMER150'), findsOneWidget);
    expect(find.text('SUMMER1'), findsNothing);
    expect(rowsInGrid(tester), 100);

    await tester.tap(find.bySemanticsLabel('Previous rows'));
    await settle(tester);
    expect(find.text('rows 1–100 of 250'), findsOneWidget);

    // A new result is a new set of rows: page 3 of the last one means nothing
    // in it, so the run starts at the top again.
    await tester.tap(find.bySemanticsLabel('Next rows'));
    await settle(tester);
    expect(find.text('rows 101–200 of 250'), findsOneWidget);

    await tester.tap(find.text('Run'));
    await settle(tester);
    expect(find.text('rows 1–100 of 250'), findsOneWidget);
  });

  testWidgets('a result past the ceiling stops there and says so', (
    tester,
  ) async {
    await seedOrders(maxQueryRows + 50);
    await runSelectStar(tester);

    // The run kept the ceiling and no more, and the count is marked as one:
    // "10000 rows" on its own reads as the answer to `COUNT(*)`.
    expect(find.text('Showing the first $maxQueryRows rows'), findsOneWidget);
    expect(find.textContaining('$maxQueryRows+ rows'), findsOneWidget);
    expect(find.text('rows 1–100 of $maxQueryRows'), findsOneWidget);
    expect(rowsInGrid(tester), 100);
  });

  testWidgets('a result inside the ceiling is not marked as capped', (
    tester,
  ) async {
    await seedOrders(120);
    await runSelectStar(tester);

    expect(find.textContaining('Showing the first'), findsNothing);
    expect(find.textContaining('120 rows'), findsOneWidget);
    expect(find.text('rows 1–100 of 120'), findsOneWidget);
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
