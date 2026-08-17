import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dextr/connectors/vector/backends/chroma_file_backend.dart';
import 'package:dextr/connectors/vector/vector_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Builds a Chroma persist directory by hand: the SQLite catalogue Chroma
/// writes, and the hnswlib index files beside it.
///
/// This is the mode with no server in front of it, so there is no fake to stand
/// in for one — the only way to test it is to write the files Chroma writes and
/// read them back.
class _Persist {
  _Persist(this.directory);

  final Directory directory;

  String get path => directory.path;

  static Future<_Persist> create() async {
    final directory = await Directory.systemTemp.createTemp('chroma-persist');
    final persist = _Persist(directory);
    persist._schema();
    return persist;
  }

  Database get _db => sqlite3.open(p.join(path, 'chroma.sqlite3'));

  void _schema() {
    final db = _db;
    db.execute('''
      CREATE TABLE collections (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, dimension INTEGER,
        database_id TEXT, config_json_str TEXT);
      CREATE TABLE collection_metadata (
        collection_id TEXT, key TEXT NOT NULL, str_value TEXT,
        int_value INTEGER, float_value REAL, bool_value INTEGER,
        PRIMARY KEY (collection_id, key));
      CREATE TABLE segments (
        id TEXT PRIMARY KEY, type TEXT NOT NULL, scope TEXT NOT NULL,
        collection TEXT NOT NULL);
      CREATE TABLE embeddings (
        id INTEGER PRIMARY KEY, segment_id TEXT NOT NULL,
        embedding_id TEXT NOT NULL, seq_id BLOB, created_at TIMESTAMP);
      CREATE TABLE embedding_metadata (
        id INTEGER, key TEXT NOT NULL, string_value TEXT, int_value INTEGER,
        float_value REAL, bool_value INTEGER, PRIMARY KEY (id, key));
      CREATE TABLE embeddings_queue (
        seq_id INTEGER PRIMARY KEY, created_at TIMESTAMP, operation INTEGER,
        topic TEXT, id TEXT, vector BLOB, encoding TEXT, metadata TEXT);
    ''');
    db.close();
  }

  /// Adds a collection whose vectors live in an hnsw index on disk.
  ///
  /// [labels] is the hnswlib label of each stored element, in file order.
  /// Chroma hands them out in insertion order, but they are *not* the same as
  /// position once anything has been deleted — passing them explicitly is what
  /// lets a test prove the id mapping rather than assume it.
  Future<void> addIndexed({
    required String name,
    required List<List<double>> vectors,
    required List<int> labels,
    required List<String> ids,
    Map<String, Map<String, Object?>> metadata = const {},
    Map<String, String> documents = const {},
    String space = 'cosine',
    int? count,
  }) async {
    final collectionId = 'col-$name';
    final vectorSegment = 'seg-vec-$name';
    final metadataSegment = 'seg-meta-$name';

    final db = _db;
    db.execute(
      'INSERT INTO collections (id, name, dimension) VALUES (?, ?, ?)',
      <Object?>[collectionId, name, vectors.isEmpty ? null : vectors.first.length],
    );
    db.execute(
      'INSERT INTO collection_metadata (collection_id, key, str_value) '
      'VALUES (?, ?, ?)',
      <Object?>[collectionId, 'hnsw:space', space],
    );
    db.execute(
      'INSERT INTO segments (id, type, scope, collection) VALUES (?,?,?,?)',
      <Object?>[vectorSegment, 'hnsw', 'VECTOR', collectionId],
    );
    db.execute(
      'INSERT INTO segments (id, type, scope, collection) VALUES (?,?,?,?)',
      <Object?>[metadataSegment, 'sqlite', 'METADATA', collectionId],
    );
    for (var i = 0; i < ids.length; i++) {
      db.execute(
        'INSERT INTO embeddings (id, segment_id, embedding_id) VALUES (?,?,?)',
        <Object?>[i + 1, metadataSegment, ids[i]],
      );
      final document = documents[ids[i]];
      if (document != null) {
        db.execute(
          'INSERT INTO embedding_metadata (id, key, string_value) '
          'VALUES (?,?,?)',
          <Object?>[i + 1, 'chroma:document', document],
        );
      }
      final meta = metadata[ids[i]];
      if (meta == null) continue;
      for (final e in meta.entries) {
        db.execute(
          'INSERT INTO embedding_metadata (id, key, string_value) '
          'VALUES (?,?,?)',
          <Object?>[i + 1, e.key, '${e.value}'],
        );
      }
    }
    db.close();

    await _writeIndex(
      Directory(p.join(path, vectorSegment)),
      vectors: vectors,
      labels: labels,
      count: count,
    );
  }

