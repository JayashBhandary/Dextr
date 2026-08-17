import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../../core/errors.dart';
import '../../../core/logger.dart';
import '../../data_source.dart';
import '../chroma_index_metadata.dart';
import '../hnsw_index_file.dart';
import '../vector_backend.dart';
import '../vector_types.dart';

/// A Chroma persist directory, opened with no server running.
///
/// Chroma splits a persisted collection across two stores: `chroma.sqlite3`
/// holds the catalogue, the ids and the metadata, and a uuid-named
/// subdirectory holds the vectors as an hnswlib index. Both have to be read and
/// joined, because neither has everything.
///
/// The join is the awkward part. hnswlib knows its elements by an integer
/// label; the mapping from those labels back to Chroma's string ids lives in
/// `index_metadata.pickle`. That is read where it exists — see
/// [ChromaIndexMetadata] — and where it does not, the ids are lined up with the
/// labels by insertion order, which is the order Chroma assigns them in.
/// Deletions break that correspondence, so the counts are checked first and ids
/// are dropped — not guessed at — when they disagree.
///
/// Read-only throughout. Nothing here writes to a store that a running Chroma
/// may also have open.
class ChromaFileBackend implements VectorBackend {
  ChromaFileBackend({required this.directory});

  /// The persist directory — the one holding `chroma.sqlite3`, not the
  /// collection subdirectory inside it.
  final String directory;

  Database? _db;

  final Map<String, _ChromaCollection> _collections =
      <String, _ChromaCollection>{};

  /// The open hnsw index per collection, kept because opening one is a file
  /// open and a header parse and the pane pages through the same collection
  /// repeatedly. The *elements* are not cached: they are read from the file as
  /// asked for, which is what keeps a large collection from being a half-gigabyte
  /// allocation before anything is drawn.
  final Map<String, HnswIndexFile?> _indexes = <String, HnswIndexFile?>{};

  /// Ids in insertion order, per collection. One string per point rather than
  /// one vector per point, so this stays affordable where caching the vectors
  /// would not.
  final Map<String, List<_ChromaRecord>> _records =
      <String, List<_ChromaRecord>>{};

  /// Replayed write-ahead log per collection, for stores with no index.
  ///
  /// Cached where index elements are not, because the log has to be replayed
  /// from the beginning to know the current state of even one point — there is
  /// no seeking to the tenth surviving id.
  final Map<String, List<VectorPoint>> _walPoints =
      <String, List<VectorPoint>>{};

  /// hnsw label → Chroma id, per collection, read from the pickle beside each
  /// index. Absent when a store has no mapping to read, which is what the
  /// positional fallback in [_idForLabel] is for.
  final Map<String, ChromaIndexMetadata> _labels =
      <String, ChromaIndexMetadata>{};

  /// Chroma's `Operation` enum, as stored: add 0, update 1, upsert 2, delete 3.
  static const int _walDelete = 3;

  Database get _open {
    final db = _db;
    if (db == null) throw const ConnectError('Chroma file: not connected');
    return db;
  }

  @override
  Future<void> connect() async {
    final dbPath = '$directory/chroma.sqlite3';
    if (!File(dbPath).existsSync()) {
      throw ConnectError(
        'No chroma.sqlite3 in $directory — pick the persist directory itself, '
        'not a collection inside it',
      );
    }
    try {
      // Read-write without create, falling back to read-only. A database with a
      // live WAL beside it cannot always be opened read-only, because that
      // still needs to write the shared-memory index; on a directory that is
      // genuinely read-only the second attempt is the one that works.
      try {
        _db = sqlite3.open(dbPath, mode: OpenMode.readWrite);
      } catch (_) {
        _db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      }
      _open.select('SELECT 1');
    } catch (e, st) {
      _db = null;
      throw ConnectError('Could not open $dbPath', cause: e, stack: st);
    }
    await _loadCollections();
  }

  @override
  Future<void> close() async {
    for (final index in _indexes.values) {
      await index?.close();
    }
    _indexes.clear();
    _walPoints.clear();
    _labels.clear();
    _records.clear();
    _collections.clear();
    _db?.close();
    _db = null;
  }

