import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../../services/file_access.dart';
import '../data_source.dart';
import 'backends/chroma_backend.dart';
import 'backends/chroma_file_backend.dart';
import 'backends/pinecone_backend.dart';
import 'backends/qdrant_backend.dart';
import 'backends/weaviate_backend.dart';
import 'vector_backend.dart';
import 'vector_types.dart';

/// One connection to a vector database, whichever engine is behind it.
///
/// The engine is a [VectorBackend] chosen at connect from the record's
/// `provider` and `mode`, so everything above this class — the rail, the tabs,
/// the browse grid, the vector pane — sees one kind of connection rather than
/// four. Adding a fifth engine is a backend and an enum entry; nothing else in
/// the app has to learn its name.
///
/// Read-only. [Writable] is deliberately not mixed in: an accidental upsert
/// into a production index is not a mistake worth making reachable from a grid.
class VectorDataSource extends DataSource with VectorSearchable, SchemaReadable {
  VectorDataSource({
    required this.record,
    required this.secrets,
    FileAccess? fileAccess,
  }) : fileAccess = fileAccess ?? FileAccess.instance;

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;
  final FileAccess fileAccess;

  VectorBackend? _backend;

  /// Held for as long as a sandboxed persist directory is open, and the
  /// argument to the revoke that has to follow.
  String? _accessToken;

  final Map<String, Object?> _corrected = <String, Object?>{};

  /// How many payload keys a schema is built from, and how many points are read
  /// to find them. A vector collection has no declared schema, so the columns
  /// are whatever the first page happens to carry.
  static const _schemaSampleSize = 50;

  /// The most points one call to [sampleVectors] will hold. A projection is
  /// O(points × dimension) per iteration and a scatter plot stops saying
  /// anything past a few thousand marks, so the cap is a readability limit
  /// before it is a performance one.
  static const maxSample = 5000;

  @override
  Map<String, Object?> get correctedConfig => Map.unmodifiable(_corrected);

  @override
  String get id => record.id;

  @override
  String get displayName => record.name;

  @override
  DataSourceKind get kind => DataSourceKind.vector;

  @override
  Set<Capability> get capabilities => const <Capability>{
    Capability.schemaRead,
    Capability.vectorSearch,
  };

  VectorProvider get provider =>
      VectorProvider.fromName(record.config['provider']);

  VectorMode get mode => VectorMode.fromName(record.config['mode']);

  VectorBackend get _open {
    final b = _backend;
    if (b == null) throw const ConnectError('Not connected');
    return b;
  }

  String get _url {
    final raw = record.config['url'];
    final url = raw is String ? raw.trim() : '';
    if (url.isEmpty) {
      throw ConnectError('${provider.label}: no URL saved for this connection');
    }
    return url;
  }

  String? get _apiKey {
    final key = secrets?.apiKey;
    return (key == null || key.isEmpty) ? null : key;
  }

  String _configString(String key, [String fallback = '']) {
    final raw = record.config[key];
    return raw is String ? raw : fallback;
  }

  @override
  Future<void> connect() async {
    final backend = mode == VectorMode.file
        ? await _fileBackend()
        : _serverBackend();
    try {
      await backend.connect();
    } catch (e) {
      await _releaseFile();
      rethrow;
    }
    _backend = backend;
  }

  VectorBackend _serverBackend() => switch (provider) {
    VectorProvider.qdrant => QdrantBackend(baseUrl: _url, apiKey: _apiKey),
    VectorProvider.chroma => ChromaBackend(
      baseUrl: _url,
      apiKey: _apiKey,
      tenant: _configString('tenant'),
      database: _configString('database'),
    ),
    VectorProvider.pinecone => PineconeBackend(
      apiKey: _apiKey ?? '',
      controlPlaneUrl: _url,
      namespace: _configString('namespace'),
    ),
    VectorProvider.weaviate => WeaviateBackend(baseUrl: _url, apiKey: _apiKey),
  };

