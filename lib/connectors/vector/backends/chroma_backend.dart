import '../../../core/errors.dart';
import '../../data_source.dart';
import '../vector_backend.dart';
import '../vector_types.dart';

/// Chroma over its HTTP API, in a server deployment.
///
/// Two API generations are in the wild and both are still deployed: v1, which
/// is flat (`/api/v1/collections`), and v2, which is multi-tenant
/// (`/api/v2/tenants/{t}/databases/{d}/collections`). Which one a server speaks
/// is settled once at connect by asking each for a heartbeat, because guessing
/// wrong turns every later call into a 404 that reads like a missing
/// collection.
///
/// For a persist directory with no server in front of it, see
/// `ChromaFileBackend` — same engine, no HTTP at all.
class ChromaBackend with VectorHttp implements VectorBackend {
  ChromaBackend({
    required this.baseUrl,
    this.apiKey,
    String? tenant,
    String? database,
  }) : tenant = (tenant == null || tenant.isEmpty) ? 'default_tenant' : tenant,
       database = (database == null || database.isEmpty)
           ? 'default_database'
           : database;

  final String baseUrl;
  final String? apiKey;
  final String tenant;
  final String database;

  @override
  String get engineLabel => 'Chroma';

  bool _v2 = true;

  /// Chroma addresses a collection by uuid, not by name, everywhere except the
  /// listing that hands out both. Cached so that browsing a collection is not
  /// two round trips per page.
  final Map<String, String> _idByName = <String, String>{};

  /// The dimension, from the same listing. Chroma reports it per collection and
  /// there is no cheaper call that returns it alone.
  final Map<String, int?> _dimensionByName = <String, int?>{};

  String get _root => _v2
      ? '/api/v2/tenants/${Uri.encodeComponent(tenant)}'
            '/databases/${Uri.encodeComponent(database)}'
      : '/api/v1';

  @override
  Future<void> connect() async {
    openHttp(
      baseUrl: baseUrl,
      headers: <String, String>{
        if (apiKey != null && apiKey!.isNotEmpty) ...<String, String>{
          // Chroma's two shipped auth providers read different headers and the
          // server only ever honours the one it was configured for. Sending
          // both costs a header and saves the reader guessing which their
          // deployment uses.
          'x-chroma-token': apiKey!,
          'authorization': 'Bearer ${apiKey!}',
        },
      },
    );

    final v2 = await send('GET', '/api/v2/heartbeat', allow404: true);
    if (v2 != null) {
      _v2 = true;
      return;
    }
    final v1 = await send('GET', '/api/v1/heartbeat', allow404: true);
    if (v1 != null) {
      _v2 = false;
      return;
    }
    throw const ConnectError(
      'Chroma: no heartbeat at /api/v2 or /api/v1 — the URL is reachable but '
      'does not look like a Chroma server',
    );
  }

  @override
  Future<void> close() async {
    _idByName.clear();
    _dimensionByName.clear();
    closeHttp();
  }

  @override
  Future<void> ping() async {
    await send('GET', _v2 ? '/api/v2/heartbeat' : '/api/v1/heartbeat');
  }

