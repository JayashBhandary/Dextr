import '../../../core/errors.dart';
import '../../data_source.dart';
import '../vector_backend.dart';
import '../vector_types.dart';

/// Qdrant over its REST API.
///
/// One backend for local and cloud alike: Qdrant Cloud is the same API behind
/// TLS with an `api-key` header, so the only difference the two modes make is
/// what the form put in the URL box and whether a credential came with it.
class QdrantBackend with VectorHttp implements VectorBackend {
  QdrantBackend({required this.baseUrl, this.apiKey});

  final String baseUrl;
  final String? apiKey;

  @override
  String get engineLabel => 'Qdrant';

  /// Set on the first search. Qdrant grew `/points/query` in 1.10 and it is the
  /// endpoint to prefer, but a 1.9 server 404s it and wants `/points/search`.
  /// Probed once rather than per search, because the answer cannot change while
  /// a connection is open.
  bool? _hasQueryApi;

  @override
  Future<void> connect() async {
    openHttp(
      baseUrl: baseUrl,
      headers: <String, String>{
        if (apiKey != null && apiKey!.isNotEmpty) 'api-key': apiKey!,
      },
    );
    await ping();
  }

  @override
  Future<void> close() async => closeHttp();

  @override
  Future<void> ping() async {
    await send('GET', '/collections');
  }

  @override
  Future<List<ContainerRef>> listCollections() async {
    final body = await send('GET', '/collections');
    final list = _result(body)?['collections'];
    if (list is! List) return const [];
    return <ContainerRef>[
      for (final entry in list)
        if (entry is Map && entry['name'] != null)
          ContainerRef(name: '${entry['name']}', subtype: 'collection'),
    ];
  }

  @override
  Future<VectorSpaceInfo> describe(String collection) async {
    final body = await send('GET', '/collections/${_seg(collection)}');
    final result = _result(body) ?? const {};
    final params = _mapAt(result, ['config', 'params']);
    final vectors = params?['vectors'];

    int? dimension;
    VectorMetric metric = VectorMetric.unknown;
    if (vectors is Map) {
      if (vectors['size'] is num) {
        // A single unnamed vector: `{size, distance}`.
        dimension = (vectors['size'] as num).toInt();
        metric = VectorMetric.parse(vectors['distance']);
      } else if (vectors.isNotEmpty) {
        // Named vectors: `{"text": {size, distance}, …}`. The first one is what
        // gets plotted, matching what [scroll] pulls out of each point.
        final first = vectors.values.first;
        if (first is Map) {
          dimension = (first['size'] as num?)?.toInt();
          metric = VectorMetric.parse(first['distance']);
        }
      }
    }

    final count = (result['points_count'] ?? result['vectors_count']) as num?;
    return VectorSpaceInfo(
      name: collection,
      dimension: dimension,
      count: count?.toInt(),
      metric: metric,
    );
  }

  @override
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  }) async {
    final body = await send(
      'POST',
      '/collections/${_seg(collection)}/points/scroll',
      body: <String, Object?>{
        'limit': limit,
        'with_payload': true,
        'with_vector': true,
        if (cursor != null) 'offset': _decodeOffset(cursor),
      },
    );
    final result = _result(body) ?? const {};
    final points = result['points'];
    final next = result['next_page_offset'];
    return VectorPage(
      points: <VectorPoint>[
        if (points is List)
          for (final raw in points)
            if (_toPoint(raw) case final VectorPoint p) p,
      ],
      cursor: next == null ? null : '$next',
    );
  }

  @override
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  }) async {
    if (_hasQueryApi ?? true) {
      final body = await send(
        'POST',
        '/collections/${_seg(collection)}/points/query',
        body: <String, Object?>{
          'query': query,
          'limit': topK,
          'with_payload': true,
          'with_vector': true,
        },
        allow404: true,
      );
      if (body != null) {
        _hasQueryApi = true;
        final points = _result(body)?['points'];
        return _points(points);
      }
      _hasQueryApi = false;
    }

    // Pre-1.10.
    final body = await send(
      'POST',
      '/collections/${_seg(collection)}/points/search',
      body: <String, Object?>{
        'vector': query,
        'limit': topK,
        'with_payload': true,
        'with_vector': true,
      },
    );
    return _points(_result(body) ?? (body is Map ? body['result'] : null));
  }

  /// Qdrant has no collection-wide text search.
  ///
  /// Its `match: {text: …}` filter works against *one named payload field*, and
  /// only where a full-text index has been created on it — neither of which
  /// this app can know. Returning null says so honestly and lets the caller
  /// filter what it has already read, rather than guessing at a field name and
  /// reporting an empty result for a collection that was never searched.
  @override
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  }) async => null;

  List<VectorPoint> _points(Object? raw) => <VectorPoint>[
    if (raw is List)
      for (final entry in raw)
        if (_toPoint(entry) case final VectorPoint p) p,
  ];

  /// One scroll or search hit. Null when the point came back without a vector,
  /// which happens for a collection configured with sparse vectors only —
  /// there is nothing to plot, and a row of zeroes would be a lie.
  VectorPoint? _toPoint(Object? raw) {
    if (raw is! Map) return null;
    final vector = _vectorOf(raw['vector']);
    if (vector == null) return null;
    return VectorPoint(
      id: '${raw['id']}',
      vector: vector,
      payload: parsePayload(raw['payload']),
      score: (raw['score'] as num?)?.toDouble(),
    );
  }

  /// Qdrant sends either an array or, for a collection with named vectors, a
  /// map of them. The first named vector is the one plotted — consistently the
  /// same one [describe] reported the width of.
  List<double>? _vectorOf(Object? raw) {
    if (raw is List) return parseVector(raw);
    if (raw is Map && raw.isNotEmpty) {
      for (final value in raw.values) {
        final parsed = parseVector(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  /// Qdrant's scroll offset is a point id, which may be an integer or a UUID.
  /// It arrives here as a string because a cursor is a string; sending `"7"`
  /// where the ids are numbers gets it rejected, so a digits-only cursor goes
  /// back as a number.
  Object _decodeOffset(String cursor) => int.tryParse(cursor) ?? cursor;

  Map<String, Object?>? _result(Object? body) {
    if (body is! Map) return null;
    final result = body['result'];
    return result is Map ? parsePayload(result) : null;
  }

  Map<String, Object?>? _mapAt(Map<String, Object?> root, List<String> path) {
    Object? node = root;
    for (final key in path) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node is Map ? parsePayload(node) : null;
  }

  /// A collection name goes in a path segment, and Qdrant permits characters
  /// that do not survive one unescaped.
  String _seg(String name) {
    if (name.isEmpty) throw const QueryError('Qdrant: empty collection name');
    return Uri.encodeComponent(name);
  }
}