  /// Creates and fills the FTS5 table Chroma indexes its documents with.
  ///
  /// Trigram-tokenised and keyed by the `embeddings` row id, exactly as Chroma
  /// writes it — the rowid is the join back to an embedding.
  void buildFullTextIndex() {
    final db = _db;
    db.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS embedding_fulltext_search '
      "USING fts5(string_value, tokenize='trigram')",
    );
    final rows = db.select(
      'SELECT id, string_value FROM embedding_metadata '
      "WHERE key = 'chroma:document'",
    );
    for (final row in rows) {
      db.execute(
        'INSERT INTO embedding_fulltext_search (rowid, string_value) '
        'VALUES (?,?)',
        <Object?>[row['id'], row['string_value']],
      );
    }
    db.close();
  }

  /// Writes an `index_metadata.pickle` holding a `label_to_id` map, in the
  /// protocol-3 opcodes CPython emits for a dict of int → string.
  void writeLabelMap({
    required String segment,
    required Map<int, String> labelToId,
  }) {
    final out = BytesBuilder()
      ..addByte(0x80) // PROTO
      ..addByte(3)
      ..addByte(0x7d) // EMPTY_DICT
      ..addByte(0x28); // MARK

    void str(String value) {
      final bytes = Uint8List.fromList(value.codeUnits);
      out.addByte(0x58); // BINUNICODE
      out.add((ByteData(4)..setUint32(0, bytes.length, Endian.little))
          .buffer
          .asUint8List());
      out.add(bytes);
    }

    str('label_to_id');
    out
      ..addByte(0x7d) // EMPTY_DICT
      ..addByte(0x28); // MARK
    for (final e in labelToId.entries) {
      out.addByte(0x4a); // BININT
      out.add((ByteData(4)..setInt32(0, e.key, Endian.little))
          .buffer
          .asUint8List());
      str(e.value);
    }
    out
      ..addByte(0x75) // SETITEMS, inner
      ..addByte(0x75) // SETITEMS, outer
      ..addByte(0x2e); // STOP

    File(p.join(path, segment, 'index_metadata.pickle'))
        .writeAsBytesSync(out.toBytes());
  }

  /// A collection row with no segments and no index.
  void addCollection({required String name, int? dimension}) {
    final db = _db;
    db.execute(
      'INSERT INTO collections (id, name, dimension) VALUES (?, ?, ?)',
      <Object?>['col-$name', name, dimension],
    );
    db.close();
  }

  /// Appends raw write-ahead log rows, in the order given.
  ///
  /// `operation` is Chroma's own encoding: add 0, update 1, upsert 2, delete 3.
  void addWalRows({
    required String collectionId,
    required List<({String id, int operation, List<double>? vector})> rows,
  }) {
    final db = _db;
    final start =
        (db.select('SELECT coalesce(max(seq_id), 0) AS m FROM embeddings_queue')
                    .first['m']
                as int) +
        1;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final vector = row.vector;
      db.execute(
        'INSERT INTO embeddings_queue '
        '(seq_id, operation, topic, id, vector, encoding, metadata) '
        'VALUES (?,?,?,?,?,?,?)',
        <Object?>[
          start + i,
          row.operation,
          'persistent://default/default/$collectionId',
          row.id,
          if (vector == null)
            null
          else
            Float32List.fromList(vector).buffer.asUint8List(),
          // Uppercase, as Chroma actually writes it.
          'FLOAT32',
          jsonEncode(<String, Object?>{'from': 'wal'}),
        ],
      );
    }
    db.close();
  }

  /// Adds a collection with no index on disk, only a write-ahead log — the
  /// state a store is in before Chroma has flushed a segment.
  void addWalOnly({
    required String name,
    required List<List<double>> vectors,
    required List<String> ids,
  }) {
    final collectionId = 'col-$name';
    final db = _db;
    db.execute(
      'INSERT INTO collections (id, name, dimension) VALUES (?, ?, ?)',
      <Object?>[collectionId, name, vectors.first.length],
    );
    db.execute(
      'INSERT INTO segments (id, type, scope, collection) VALUES (?,?,?,?)',
      <Object?>['seg-meta-$name', 'sqlite', 'METADATA', collectionId],
    );
    for (var i = 0; i < ids.length; i++) {
      final bytes = Float32List.fromList(
        vectors[i].map((v) => v).toList(),
      ).buffer.asUint8List();
      db.execute(
        'INSERT INTO embeddings_queue '
        '(seq_id, operation, topic, id, vector, encoding, metadata) '
        'VALUES (?,?,?,?,?,?,?)',
        <Object?>[
          i + 1,
          0,
          'persistent://default/default/$collectionId',
          ids[i],
          bytes,
          'float32',
          jsonEncode(<String, Object?>{'from': 'wal'}),
        ],
      );
    }
    db.close();
  }

  Future<void> dispose() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}