  /// The on-disk store, for the one engine that has a format this can read.
  ///
  /// The others reach here only if a record was hand-edited: the form does not
  /// offer file mode for them, because their stores are RocksDB and LSM trees
  /// that cannot be read without the engine itself.
  Future<VectorBackend> _fileBackend() async {
    if (provider != VectorProvider.chroma) {
      throw ConnectError(
        '${provider.label} has no on-disk format Dextr can read directly — '
        'point this connection at a running server instead',
      );
    }
    return ChromaFileBackend(directory: await _acquireDirectory());
  }

  /// Resolves the persist directory, redeeming a sandbox bookmark first where
  /// the platform needs one. Mirrors what the SQLite connector does with a
  /// picked file, for the same reason: a path saved on a previous launch is
  /// just a string until the bookmark beside it is redeemed.
  Future<String> _acquireDirectory() async {
    final configured = _configString(FileAccess.pathKey);
    if (configured.isEmpty) {
      throw const ConnectError('No persist directory saved for this connection');
    }
    final bookmark = _configString(FileAccess.bookmarkKey);
    if (bookmark.isEmpty || !fileAccess.isSupported) return configured;

    final grant = await fileAccess.grant(bookmark);
    if (grant == null) {
      log.w('${record.name}: bookmark for $configured did not resolve');
      return configured;
    }
    _accessToken = grant.token;
    // The bookmark, not the path, is the authority on where the directory
    // lives: a moved one resolves to its new home and the saved path is then
    // simply wrong.
    if (grant.path != configured) {
      _corrected[FileAccess.pathKey] = grant.path;
    }
    if (grant.bookmark != null) {
      _corrected[FileAccess.bookmarkKey] = grant.bookmark;
    }
    return grant.path;
  }

  Future<void> _releaseFile() async {
    final token = _accessToken;
    _accessToken = null;
    await fileAccess.revoke(token);
  }

  @override
  Future<void> disconnect() async {
    final backend = _backend;
    _backend = null;
    await backend?.close();
    await _releaseFile();
  }

  @override
  Future<void> ping() => _open.ping();

  @override
  Future<void> dispose() => disconnect();

  @override
  Future<List<ContainerRef>> listContainers() => _open.listCollections();

  // --- Tabular view ---------------------------------------------------------

