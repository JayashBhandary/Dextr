import 'dart:convert';
import 'dart:io';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:dextr/app.dart';
import 'package:dextr/connectors/sqlite/sqlite_data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/export_service.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/providers.dart';
import 'package:dextr/ui/widgets/dextr_more_menu.dart';
import 'package:dextr/ui/workspace/query_pane.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Exporting, from the panes, against a real database.
///
/// The encoders are covered in `test/core/tabular_export_test.dart`; what these
/// pin is the wiring — that the button reaches the dialog, that the dialog
/// reaches the file, and that what lands in the file is the rows that were on
/// screen rather than an empty table.
void main() {
  late Directory tmp;

  /// What the save dialog was handed, instead of a save dialog.
  late List<({String name, Uint8List bytes})> saved;
  late String? saveResult;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_export_test');
    saved = <({String name, Uint8List bytes})>[];
    saveResult = '/tmp/export-under-test.out';

    final record = ConnectionRecord(
      id: 'sqlite-1',
      name: 'catalogue.db',
      kind: DataSourceKind.sqlite,
      config: <String, Object?>{'filePath': p.join(tmp.path, 'catalogue.db')},
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
      'INSERT INTO tracks (id, name, seconds) VALUES '
      "(1, 'Intro', 30), "
      "(2, 'Verse, with a comma', 95), "
      "(3, 'Outro', NULL)",
    );
    await seed.dispose();

    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async => tmp.delete(recursive: true));

  ExportService fakeService() => ExportService(
    saveFile: ({
      required String fileName,
      required Uint8List bytes,
      String? dialogTitle,
      List<String>? allowedExtensions,
    }) async {
      saved.add((name: fileName, bytes: bytes));
      return saveResult;
    },
    pickDirectory: ({String? dialogTitle}) async => tmp.path,
  );

  Widget app() => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      exportServiceProvider.overrideWithValue(fakeService()),
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

  /// Opens the connection and the table, leaving the browse pane on screen.
  Future<void> openTable(WidgetTester tester) async {
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
  }

  String lastText() => utf8.decode(saved.last.bytes);

  /// The query pane's own export menu. Found through the pane because the view
  /// bar above it carries a menu of the same shape for the connection.
  final exportMenu = find.descendant(
    of: find.byType(QueryPane),
    matching: find.byType(DextrMoreMenu),
  );

  /// Opens the format selector, which is labelled by the value it is showing.
  Future<void> openFormats(WidgetTester tester, String current) async {
    await tester.tap(find.text(current).last);
    await settle(tester);
  }

  /// Picks a format out of that selector.
  Future<void> chooseFormat(
    WidgetTester tester,
    String current,
    String wanted,
  ) async {
    await openFormats(tester, current);
    await tester.tap(find.text(wanted).last);
    await settle(tester);
  }

  testWidgets('the browse pane exports the page it is showing as CSV', (
    tester,
  ) async {
    await openTable(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);
    // The dialog says what it is about before anything is written.
    expect(find.text('Export tracks'), findsOneWidget);
    expect(find.text('This page (3 rows)'), findsOneWidget);

    // The dialog's own Export button, not the toolbar one behind it.
    await tester.tap(find.text('Export').last);
    await settle(tester);

    expect(saved, hasLength(1));
    expect(saved.single.name, startsWith('tracks-'));
    expect(saved.single.name, endsWith('.csv'));

    final lines = lastText().trim().split('\n');
    expect(lines.first, 'id,name,seconds');
    expect(lines[1], '1,Intro,30');
    // The value with a comma in it is quoted rather than splitting the row.
    expect(lines[2], '2,"Verse, with a comma",95');
    // A NULL is a blank field by default, and the row still has its columns.
    expect(lines[3], '3,Outro,');
  });

  testWidgets('the format chosen is the format written', (tester) async {
    await openTable(tester);
    await tester.tap(find.text('Export'));
    await settle(tester);

    await chooseFormat(tester, 'CSV', 'JSON Lines');
    await tester.tap(find.text('Export').last);
    await settle(tester);

    expect(saved.single.name, endsWith('.jsonl'));
    final rows = lastText()
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect(rows, hasLength(3));
    expect(rows.first, <String, Object?>{
      'id': 1,
      'name': 'Intro',
      'seconds': 30,
    });
    // JSON keeps a null as a null, which is the reason to pick it.
    expect(rows.last['seconds'], isNull);
  });

  testWidgets('every row is paged out of the connection, and a limit is said', (
    tester,
  ) async {
    // More rows than one page, so the export has to page rather than take what
    // the browser happened to load.
    final more = SqliteDataSource(
      record: ConnectionRecord(
        id: 'seed',
        name: 'seed',
        kind: DataSourceKind.sqlite,
        config: <String, Object?>{'filePath': p.join(tmp.path, 'catalogue.db')},
        secretsRef: 'none',
      ),
    );
    await more.connect();
    for (var i = 4; i <= 253; i++) {
      await more.runRawQuery(
        'INSERT INTO tracks (id, name, seconds) VALUES ($i, \'t$i\', $i)',
      );
    }
    await more.dispose();

    await openTable(tester);
    await tester.tap(find.text('Export'));
    await settle(tester);
    await tester.tap(find.text('Every row'));
    await settle(tester);
    await tester.tap(find.text('Export').last);
    await settle(tester, times: 16);

    // 253 rows and a header, from a browser that had only loaded the first 100.
    expect(lastText().trim().split('\n'), hasLength(254));

    // And with a limit set, the file stops there and the message says it did —
    // a short export that looked complete would be the worst outcome here.
    saved.clear();
    await tester.tap(find.text('Export'));
    await settle(tester);
    await tester.tap(find.text('Every row'));
    await settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AstryxNumberInput),
        matching: find.byType(EditableText),
      ),
      '150',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.tap(find.text('Export').last);
    await settle(tester, times: 16);

    expect(lastText().trim().split('\n'), hasLength(151));
    expect(
      find.textContaining('stopped at the row limit'),
      findsOneWidget,
    );
  });

  testWidgets('a cancelled save writes nothing and says so', (tester) async {
    saveResult = null;
    await openTable(tester);
    await tester.tap(find.text('Export'));
    await settle(tester);
    await tester.tap(find.text('Export').last);
    await settle(tester);

    expect(find.text('Export cancelled'), findsOneWidget);
    // The dialog is gone: cancelling the save is not an error to correct.
    expect(find.text('Export tracks'), findsNothing);
  });

  testWidgets('the query pane exports its results and its SQL separately', (
    tester,
  ) async {
    await openTable(tester);
    await tester.tap(find.text('Query'));
    await settle(tester);

    // The query itself: no format to choose, straight to the file.
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(
      find.byType(EditableText),
      'SELECT name FROM tracks WHERE id = 1',
    );
    await settle(tester);

    await tester.tap(exportMenu);
    await settle(tester);
    await tester.tap(find.text('Export the query…'));
    await settle(tester);

    expect(saved.single.name, endsWith('.sql'));
    expect(lastText(), 'SELECT name FROM tracks WHERE id = 1;\n');

    // Exporting results is offered only once there are results.
    saved.clear();
    await tester.tap(find.text('Run'));
    await settle(tester);
    await tester.tap(exportMenu);
    await settle(tester);
    await tester.tap(find.text('Export results…'));
    await settle(tester);
    // One source, so there is nothing to choose between — the title and its
    // description are what say which rows these are.
    expect(find.text('Export the results'), findsOneWidget);
    expect(find.text('What to export'), findsNothing);

    await tester.tap(find.text('Export').last);
    await settle(tester);

    expect(lastText().trim().split('\n'), <String>['name', 'Intro']);
  });

  testWidgets('the schema pane exports its columns, and offers no SQL', (
    tester,
  ) async {
    await openTable(tester);
    await tester.tap(find.text('Schema'));
    await settle(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);
    // An INSERT of a column list is not the CREATE TABLE anyone would mean.
    await openFormats(tester, 'CSV');
    expect(find.text('SQL inserts'), findsNothing);
    expect(find.text('Markdown table'), findsOneWidget);
    await tester.tap(find.text('CSV').last);
    await settle(tester);

    await tester.tap(find.text('Export').last);
    await settle(tester);

    final lines = lastText().trim().split('\n');
    expect(lines.first, 'column,type,nullable,primary_key,default');
    expect(lines[1], startsWith('id,INTEGER,'));
    expect(lines[1], contains('true'));
    expect(saved.single.name, startsWith('tracks-schema-'));
  });
}

class _NoSecrets implements SecretsStore {
  @override
  Future<ConnectionSecrets?> read(String secretsRef) async => null;

  @override
  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {}

  @override
  Future<void> delete(String secretsRef) async {}
  @override
  Future<int> sweepOrphans(Iterable<String> liveRefs) async => 0;

  @override
  Future<({int removed, bool complete})> deleteAll() async =>
      (removed: 0, complete: true);
}