/// A `header.bin` in the layout a real Chroma index has: its hnswlib fork
/// writes a four-byte word before the twelve scalars, making the file 100 bytes
/// rather than upstream's 96.
Uint8List chromaHeader({
  required int count,
  required int maxElements,
  required int stride,
  required int labelOffset,
  required int dataOffset,
}) {
  const base = 4;
  final header = ByteData(base + 96);
  header.setInt32(0, 1, Endian.little);
  void put(int index, int value) =>
      header.setUint64(base + index * 8, value, Endian.little);

  put(0, 0); // offsetLevel0
  put(1, maxElements);
  put(2, count);
  put(3, stride);
  put(4, labelOffset);
  put(5, dataOffset);
  header.setInt32(base + 48, -1, Endian.little); // maxlevel
  header.setInt32(base + 52, -1, Endian.little); // enterpoint
  put(7, 16);
  put(8, 32);
  put(9, 16);
  header.setFloat64(base + 80, 0.36067376022224085, Endian.little);
  put(11, 100);
  return header.buffer.asUint8List();
}

/// Writes `header.bin` and `data_level0.bin` the way hnswlib's `saveIndex` does.
///
/// [count] overrides `cur_element_count`, for the reserved-but-empty state a
/// Chroma collection is in before its first flush.
Future<void> _writeIndex(
  Directory directory, {
  required List<List<double>> vectors,
  required List<int> labels,
  int linkBytes = 40,
  int? count,
}) async {
  await directory.create(recursive: true);
  final dimension = vectors.first.length;
  final dataOffset = linkBytes;
  final labelOffset = dataOffset + dimension * 4;
  final stride = labelOffset + 8;

  await File(p.join(directory.path, 'header.bin')).writeAsBytes(
    chromaHeader(
      count: count ?? vectors.length,
      maxElements: vectors.length,
      stride: stride,
      labelOffset: labelOffset,
      dataOffset: dataOffset,
    ),
  );

  final data = ByteData(stride * vectors.length);
  for (var i = 0; i < vectors.length; i++) {
    final base = i * stride;
    for (var j = 0; j < dimension; j++) {
      data.setFloat32(base + dataOffset + j * 4, vectors[i][j], Endian.little);
    }
    data.setUint64(base + labelOffset, labels[i], Endian.little);
  }
  await File(p.join(directory.path, 'data_level0.bin'))
      .writeAsBytes(data.buffer.asUint8List());
}