  /// The same points the vector pane plots, as rows.
  ///
  /// A vector space is browsable as a table too — the id, how wide the vector
  /// is, its first few components, and the payload spread across columns — and
  /// that is often the faster way to answer "what is actually in here".
  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    final page = await _open.scroll(
      container.name,
      limit: spec.limit,
      cursor: spec.cursor,
    );
    return Page(
      items: <RowData>[for (final p in page.points) _toRow(p)],
      nextCursor: page.cursor,
    );
  }

  RowData _toRow(VectorPoint point) => <String, CellValue>{
    'id': StringCell(point.id),
    if (point.score != null) 'score': NumCell(point.score!),
    'dim': NumCell(point.vector.length),
    // The whole vector in a cell is unreadable and the column would be the
    // width of the grid; the head of it is enough to tell two points apart,
    // and the pane is where the vector is actually looked at.
    'vector': StringCell(previewVector(point.vector)),
    for (final e in point.payload.entries)
      e.key: CellValue.fromDynamic(e.value),
  };

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async => null;

  /// Columns inferred from a sample, the way the Mongo connector infers them
  /// from documents: there is no declared schema to read, so what the data
  /// happens to carry is the schema.
  @override
  Future<ContainerSchema> getSchema(ContainerRef container) async {
    final info = await _open.describe(container.name);
    final page = await _open.scroll(container.name, limit: _schemaSampleSize);
    final sample = page.points.length;

    final counts = <String, int>{};
    final types = <String, Set<String>>{};
    for (final point in page.points) {
      for (final e in point.payload.entries) {
        counts[e.key] = (counts[e.key] ?? 0) + 1;
        types.putIfAbsent(e.key, () => <String>{}).add(_typeOf(e.value));
      }
    }

    return ContainerSchema(
      container: container,
      columns: <ColumnSchema>[
        const ColumnSchema(
          name: 'id',
          typeLabel: 'string',
          nullable: false,
          isPrimaryKey: true,
        ),
        ColumnSchema(
          name: 'vector',
          typeLabel: info.dimension == null
              ? 'float[]'
              : 'float[${info.dimension}]',
          nullable: false,
        ),
        for (final entry in counts.entries)
          ColumnSchema(
            name: entry.key,
            typeLabel: types[entry.key]!.join(' | '),
            nullable: entry.value < sample,
            frequency: sample == 0 ? null : entry.value / sample,
          ),
      ],
    );
  }

  String _typeOf(Object? v) => switch (v) {
    null => 'null',
    bool() => 'bool',
    int() => 'int',
    double() => 'double',
    String() => 'string',
    List() => 'array',
    Map() => 'object',
    _ => v.runtimeType.toString(),
  };

  // --- Vector view ----------------------------------------------------------

  @override
  Future<VectorSpaceInfo> describeVectors(ContainerRef container) =>
      _open.describe(container.name);

  @override
  Future<List<VectorPoint>> sampleVectors(
    ContainerRef container, {
    int limit = 1000,
  }) async {
    final target = limit.clamp(1, maxSample);
    final out = <VectorPoint>[];
    final sw = Stopwatch()..start();
    String? cursor;
    // Page size is capped separately: some engines refuse a very large single
    // page, and a walk of a few pages costs little next to the projection that
    // follows it.
    const pageSize = 500;

    while (out.length < target) {
      final page = await _open.scroll(
        container.name,
        limit: (target - out.length).clamp(1, pageSize),
        cursor: cursor,
      );
      if (page.points.isEmpty) break;
      out.addAll(page.points);

      // A cursor that does not move means the engine is handing back the same
      // page. Without this the walk still ends — at `target` — but only after
      // fetching the same points over and over, which reads as a hang.
      final next = page.cursor;
      if (next == null || next == cursor) break;
      cursor = next;
    }

    log.i(
      '${provider.label}: read ${out.length} vectors from ${container.name} '
      'in ${sw.elapsedMilliseconds}ms',
    );
    return out.length > target ? out.sublist(0, target) : out;
  }

  @override
  Future<List<VectorPoint>> nearestVectors(
    ContainerRef container,
    List<double> query, {
    int topK = 20,
  }) {
    if (query.isEmpty) {
      throw const QueryError('The query vector is empty');
    }
    return _open.nearest(container.name, query, topK: topK);
  }

  @override
  Future<List<VectorPoint>?> searchVectorText(
    ContainerRef container,
    String query, {
    int limit = 50,
  }) async {
    final sw = Stopwatch()..start();
    final found = await _open.searchText(
      container.name,
      query,
      limit: limit,
    );
    log.i(
      '${provider.label}: text search of ${container.name} '
      '${found == null ? 'unsupported' : 'returned ${found.length}'} '
      'in ${sw.elapsedMilliseconds}ms',
    );
    return found;
  }
}

/// Whether a point's text contains [query], for the client-side fallback.
///
/// Used where the engine cannot search for itself. Case-insensitive, and over
/// every string in the payload rather than one nominated field — the document
/// is usually the interesting one but a subject line or a filename is a
/// perfectly good thing to search for, and there is no schema here saying which
/// is which.
bool payloadContains(VectorPoint point, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return false;
  if (point.id.toLowerCase().contains(needle)) return true;
  for (final value in point.payload.values) {
    if (value == null) continue;
    if (value is num || value is bool) {
      if ('$value'.toLowerCase() == needle) return true;
      continue;
    }
    if ('$value'.toLowerCase().contains(needle)) return true;
  }
  return false;
}

/// The head of a vector, for a grid cell or a tooltip.
///
/// Shared rather than private because the pane shows the same abbreviation next
/// to a selected point, and two spellings of "the first few components" is how
/// a grid and a detail panel come to disagree about the same vector.
String previewVector(List<double> vector, {int components = 4}) {
  if (vector.isEmpty) return '[]';
  final head = vector.take(components).map((v) => v.toStringAsFixed(4));
  final tail = vector.length > components ? ', … +${vector.length - components}' : '';
  return '[${head.join(', ')}$tail]';
}
