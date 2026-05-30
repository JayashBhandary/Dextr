import 'dart:io';

import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/query_spec.dart';
import 'package:dextr/connectors/sqlite/sqlite_data_source.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end exercise of the SQLite connector through the full DataSource API
/// (M1): connect, list, browse, raw query, CRUD, schema. Uses a temp file so
/// persistence across reopen is verified.
void main() {
  late Directory tmp;
  late ConnectionRecord record;
  late SqliteDataSource src;

  ConnectionRecord recordFor(String path) => ConnectionRecord(
        id: 'test-sqlite',
        name: 'Test SQLite',
        kind: DataSourceKind.sqlite,
        config: {'filePath': path},
        secretsRef: 'none',
      );

  const tracks = ContainerRef(name: 'tracks');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_sqlite_test');
    record = recordFor(p.join(tmp.path, 'test.db'));
    src = SqliteDataSource(record: record);
    await src.connect();
    await src.runRawQuery(
      'CREATE TABLE tracks ('
      'id INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'seconds INTEGER, '
      'price REAL)',
    );
    await src.runRawQuery(
      'INSERT INTO tracks (id, name, seconds, price) VALUES '
      "(1, 'Intro', 30, 0.99), "
      "(2, 'Verse', 95, 1.29), "
      "(3, 'Outro', 45, 0.99)",
    );
  });

  tearDown(() async {
    await src.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('exposes SQL capabilities and matches plan matrix', () {
    expect(src.kind, DataSourceKind.sqlite);
    expect(src, isA<RawQueryable>());
    expect(src, isA<Writable>());
    expect(src, isA<SchemaReadable>());
    expect(src, isA<SchemaMutable>());
    expect(src.capabilities, contains(Capability.rawQuery));
  });

  test('ping succeeds on an open connection', () async {
    await expectLater(src.ping(), completes);
  });

  test('listContainers returns user tables, hides sqlite_ internals', () async {
    final containers = await src.listContainers();
    expect(containers.map((c) => c.name), contains('tracks'));
    expect(containers.every((c) => !c.name.startsWith('sqlite_')), isTrue);
  });

  test('listRows respects limit and ordering', () async {
    final page = await src.listRows(
      tracks,
      const QuerySpec(orderBy: [SortClause('id', SortDir.desc)], limit: 2),
    );
    expect(page.items, hasLength(2));
    expect((page.items.first['id'] as NumCell).value, 3);
    // limit reached -> a next cursor is offered.
    expect(page.hasMore, isTrue);
  });

  test('listRows applies WHERE filters', () async {
    final page = await src.listRows(
      tracks,
      const QuerySpec(
        where: [FilterClause('price', FilterOp.eq, NumCell(0.99))],
      ),
    );
    expect(page.items, hasLength(2));
  });

  test('raw SELECT returns typed columns and rows', () async {
    final res = await src.runRawQuery('SELECT name FROM tracks WHERE id = 2');
    expect(res.columns, ['name']);
    expect((res.rows.single['name'] as StringCell).value, 'Verse');
    expect(res.elapsed, isNotNull);
  });

  test('bad SQL raises a QueryError with the engine message', () async {
    await expectLater(
      src.runRawQuery('SELECT * FROM no_such_table'),
      throwsA(isA<Object>()),
    );
  });

  test('insert / update / delete round-trip persists', () async {
    await src.insertRow(tracks, {
      'id': const NumCell(4),
      'name': const StringCell('Bridge'),
      'seconds': const NumCell(60),
    });
    final afterInsert = await src.getRow(tracks, const RowId({'id': NumCell(4)}));
    expect((afterInsert!['name'] as StringCell).value, 'Bridge');

    final updated = await src.updateRow(
      tracks,
      const RowId({'id': NumCell(4)}),
      {'name': const StringCell('Bridge II')},
    );
    expect(updated, 1);

    final deleted =
        await src.deleteRow(tracks, const RowId({'id': NumCell(4)}));
    expect(deleted, 1);
    final afterDelete =
        await src.getRow(tracks, const RowId({'id': NumCell(4)}));
    expect(afterDelete, isNull);
  });

  test('getSchema reports columns, types, nullability, primary key', () async {
    final schema = await src.getSchema(tracks);
    final byName = {for (final c in schema.columns) c.name: c};
    expect(byName.keys, containsAll(['id', 'name', 'seconds', 'price']));
    expect(byName['id']!.isPrimaryKey, isTrue);
    expect(byName['name']!.nullable, isFalse);
    expect(schema.pkColumns, ['id']);
  });

  test('edited value persists across a reconnect', () async {
    await src.updateRow(
      tracks,
      const RowId({'id': NumCell(1)}),
      {'name': const StringCell('Intro (remastered)')},
    );
    await src.disconnect();

    final reopened = SqliteDataSource(record: record);
    await reopened.connect();
    final row = await reopened.getRow(tracks, const RowId({'id': NumCell(1)}));
    expect((row!['name'] as StringCell).value, 'Intro (remastered)');
    await reopened.dispose();
  });

  test('transaction rollback discards writes', () async {
    await src.beginTx();
    await src.insertRow(tracks, {
      'id': const NumCell(99),
      'name': const StringCell('Temp'),
    });
    await src.rollback();
    final row = await src.getRow(tracks, const RowId({'id': NumCell(99)}));
    expect(row, isNull);
  });

  test('createContainer and dropContainer mutate schema', () async {
    const tags = ContainerRef(name: 'tags');
    await src.createContainer(const ContainerSchema(
      container: tags,
      columns: [
        ColumnSchema(name: 'id', typeLabel: 'INTEGER', isPrimaryKey: true),
        ColumnSchema(name: 'label', typeLabel: 'TEXT', nullable: false),
      ],
    ));
    expect((await src.listContainers()).map((c) => c.name), contains('tags'));

    await src.dropContainer(tags);
    expect(
      (await src.listContainers()).map((c) => c.name),
      isNot(contains('tags')),
    );
  });
}