void main() {
  late _Persist persist;
  late ChromaFileBackend backend;

  setUp(() async {
    persist = await _Persist.create();
  });

  tearDown(() async {
    await backend.close();
    await persist.dispose();
  });

  Future<ChromaFileBackend> open() async {
    backend = ChromaFileBackend(directory: persist.path);
    await backend.connect();
    return backend;
  }

  group('a persisted collection', () {
    setUp(() async {
      await persist.addIndexed(
        name: 'documents',
        vectors: <List<double>>[
          <double>[1, 0, 0],
          <double>[0, 1, 0],
          <double>[0, 0, 1],
          <double>[1, 1, 0],
        ],
        // File order is not label order, so a test that passes has actually
        // resolved the mapping rather than got lucky with the index.
        labels: <int>[3, 1, 0, 2],
        ids: <String>['doc-a', 'doc-b', 'doc-c', 'doc-d'],
        metadata: <String, Map<String, Object?>>{
          'doc-a': <String, Object?>{'source': 'wiki'},
          'doc-c': <String, Object?>{'source': 'blog'},
        },
      );
    });

    test('lists what is in the directory', () async {
      final chroma = await open();
      final collections = await chroma.listCollections();
      expect(collections.map((c) => c.name), <String>['documents']);
      expect(collections.single.subtype, 'collection');
    });

    test('describes the space from the header, not from its contents',
        () async {
      final chroma = await open();
      final info = await chroma.describe('documents');

      // The width is derived from the hnsw layout and the size from the index
      // header — neither requires reading a single vector, which is what keeps
      // opening a large collection from being a half-gigabyte allocation.
      expect(info.dimension, 3);
      expect(info.count, 4);
      expect(info.metric, VectorMetric.cosine);
    });

    test('walks the collection a page at a time', () async {
      final chroma = await open();

      final first = await chroma.scroll('documents', limit: 2);
      expect(first.points, hasLength(2));
      expect(first.cursor, '2');

      final second = await chroma.scroll(
        'documents',
        limit: 2,
        cursor: first.cursor,
      );
      expect(second.points, hasLength(2));
      // A short page is the end of the walk, and there is no page after it.
      expect(second.cursor, isNull);

      final past = await chroma.scroll('documents', limit: 2, cursor: '4');
      expect(past.points, isEmpty);
    });

    test('resolves ids through the hnsw label, not the file position',
        () async {
      final chroma = await open();
      final page = await chroma.scroll('documents', limit: 4);

      // Element 0 carries label 3, so it is the fourth id inserted.
      expect(page.points[0].id, 'doc-d');
      expect(page.points[1].id, 'doc-b');
      expect(page.points[2].id, 'doc-a');
      expect(page.points[3].id, 'doc-c');

      // And the vectors stay with the elements they were read from.
      expect(page.points[0].vector, <double>[1, 0, 0]);
      expect(page.points[3].vector, <double>[1, 1, 0]);
    });

    test('attaches the metadata of the points on the page', () async {
      final chroma = await open();
      final page = await chroma.scroll('documents', limit: 4);
      final byId = <String, VectorPoint>{
        for (final point in page.points) point.id: point,
      };

      expect(byId['doc-a']!.payload['source'], 'wiki');
      expect(byId['doc-c']!.payload['source'], 'blog');
      // A point with no metadata gets an empty payload, not a missing one.
      expect(byId['doc-b']!.payload, isEmpty);
    });

    test('finds the true nearest neighbours, in order', () async {
      final chroma = await open();
      // The labels put the vectors on ids that are not their file order:
      // doc-d holds [1,0,0] and doc-c holds [1,1,0]. So from [1,0,0] the
      // cosine distances are doc-d 0, doc-c 1-1/√2 ≈ 0.29, and the two
      // orthogonal ones 1 — which is also a second check that scoring reads
      // the same mapping the listing does.
      final near = await chroma.nearest(
        'documents',
        <double>[1, 0, 0],
        topK: 2,
      );

      expect(near.map((p) => p.id), <String>['doc-d', 'doc-c']);
      expect(near.first.score, closeTo(0, 1e-6));
      expect(near.last.score, closeTo(1 - 1 / 1.4142135, 1e-5));
      // The winners carry their metadata too, so the panel has something to
      // show without a second read.
      expect(near.last.payload['source'], 'blog');
    });

    test('refuses a query vector of the wrong width', () async {
      final chroma = await open();
      await expectLater(
        chroma.nearest('documents', <double>[1, 0], topK: 2),
        throwsA(isA<Exception>()),
      );
    });

    test('names a collection that is not there', () async {
      final chroma = await open();
      await expectLater(
        chroma.describe('nope'),
        throwsA(
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('nope'),
          ),
        ),
      );
    });
  });

  group('a store whose segment was never flushed', () {
    setUp(() {
      persist.addWalOnly(
        name: 'pending',
        vectors: <List<double>>[
          <double>[1, 0],
          <double>[0, 1],
        ],
        ids: <String>['w-1', 'w-2'],
      );
    });

    test('falls back to the write-ahead log for the vectors', () async {
      final chroma = await open();
      final page = await chroma.scroll('pending', limit: 10);

      expect(page.points.map((p) => p.id), <String>['w-1', 'w-2']);
      expect(page.points.first.vector, <double>[1, 0]);
      // The log carries its own copy of the metadata, which is the only copy
      // there is when the metadata segment was never written.
      expect(page.points.first.payload['from'], 'wal');
    });

    test('still searches, without an index to search', () async {
      final chroma = await open();
      final near = await chroma.nearest('pending', <double>[0, 1], topK: 1);
      expect(near.single.id, 'w-2');
    });
  });

  group('a collection whose index was reserved but never written', () {
    // The state every one of a real store's small collections was in: Chroma
    // allocates `data_level0.bin` for `max_elements` up front, so the file is
    // full-size and full of zeroes while `cur_element_count` is still 0. The
    // vectors are in the write-ahead log until the first flush.
    setUp(() async {
      await persist.addIndexed(
        name: 'reserved',
        vectors: List<List<double>>.generate(
          8,
          (_) => List<double>.filled(4, 0),
        ),
        labels: List<int>.generate(8, (i) => i),
        ids: const <String>[],
        count: 0, // reserved, nothing flushed
      );
      persist.addWalRows(
        collectionId: 'col-reserved',
        rows: <({String id, int operation, List<double>? vector})>[
          (id: 'r-1', operation: 0, vector: <double>[1, 0, 0, 0]),
          (id: 'r-2', operation: 0, vector: <double>[0, 1, 0, 0]),
        ],
      );
    });

    test('reads the log rather than a screenful of zero vectors', () async {
      final chroma = await open();
      final page = await chroma.scroll('reserved', limit: 10);

      expect(page.points.map((p) => p.id), <String>['r-1', 'r-2']);
      expect(page.points.first.vector, <double>[1, 0, 0, 0]);
    });

    test('describes the space from the log when nothing else knows', () async {
      final chroma = await open();
      final info = await chroma.describe('reserved');
      expect(info.count, 2);
      expect(info.dimension, 4);
    });
  });

  group('a log with a history rather than a set', () {
    // A real store had 252 log rows for 12 vectors — an add followed by
    // twenty rounds of upserts. Reading the log as a set drew 252 marks.
    setUp(() {
      persist.addCollection(name: 'churned', dimension: 2);
      persist.addWalRows(
        collectionId: 'col-churned',
        rows: <({String id, int operation, List<double>? vector})>[
          (id: 'a', operation: 0, vector: <double>[1, 0]),
          (id: 'b', operation: 0, vector: <double>[0, 1]),
          (id: 'c', operation: 0, vector: <double>[1, 1]),
          // `a` upserted twice more, with the last write winning.
          (id: 'a', operation: 2, vector: <double>[2, 0]),
          (id: 'a', operation: 2, vector: <double>[3, 0]),
          // `c` deleted.
          (id: 'c', operation: 3, vector: null),
        ],
      );
    });

    test('replays the log instead of counting every write', () async {
      final chroma = await open();
      final page = await chroma.scroll('churned', limit: 50);

      // Three writes for `a`, one surviving point.
      expect(page.points.map((p) => p.id), <String>['a', 'b']);
      // The last write wins.
      expect(page.points.first.vector, <double>[3, 0]);
    });

    test('a deleted id does not come back', () async {
      final chroma = await open();
      final page = await chroma.scroll('churned', limit: 50);
      expect(page.points.map((p) => p.id), isNot(contains('c')));
    });

    test('the count reflects the replay, not the log length', () async {
      final chroma = await open();
      final info = await chroma.describe('churned');
      expect(info.count, 2);
    });
  });

  group('an index with the mapping Chroma writes beside it', () {
    // hnswlib never removes a deleted element, it marks it and leaves it in the
    // file. `label_to_id` is what says which are still real: a real store had
    // 9,566 elements for 8,616 mapped labels, and walking the file plotted
    // nearly a thousand vectors a Chroma server would never return.
    setUp(() async {
      await persist.addIndexed(
        name: 'pruned',
        vectors: <List<double>>[
          <double>[1, 0],
          <double>[0, 1],
          <double>[1, 1],
          <double>[2, 2],
        ],
        labels: <int>[0, 1, 2, 3],
        ids: const <String>[],
        space: 'l2',
      );
      // Labels 1 and 3 are absent: those two elements were deleted.
      persist.writeLabelMap(
        segment: 'seg-vec-pruned',
        labelToId: <int, String>{0: 'live-a', 2: 'live-c'},
      );
    });

    test('names points from the mapping rather than by position', () async {
      final chroma = await open();
      final page = await chroma.scroll('pruned', limit: 10);
      expect(page.points.map((p) => p.id), <String>['live-a', 'live-c']);
    });

    test('leaves deleted elements out of the walk', () async {
      final chroma = await open();
      final page = await chroma.scroll('pruned', limit: 10);
      // Four elements in the file, two of them still part of the collection.
      expect(page.points, hasLength(2));
      expect(page.points.map((p) => p.vector), <List<double>>[
        <double>[1, 0],
        <double>[1, 1],
      ]);
    });

    test('leaves deleted elements out of a search', () async {
      final chroma = await open();
      // [2,2] is the closest element in the file by euclidean distance, and it
      // is deleted — a search must not return it.
      final near = await chroma.nearest('pruned', <double>[2, 2], topK: 4);
      expect(near.map((p) => p.id), <String>['live-c', 'live-a']);
    });

    test('a page that skips everything still advances its cursor', () async {
      final chroma = await open();
      // Positions 1..2 hold one deleted element and one live one.
      final page = await chroma.scroll('pruned', limit: 1, cursor: '1');
      expect(page.points, isEmpty);
      // The cursor counts positions walked, so the walk continues rather than
      // stopping on a page that happened to be all deletions.
      expect(page.cursor, '2');
    });
  });

  group('full-text search', () {
    // Chroma builds an FTS5 index over its documents, trigram-tokenised, whose
    // rowid is the `embeddings` row id — so a match joins straight back to an
    // embedding. It is the one thing a file-mode store does better than a
    // server, and it is what finds a probe to search vectors from.
    setUp(() async {
      await persist.addIndexed(
        name: 'papers',
        vectors: <List<double>>[
          <double>[1, 0],
          <double>[0, 1],
          <double>[1, 1],
        ],
        labels: <int>[0, 1, 2],
        ids: <String>['p-invoice', 'p-recipe', 'p-invoice-2'],
        documents: <String, String>{
          'p-invoice': 'Invoice number 4471 for consulting',
          'p-recipe': 'A recipe for sourdough bread',
          'p-invoice-2': 'Second invoice, number 4472',
        },
      );
      persist.writeLabelMap(
        segment: 'seg-vec-papers',
        labelToId: <int, String>{
          0: 'p-invoice',
          1: 'p-recipe',
          2: 'p-invoice-2',
        },
      );
      persist.buildFullTextIndex();
    });

    test('finds documents anywhere in the collection', () async {
      final chroma = await open();
      final hits = await chroma.searchText('papers', 'invoice', limit: 10);

      expect(hits, isNotNull);
      expect(
        hits!.map((p) => p.id).toSet(),
        <String>{'p-invoice', 'p-invoice-2'},
      );
    });

    test('a hit carries its vector, so it can be searched from', () async {
      final chroma = await open();
      final hits = await chroma.searchText('papers', 'sourdough', limit: 10);

      expect(hits, hasLength(1));
      expect(hits!.single.id, 'p-recipe');
      // The whole point of finding it: the vector is what the neighbour search
      // needs, and a match without one would be a dead end.
      expect(hits.single.vector, <double>[0, 1]);
      expect(hits.single.payload[chromaDocumentKey], contains('sourdough'));
    });

    test('matches inside a word, not just at its start', () async {
      // Trigram tokenisation is what makes this substring search rather than
      // word search.
      final chroma = await open();
      final hits = await chroma.searchText('papers', 'ourdoug', limit: 10);
      expect(hits!.single.id, 'p-recipe');
    });

    test('a query under three characters still searches', () async {
      // The trigram index cannot match on two characters, so this falls
      // through to LIKE rather than silently returning nothing.
      final chroma = await open();
      final hits = await chroma.searchText('papers', '44', limit: 10);
      expect(hits!.map((p) => p.id).toSet(), <String>{
        'p-invoice',
        'p-invoice-2',
      });
    });

    test('a query matching nothing returns empty, not null', () async {
      // Empty is "searched, found nothing"; null would mean "did not search",
      // and the pane says something different for each.
      final chroma = await open();
      final hits = await chroma.searchText('papers', 'battleship', limit: 10);
      expect(hits, isNotNull);
      expect(hits, isEmpty);
    });

    test('FTS punctuation is searched for, not interpreted', () async {
      // Bare `AND`, `*`, `:` and `"` are all operators in FTS5's query
      // language. A search term is a search term, so the whole thing goes in
      // quoted and none of that grammar reaches the parser.
      final chroma = await open();
      for (final query in const <String>[
        'invoice OR recipe',
        'invoice*',
        'number:4471',
        'say "hello"',
      ]) {
        final hits = await chroma.searchText('papers', query, limit: 10);
        expect(hits, isNotNull, reason: '$query should not throw');
      }
    });

    test('an empty query is not a search for everything', () async {
      final chroma = await open();
      expect(await chroma.searchText('papers', '   ', limit: 10), isEmpty);
    });
  });

  test('a store with no full-text index still searches its documents', () async {
    // An older Chroma, or one whose FTS table was never populated: the LIKE
    // path is what keeps text search working rather than reporting nothing.
    await persist.addIndexed(
      name: 'plain',
      vectors: <List<double>>[
        <double>[1, 0],
        <double>[0, 1],
      ],
      labels: <int>[0, 1],
      ids: <String>['a', 'b'],
      documents: <String, String>{'a': 'alpha document', 'b': 'beta document'},
    );
    persist.writeLabelMap(
      segment: 'seg-vec-plain',
      labelToId: <int, String>{0: 'a', 1: 'b'},
    );
    // Deliberately no buildFullTextIndex().

    final chroma = await open();
    final hits = await chroma.searchText('plain', 'alpha', limit: 10);
    expect(hits!.single.id, 'a');
  });

  test('opens a huge collection without reading it', () async {
    // The regression this guards: `describe` used to materialise every vector
    // in the collection just to report how wide they were, so opening a large
    // store built two hundred thousand `List<double>`s before anything was
    // drawn. It was indistinguishable from a hang.
    //
    // The cost this catches is the per-point allocation, not the file read —
    // the index is made sparse, so reading its bytes is cheap and only
    // materialising them is not. Restoring the old `describe` against this
    // fixture takes about 4.4 seconds; the current one takes milliseconds.
    const dimension = 384;
    const count = 200000;
    const stride = 40 + dimension * 4 + 8;

    final segment = Directory(p.join(persist.path, 'seg-vec-huge'));
    await segment.create(recursive: true);

    final header = ByteData(100);
  header.setInt32(0, 1, Endian.little); // Chroma's fork writes this word first
    header.setUint64(0, 40, Endian.little);
    header.setUint64(8, count, Endian.little);
    header.setUint64(16, count, Endian.little);
    header.setUint64(24, stride, Endian.little);
    header.setUint64(32, 40 + dimension * 4, Endian.little);
    header.setUint64(40, 40, Endian.little);
    await File(p.join(segment.path, 'header.bin'))
        .writeAsBytes(header.buffer.asUint8List());

    // Sparse: seek to the end and write one byte. The file reports its full
    // length without a third of a gigabyte ever being written or read.
    final data = await File(p.join(segment.path, 'data_level0.bin')).open(
      mode: FileMode.write,
    );
    await data.setPosition(stride * count - 1);
    await data.writeByte(0);
    await data.close();

    final db = sqlite3.open(p.join(persist.path, 'chroma.sqlite3'));
    db.execute(
      'INSERT INTO collections (id, name, dimension) VALUES (?,?,?)',
      <Object?>['col-huge', 'huge', dimension],
    );
    db.execute(
      'INSERT INTO segments (id, type, scope, collection) VALUES (?,?,?,?)',
      <Object?>['seg-vec-huge', 'hnsw', 'VECTOR', 'col-huge'],
    );
    db.close();

    final chroma = await open();
    final sw = Stopwatch()..start();
    final info = await chroma.describe('huge');
    final page = await chroma.scroll('huge', limit: 10);
    sw.stop();

    expect(info.dimension, dimension);
    expect(info.count, count);
    expect(page.points, hasLength(10));
    expect(page.points.first.vector, hasLength(dimension));
    // A generous bound, not a benchmark: reading the whole index would be
    // hundreds of megabytes and hundreds of megabytes of allocation, which is
    // nowhere near this even on a slow machine.
    expect(
      sw.elapsedMilliseconds,
      lessThan(2000),
      reason: 'describe and a ten-point page must not read the whole index',
    );
  });

  test('refuses a directory that is not a Chroma store', () async {
    final empty = await Directory.systemTemp.createTemp('not-chroma');
    addTearDown(() => empty.delete(recursive: true));

    backend = ChromaFileBackend(directory: empty.path);
    await expectLater(
      backend.connect(),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          contains('chroma.sqlite3'),
        ),
      ),
    );
  });
}