  @override
  Future<List<ContainerRef>> listCollections() async {
    final body = await send('GET', '$_root/collections');
    if (body is! List) return const [];
    _idByName.clear();
    _dimensionByName.clear();
    final out = <ContainerRef>[];
    for (final entry in body) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final id = entry['id'];
      if (name == null || id == null) continue;
      _idByName['$name'] = '$id';
      _dimensionByName['$name'] = (entry['dimension'] as num?)?.toInt();
      out.add(ContainerRef(name: '$name', subtype: 'collection'));
    }
    return out;
  }

  Future<String> _idOf(String collection) async {
    final known = _idByName[collection];
    if (known != null) return known;
    await listCollections();
    final found = _idByName[collection];
    if (found == null) {
      throw QueryError('Chroma: no collection named "$collection"');
    }
    return found;
  }

  @override
  Future<VectorSpaceInfo> describe(String collection) async {
    final id = await _idOf(collection);
    final count = await send('GET', '$_root/collections/$id/count');

    // The metric lives in the collection's configuration under whichever of
    // three key spellings the server's version uses.
    final detail = await send('GET', '$_root/collections/$id', allow404: true);
    var metric = VectorMetric.unknown;
    var dimension = _dimensionByName[collection];
    if (detail is Map) {
      dimension ??= (detail['dimension'] as num?)?.toInt();
      final meta = detail['metadata'];
      if (meta is Map) metric = VectorMetric.parse(meta['hnsw:space']);
      if (metric == VectorMetric.unknown) {
        final config = detail['configuration_json'] ?? detail['configuration'];
        if (config is Map) {
          final hnsw = config['hnsw'] ?? config['hnsw_configuration'];
          if (hnsw is Map) metric = VectorMetric.parse(hnsw['space']);
        }
      }
    }
    // Chroma's default, and what an unlabelled collection is actually using.
    if (metric == VectorMetric.unknown) metric = VectorMetric.euclidean;

    return VectorSpaceInfo(
      name: collection,
      dimension: dimension,
      count: count is num ? count.toInt() : null,
      metric: metric,
    );
  }

  @override
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  }) async {
    final id = await _idOf(collection);
    final offset = int.tryParse(cursor ?? '') ?? 0;
    final body = await send(
      'POST',
      '$_root/collections/$id/get',
      body: <String, Object?>{
        'limit': limit,
        'offset': offset,
        'include': const <String>['embeddings', 'metadatas', 'documents'],
      },
    );
    final points = _columnsToPoints(body);
    return VectorPage(
      points: points,
      // Chroma pages by integer offset and says nothing about whether more
      // remain, so a short page is the only end-of-list signal there is.
      cursor: points.length < limit ? null : '${offset + points.length}',
    );
  }

  @override
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  }) async {
    final id = await _idOf(collection);
    final body = await send(
      'POST',
      '$_root/collections/$id/query',
      body: <String, Object?>{
        'query_embeddings': <List<double>>[query],
        'n_results': topK,
        'include': const <String>[
          'embeddings',
          'metadatas',
          'documents',
          'distances',
        ],
      },
    );
    // A query result is the same column layout as `get`, wrapped one level
    // deeper: one array per query vector, and exactly one was sent.
    return _columnsToPoints(body, nested: true);
  }

  /// Chroma's own document filter, which is a substring test over the text an
  /// embedding was made from.
  @override
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <VectorPoint>[];
    final id = await _idOf(collection);
    final body = await send(
      'POST',
      '$_root/collections/$id/get',
      body: <String, Object?>{
        'limit': limit,
        'where_document': <String, Object?>{r'$contains': trimmed},
        'include': const <String>['embeddings', 'metadatas', 'documents'],
      },
    );
    return _columnsToPoints(body);
  }

  /// Chroma answers in parallel arrays — `ids`, `embeddings`, `metadatas`,
  /// `documents`, `distances` — rather than a list of records. Zipping them is
  /// the whole of reading a Chroma response.
  ///
  /// [nested] unwraps the extra per-query-vector level that `query` adds and
  /// `get` does not.
  List<VectorPoint> _columnsToPoints(Object? body, {bool nested = false}) {
    if (body is! Map) return const [];

    List<Object?>? column(String key) {
      final raw = body[key];
      if (raw is! List) return null;
      if (!nested) return raw;
      if (raw.isEmpty) return const <Object?>[];
      final first = raw.first;
      return first is List ? first : null;
    }

    final ids = column('ids');
    if (ids == null) return const [];
    final embeddings = column('embeddings');
    final metadatas = column('metadatas');
    final documents = column('documents');
    final distances = column('distances');

    T? at<T>(List<Object?>? list, int i) =>
        (list != null && i < list.length) ? list[i] as T? : null;

    final out = <VectorPoint>[];
    for (var i = 0; i < ids.length; i++) {
      final vector = parseVector(at<Object>(embeddings, i));
      if (vector == null) continue;
      final payload = parsePayload(at<Object>(metadatas, i));
      final document = at<Object>(documents, i);
      out.add(
        VectorPoint(
          id: '${ids[i]}',
          vector: vector,
          payload: <String, Object?>{
            ...payload,
            chromaDocumentKey: ?document,
          },
          score: (at<Object>(distances, i) as num?)?.toDouble(),
        ),
      );
    }
    return out;
  }
}