  @override
  Future<void> ping() async {
    _open.select('SELECT count(*) FROM collections');
  }

  Future<void> _loadCollections() async {
    _collections.clear();
    // `dimension` arrived in Chroma 0.4 and `config_json_str` later still, so
    // the narrow query is the one that always works and the wide one is tried
    // first for what it adds.
    ResultSet rows;
    var hasDimension = true;
    try {
      rows = _open.select('SELECT id, name, dimension FROM collections');
    } catch (_) {
      hasDimension = false;
      rows = _open.select('SELECT id, name FROM collections');
    }

    for (final row in rows) {
      final id = row['id']?.toString();
      final name = row['name']?.toString();
      if (id == null || name == null) continue;
      _collections[name] = _ChromaCollection(
        id: id,
        name: name,
        dimension: hasDimension ? (row['dimension'] as int?) : null,
        metric: _metricOf(id),
        vectorSegmentId: _segmentId(id, 'VECTOR'),
        metadataSegmentId: _segmentId(id, 'METADATA'),
      );
    }
  }

  /// The distance function, which Chroma records as a collection metadata entry
  /// rather than as a column.
  VectorMetric _metricOf(String collectionId) {
    try {
      final rows = _open.select(
        'SELECT str_value FROM collection_metadata '
        "WHERE collection_id = ? AND key = 'hnsw:space'",
        <Object?>[collectionId],
      );
      if (rows.isNotEmpty) {
        final metric = VectorMetric.parse(rows.first['str_value']);
        if (metric != VectorMetric.unknown) return metric;
      }
    } catch (_) {
      // An older schema without the table. The default below still holds.
    }
    // Chroma's default when a collection does not say.
    return VectorMetric.euclidean;
  }

  String? _segmentId(String collectionId, String scope) {
    try {
      final rows = _open.select(
        'SELECT id FROM segments WHERE collection = ? AND scope = ?',
        <Object?>[collectionId, scope],
      );
      return rows.isEmpty ? null : rows.first['id']?.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<ContainerRef>> listCollections() async {
    if (_collections.isEmpty) await _loadCollections();
    return <ContainerRef>[
      for (final c in _collections.values)
        ContainerRef(name: c.name, subtype: 'collection'),
    ];
  }

  _ChromaCollection _collection(String name) {
    final c = _collections[name];
    if (c == null) {
      throw QueryError('Chroma file: no collection named "$name" in $directory');
    }
    return c;
  }

  /// Describes the space without reading it.
  ///
  /// The width comes from the hnsw header — a hundred bytes — and the size from
  /// a `count(*)`, so opening a collection of half a million vectors costs the
  /// same as opening one holding ten. This used to load every vector in the
  /// collection just to ask how wide they were, which on a large store was
  /// indistinguishable from the app hanging.
  @override
  Future<VectorSpaceInfo> describe(String collection) async {
    final c = _collection(collection);
    final index = await _index(collection);

    var dimension = index?.dimension ?? c.dimension;
    // SQLite first: its row count is what a Chroma server reports for the
    // collection. The index's element count includes deleted elements — 9,566
    // against 8,965 live rows on a real store — and reporting that would say
    // the collection is bigger than it is.
    var count = _countFromSqlite(c) ?? index?.count;

    // No index and nothing declared: the log is the only thing that knows. Only
    // reached when the two cheap answers have both come back empty, and its
    // result is cached for the read that follows.
    if (index == null && (dimension == null || count == null || count == 0)) {
      final points = _pointsFromWal(c);
      if (points.isNotEmpty) {
        dimension ??= points.first.vector.length;
        count = points.length;
      }
    }

    return VectorSpaceInfo(
      name: collection,
      dimension: dimension,
      count: count,
      metric: c.metric,
    );
  }

  @override
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  }) async {
    final offset = int.tryParse(cursor ?? '') ?? 0;
    final index = await _index(collection);

    // No index on disk: the write-ahead log is the only place the vectors are,
    // and it is read through SQLite rather than seeked into.
    if (index == null) {
      final all = _pointsFromWal(_collection(collection));
      if (offset >= all.length) {
        return const VectorPage(points: <VectorPoint>[]);
      }
      final end = math.min(offset + limit, all.length);
      return VectorPage(
        points: all.sublist(offset, end),
        cursor: end >= all.length ? null : '$end',
      );
    }

    if (offset >= index.count) {
      return const VectorPage(points: <VectorPoint>[]);
    }
    final end = math.min(offset + limit, index.count);
    final c = _collection(collection);
    final records = _recordsFor(c);
    final points = <VectorPoint>[
      for (var i = offset; i < end; i++)
        if (_pointAt(c, index, records, i) case final VectorPoint point) point,
    ];
    _attachMetadata(c, points);
    // The cursor counts positions walked, not points returned: elements that
    // were skipped as deleted still have to be walked past to reach the next
    // live one, and a cursor that counted results would read them again.
    return VectorPage(
      points: points,
      cursor: end >= index.count ? null : '$end',
    );
  }

  /// Exact rather than approximate, and deliberately so: scanning the file is
  /// simpler than walking the hnsw graph and gives the true neighbours rather
  /// than the ones the graph happens to reach.
  ///
  /// This is the one operation here that does read the whole collection. It is
  /// a deliberate action on a local file rather than something that happens on
  /// the way to a first paint, which is why it is allowed to cost what it costs.
  @override
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  }) async {
    final c = _collection(collection);
    final index = await _index(collection);

    if (index == null) {
      final all = _pointsFromWal(c);
      return _topK(all, query, c.metric, topK);
    }

    if (query.length != index.dimension) {
      throw QueryError(
        'Chroma file: the query vector has ${query.length} components but '
        '$collection is ${index.dimension}-dimensional',
      );
    }

    // Scored as they are read, keeping only the leaders: holding every point of
    // a large collection in memory to sort it is the thing this class exists to
    // avoid.
    final records = _recordsFor(c);
    final best = <VectorPoint>[];
    for (var i = 0; i < index.count; i++) {
      final (label, vector) = index.entryAt(i);
      final score = _distance(query, vector, c.metric);
      if (best.length == topK && score >= best.last.score!) continue;
      final id = _idForLabel(c, records, label, index.count);
      // Same as the walk: a label the mapping does not know is a deleted
      // element, and a deleted vector must not come back as somebody's nearest
      // neighbour.
      if (id == null && _labels.containsKey(c.name)) continue;
      final point = VectorPoint(
        id: id ?? '#$label',
        vector: vector,
        payload: id == null
            ? <String, Object?>{'chroma:label': label}
            : <String, Object?>{},
        score: score,
      );
      final at = best.indexWhere((p) => p.score! > score);
      best.insert(at < 0 ? best.length : at, point);
      if (best.length > topK) best.removeLast();
    }
    _attachMetadata(c, best);
    return best;
  }

  /// Full-text search across the whole collection, through the FTS5 index
  /// Chroma builds over its documents.
  ///
  /// This is the one place a file-mode store beats a server: `chroma.sqlite3`
  /// carries `embedding_fulltext_search`, a trigram-tokenised FTS5 table whose
  /// rowid is the `embeddings` row id, so a match joins straight back to an
  /// embedding without a scan.
  ///
  /// Trigram tokenisation is what makes this substring search rather than word
  /// search — but it also means a query shorter than three characters matches
  /// nothing at all, so those fall back to `LIKE`.
  @override
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  }) async {
    final c = _collection(collection);
    final segmentId = c.metadataSegmentId;
    final trimmed = query.trim();
    if (segmentId == null || trimmed.isEmpty) return const <VectorPoint>[];

    final ids = _matchingIds(segmentId, trimmed, limit);
    if (ids.isEmpty) return const <VectorPoint>[];

    final index = await _index(collection);
    final points = <VectorPoint>[];

    if (index == null) {
      // No index: the vectors are in the log, which is already replayed and
      // keyed by id.
      final byId = <String, VectorPoint>{
        for (final p in _pointsFromWal(c)) p.id: p,
      };
      for (final id in ids) {
        final point = byId[id];
        if (point != null) points.add(point);
      }
    } else {
      final labels = _labels[collection];
      for (final id in ids) {
        // id → label → position → vector. Without the mapping there is no way
        // from an id back to an element, so a matched document simply cannot
        // be located in the index.
        final label = labels?.idToLabel[id];
        if (label == null) continue;
        final position = index.positionOfLabel(label);
        if (position == null) continue;
        final (_, vector) = index.entryAt(position);
        points.add(VectorPoint(id: id, vector: vector));
      }
    }

    _attachMetadata(c, points);
    return points;
  }

  /// Embedding ids whose document matches, newest FTS first.
  List<String> _matchingIds(String segmentId, String query, int limit) {
    // FTS5 parses its argument as a query language — bare `AND`, `*`, `:` and
    // `"` all mean something. Wrapping the whole thing in quotes, with internal
    // quotes doubled, makes it one literal phrase and takes that grammar out of
    // the user's hands.
    final phrase = '"${query.replaceAll('"', '""')}"';
    if (query.length >= 3) {
      try {
        final rows = _open.select(
          'SELECT e.embedding_id AS id FROM embedding_fulltext_search f '
          'JOIN embeddings e ON e.id = f.rowid '
          'WHERE f.string_value MATCH ? AND e.segment_id = ? LIMIT ?',
          <Object?>[phrase, segmentId, limit],
        );
        return <String>[
          for (final row in rows)
            if (row['id'] != null) row['id'].toString(),
        ];
      } catch (e) {
        log.w('Chroma file: FTS query failed, falling back to LIKE: $e');
      }
    }

    // Under three characters the trigram index has nothing to match on, and a
    // store old enough to have no FTS table at all lands here too.
    try {
      final rows = _open.select(
        'SELECT e.embedding_id AS id FROM embedding_metadata m '
        'JOIN embeddings e ON e.id = m.id '
        "WHERE m.key = 'chroma:document' "
        "AND m.string_value LIKE ? ESCAPE '\\' "
        'AND e.segment_id = ? LIMIT ?',
        <Object?>['%${_escapeLike(query)}%', segmentId, limit],
      );
      return <String>[
        for (final row in rows)
          if (row['id'] != null) row['id'].toString(),
      ];
    } catch (e) {
      log.w('Chroma file: text search unavailable: $e');
      return const <String>[];
    }
  }

  /// `%` and `_` are wildcards in `LIKE`, and a document full of underscores
  /// would otherwise match nearly everything.
  String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// The [topK] closest of an already-materialised list, for the log path.
  List<VectorPoint> _topK(
    List<VectorPoint> points,
    List<double> query,
    VectorMetric metric,
    int topK,
  ) {
    if (points.isEmpty) return const [];
    if (query.length != points.first.vector.length) {
      throw QueryError(
        'Chroma file: the query vector has ${query.length} components but '
        'this collection is ${points.first.vector.length}-dimensional',
      );
    }
    final scored = <VectorPoint>[
      for (final p in points)
        VectorPoint(
          id: p.id,
          vector: p.vector,
          payload: p.payload,
          score: _distance(query, p.vector, metric),
        ),
    ];
    // Every metric computed here is a distance — smaller is closer — including
    // cosine, which is returned as `1 - similarity` to match what a Chroma
    // server reports for the same collection.
    scored.sort((a, b) => a.score!.compareTo(b.score!));
    return scored.take(topK).toList();
  }

  double _distance(List<double> a, List<double> b, VectorMetric metric) {
    switch (metric) {
      case VectorMetric.cosine:
        var dot = 0.0;
        var na = 0.0;
        var nb = 0.0;
        for (var i = 0; i < a.length; i++) {
          dot += a[i] * b[i];
          na += a[i] * a[i];
          nb += b[i] * b[i];
        }
        if (na == 0 || nb == 0) return 1;
        return 1 - dot / (math.sqrt(na) * math.sqrt(nb));
      case VectorMetric.dot:
        var dot = 0.0;
        for (var i = 0; i < a.length; i++) {
          dot += a[i] * b[i];
        }
        // Negated so that, like the others, smaller sorts closer.
        return -dot;
      case VectorMetric.manhattan:
        var sum = 0.0;
        for (var i = 0; i < a.length; i++) {
          sum += (a[i] - b[i]).abs();
        }
        return sum;
      case VectorMetric.euclidean:
      case VectorMetric.unknown:
        var sum = 0.0;
        for (var i = 0; i < a.length; i++) {
          final d = a[i] - b[i];
          sum += d * d;
        }
        return math.sqrt(sum);
    }
  }

  /// The open index for a collection, or null when there is none on disk.
  ///
  /// Opening reads the 96-byte header and nothing else; the handle is kept so
  /// paging through a collection does not reopen the file per page.
  Future<HnswIndexFile?> _index(String collection) async {
    if (_indexes.containsKey(collection)) return _indexes[collection];
    final segmentId = _collection(collection).vectorSegmentId;
    final index = segmentId == null
        ? null
        : await HnswIndexFile.open('$directory/$segmentId');
    _indexes[collection] = index;

    // Loaded with the index and only when there is one: it is the mapping from
    // that index's labels, and it is a few megabytes for a large collection, so
    // it is not worth reading for a store that turns out to have no index.
    if (index != null && segmentId != null) {
      final labels = await ChromaIndexMetadata.open('$directory/$segmentId');
      if (labels != null && !labels.isEmpty) {
        _labels[collection] = labels;
        log.i(
          'Chroma file: $collection mapped ${labels.labelToId.length} of '
          '${index.count} labels to ids',
        );
      }
    }
    return index;
  }

  int? _countFromSqlite(_ChromaCollection c) {
    final segmentId = c.metadataSegmentId;
    if (segmentId == null) return null;
    try {
      final rows = _open.select(
        'SELECT count(*) AS n FROM embeddings WHERE segment_id = ?',
        <Object?>[segmentId],
      );
      return rows.isEmpty ? null : rows.first['n'] as int?;
    } catch (_) {
      return null;
    }
  }

  /// One point out of the index, without its metadata — which is attached in
  /// bulk afterwards, because a query per point is a query per point.
  /// One point out of the index, or null where the element is not part of the
  /// collection any more.
  ///
  /// hnswlib does not remove a deleted element, it marks it and leaves it in
  /// the file — so a real store had 9,566 elements for 8,616 live ones, and
  /// walking the file plotted nearly a thousand vectors a Chroma server would
  /// never return. Where the label mapping is known, an unmapped label *is* the
  /// deletion marker and the element is skipped. Where it is not known, nothing
  /// can be told apart and every element is kept, labelled rather than named.
  VectorPoint? _pointAt(
    _ChromaCollection c,
    HnswIndexFile index,
    List<_ChromaRecord> records,
    int i,
  ) {
    final (label, vector) = index.entryAt(i);
    final id = _idForLabel(c, records, label, index.count);
    if (id == null && _labels.containsKey(c.name)) return null;
    return VectorPoint(
      id: id ?? '#$label',
      vector: vector,
      payload: id == null
          ? <String, Object?>{'chroma:label': label}
          : <String, Object?>{},
    );
  }

  /// The id of one hnsw label, by the best route available.
  ///
  /// First choice is the mapping Chroma writes beside the index, which is
  /// authoritative and survives deletions. Failing that: hnswlib hands out
  /// labels 0, 1, 2 … in insertion order and SQLite's rowid ordering is that
  /// same order, so the two line up — but only while nothing has been deleted,
  /// which is exactly what a count mismatch reveals. Failing that too, the
  /// label itself, because a wrong id attached to a point is worse than an
  /// honest one nobody recognises.
  String? _idForLabel(
    _ChromaCollection c,
    List<_ChromaRecord> records,
    int label,
    int indexCount,
  ) {
    final mapped = _labels[c.name]?.labelToId[label];
    if (mapped != null) return mapped;
    if (records.length != indexCount) return null;
    return label < records.length ? records[label].id : null;
  }

  /// The fallback for a store whose vector segment was never flushed: Chroma's
  /// write-ahead log still holds the raw embeddings.
  ///
  /// Only useful on a store that has not been vacuumed — `chroma vacuum` purges
  /// the log, and recent versions purge it as they go — which is why this is
  /// second choice rather than first.
  List<VectorPoint> _pointsFromWal(_ChromaCollection c) {
    final cached = _walPoints[c.name];
    if (cached != null) return cached;

    final columns = _columnsOf('embeddings_queue');
    if (columns.isEmpty) return const [];

    // The column naming the collection has changed across versions: early
    // builds wrote a pulsar-style `topic` string with the segment id in it,
    // later ones a plain `collection_id`.
    final String where;
    final List<Object?> params;
    if (columns.contains('collection_id')) {
      where = 'WHERE collection_id = ?';
      params = <Object?>[c.id];
    } else if (columns.contains('topic')) {
      where = 'WHERE topic LIKE ? OR topic LIKE ?';
      params = <Object?>['%${c.id}%', '%${c.vectorSegmentId ?? c.id}%'];
    } else {
      where = '';
      params = const <Object?>[];
    }

    final ResultSet rows;
    try {
      rows = _open.select(
        'SELECT id, operation, vector, encoding, metadata FROM embeddings_queue '
        '$where ORDER BY seq_id',
        params,
      );
    } catch (e, st) {
      throw QueryError(
        'Chroma file: ${c.name} has no hnsw index on disk and its write-ahead '
        'log could not be read either',
        cause: e,
        stack: st,
      );
    }

    // A log is a history, not a set. One id may appear many times — an add
    // followed by upserts — and replaying it means taking the last write for
    // each id rather than every row. Reading it as a set plotted one mark per
    // *write*, so a collection of twelve vectors that had been re-indexed
    // twenty times drew two hundred and fifty marks.
    //
    // A `Map` keeps a key in the position it was first inserted at when it is
    // reassigned, so replaying in `seq_id` order and overwriting leaves the
    // surviving points in a stable order.
    final replayed = <String, VectorPoint>{};
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null) continue;

      if (row['operation'] == _walDelete) {
        replayed.remove(id);
        continue;
      }

      final blob = row['vector'];
      if (blob is! Uint8List) continue;
      final encoding = row['encoding']?.toString() ?? 'float32';
      final vector = _decodeBlob(blob, encoding);
      if (vector == null) continue;

      // The log carries its own JSON copy of the metadata, which is the only
      // copy available when the metadata segment was pruned and the log was
      // not — and this path only runs when there is no index, which is that
      // same situation.
      replayed[id] = VectorPoint(
        id: id,
        vector: vector,
        payload: _decodeWalMetadata(row['metadata']),
      );
    }

    return _walPoints[c.name] = List<VectorPoint>.unmodifiable(
      replayed.values,
    );
  }

  /// Chroma stores a WAL vector as a packed little-endian float array, tagged
  /// with its width in the `encoding` column.
  List<double>? _decodeBlob(Uint8List blob, String encoding) {
    final width = encoding.contains('64') ? 8 : 4;
    if (blob.lengthInBytes < width || blob.lengthInBytes % width != 0) {
      return null;
    }
    final view = ByteData.sublistView(blob);
    final n = blob.lengthInBytes ~/ width;
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      out[i] = width == 8
          ? view.getFloat64(i * 8, Endian.little)
          : view.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  Set<String> _columnsOf(String table) {
    try {
      final rows = _open.select('PRAGMA table_info($table)');
      return <String>{
        for (final row in rows)
          if (row['name'] != null) row['name'].toString(),
      };
    } catch (_) {
      return const <String>{};
    }
  }

  /// The ids of one collection in insertion order, without their metadata.
  ///
  /// Cached, and affordable to cache: one string and one row id per point,
  /// against the several kilobytes a vector costs. The metadata is deliberately
  /// left off — joining the whole `embedding_metadata` table for a collection is
  /// the expensive half, and only the handful of points on screen need it.
  List<_ChromaRecord> _recordsFor(_ChromaCollection c) {
    final cached = _records[c.name];
    if (cached != null) return cached;

    final segmentId = c.metadataSegmentId;
    if (segmentId == null) return _records[c.name] = const <_ChromaRecord>[];

    final ResultSet rows;
    try {
      rows = _open.select(
        'SELECT id, embedding_id FROM embeddings WHERE segment_id = ? '
        'ORDER BY id',
        <Object?>[segmentId],
      );
    } catch (_) {
      return _records[c.name] = const <_ChromaRecord>[];
    }

    final records = <_ChromaRecord>[];
    for (final row in rows) {
      final rowId = row['id'];
      final embeddingId = row['embedding_id']?.toString();
      if (rowId is! int || embeddingId == null) continue;
      records.add(_ChromaRecord(id: embeddingId, rowId: rowId));
    }
    return _records[c.name] = records;
  }

  /// Fills in the metadata for exactly the points given, in one query.
  ///
  /// A query per point is a query per point; a query for the whole collection
  /// reads a table to display a page. This reads the rows for the page.
  void _attachMetadata(_ChromaCollection c, List<VectorPoint> points) {
    if (points.isEmpty) return;
    final records = _recordsFor(c);
    if (records.isEmpty) return;

    final rowIdById = <String, int>{for (final r in records) r.id: r.rowId};
    final wanted = <int>[
      for (final p in points)
        if (rowIdById[p.id] case final int rowId) rowId,
    ];
    if (wanted.isEmpty) return;

    final placeholders = List<String>.filled(wanted.length, '?').join(',');
    final ResultSet meta;
    try {
      meta = _open.select(
        'SELECT id, key, string_value, int_value, float_value, bool_value '
        'FROM embedding_metadata WHERE id IN ($placeholders)',
        wanted,
      );
    } catch (_) {
      // A schema without the metadata table. The ids alone are still useful.
      return;
    }

    final byRowId = <int, Map<String, Object?>>{};
    for (final row in meta) {
      final rowId = row['id'];
      final key = row['key']?.toString();
      if (rowId is! int || key == null) continue;
      byRowId.putIfAbsent(rowId, () => <String, Object?>{})[key] =
          row['string_value'] ??
          row['int_value'] ??
          row['float_value'] ??
          (row['bool_value'] == null ? null : row['bool_value'] != 0);
    }

    for (var i = 0; i < points.length; i++) {
      final rowId = rowIdById[points[i].id];
      final metadata = rowId == null ? null : byRowId[rowId];
      if (metadata == null || metadata.isEmpty) continue;
      points[i] = VectorPoint(
        id: points[i].id,
        vector: points[i].vector,
        payload: <String, Object?>{...points[i].payload, ...metadata},
        score: points[i].score,
      );
    }
  }
}

class _ChromaCollection {
  const _ChromaCollection({
    required this.id,
    required this.name,
    required this.metric,
    this.dimension,
    this.vectorSegmentId,
    this.metadataSegmentId,
  });

  final String id;
  final String name;
  final int? dimension;
  final VectorMetric metric;

  /// The uuid naming the subdirectory the hnsw files live in.
  final String? vectorSegmentId;
  final String? metadataSegmentId;
}

class _ChromaRecord {
  const _ChromaRecord({required this.id, required this.rowId});

  /// Chroma's own string id for the embedding.
  final String id;

  /// The `embeddings` rowid, which is what `embedding_metadata` is keyed by.
  final int rowId;
}

/// The write-ahead log stores metadata as a JSON string rather than in the
/// metadata table, so it needs decoding rather than reading column by column.
Map<String, Object?> _decodeWalMetadata(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? parsePayload(decoded) : const {};
  } catch (_) {
    // A log row whose metadata will not parse is still a usable vector.
    return const {};
  }
}
