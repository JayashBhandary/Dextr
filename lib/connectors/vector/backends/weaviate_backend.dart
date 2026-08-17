import '../../../core/errors.dart';
import '../../data_source.dart';
import '../vector_backend.dart';
import '../vector_types.dart';

/// Weaviate, which splits the two things this app needs across its two APIs.
///
/// Listing objects is REST and pages with a cursor (`?after=`); searching by
/// vector is GraphQL and cannot page at all. So [scroll] talks to `/v1/objects`
/// and [nearest] posts a `nearVector` query to `/v1/graphql`, and the class
/// carries the seam between them.
class WeaviateBackend with VectorHttp implements VectorBackend {
  WeaviateBackend({required this.baseUrl, this.apiKey});

  final String baseUrl;
  final String? apiKey;

  @override
  String get engineLabel => 'Weaviate';

  @override
  Future<void> connect() async {
    openHttp(
      baseUrl: baseUrl,
      headers: <String, String>{
        if (apiKey != null && apiKey!.isNotEmpty)
          'authorization': 'Bearer ${apiKey!}',
      },
    );
    await ping();
  }

  @override
  Future<void> close() async => closeHttp();

  @override
  Future<void> ping() async {
    await send('GET', '/v1/meta');
  }

  @override
  Future<List<ContainerRef>> listCollections() async {
    final body = await send('GET', '/v1/schema');
    final classes = body is Map ? body['classes'] : null;
    if (classes is! List) return const [];
    return <ContainerRef>[
      for (final entry in classes)
        if (entry is Map && entry['class'] != null)
          ContainerRef(name: '${entry['class']}', subtype: 'collection'),
    ];
  }

  @override
  Future<VectorSpaceInfo> describe(String collection) async {
    // The metric is declared on the class; the width is not declared anywhere,
    // because Weaviate takes it from whatever vectorizer produced the data.
    final schema = await send(
      'GET',
      '/v1/schema/${Uri.encodeComponent(collection)}',
      allow404: true,
    );
    var metric = VectorMetric.unknown;
    if (schema is Map) {
      final indexConfig = schema['vectorIndexConfig'];
      if (indexConfig is Map) {
        metric = VectorMetric.parse(indexConfig['distance']);
      }
    }

    final count = await _count(collection);

    // One object, purely to measure the space. Cheaper than it looks and the
    // only way to answer the question the pane actually asks.
    int? dimension;
    final probe = await scroll(collection, limit: 1);
    if (probe.points.isNotEmpty) dimension = probe.points.first.vector.length;

    return VectorSpaceInfo(
      name: collection,
      dimension: dimension,
      count: count,
      metric: metric == VectorMetric.unknown ? VectorMetric.cosine : metric,
    );
  }

  Future<int?> _count(String collection) async {
    final body = await _graphql(
      'query { Aggregate { ${_ident(collection)} { meta { count } } } }',
    );
    final aggregate = body?['Aggregate'];
    if (aggregate is! Map) return null;
    final list = aggregate[collection];
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    final meta = first is Map ? first['meta'] : null;
    return meta is Map ? (meta['count'] as num?)?.toInt() : null;
  }

  @override
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  }) async {
    final body = await send(
      'GET',
      '/v1/objects',
      query: <String, dynamic>{
        'class': collection,
        'limit': limit,
        'include': 'vector',
        'after': ?cursor,
      },
    );
    final objects = body is Map ? body['objects'] : null;
    if (objects is! List) return const VectorPage(points: <VectorPoint>[]);

    final points = <VectorPoint>[];
    for (final entry in objects) {
      if (entry is! Map) continue;
      final vector = parseVector(entry['vector']);
      if (vector == null) continue;
      points.add(
        VectorPoint(
          id: '${entry['id']}',
          vector: vector,
          payload: parsePayload(entry['properties']),
        ),
      );
    }
    return VectorPage(
      points: points,
      // The cursor API walks in ascending uuid order and takes the last id seen
      // as the next `after`. A short page means the walk is done.
      cursor: points.length < limit ? null : points.last.id,
    );
  }

  @override
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  }) async {
    // `_additional` alone is a valid selection set, which matters: selecting
    // properties would mean knowing the class's schema field by field, and the
    // id, distance and vector are what a neighbour list is made of.
    final body = await _graphql(
      'query { Get { ${_ident(collection)}('
      'nearVector: {vector: ${_encodeVector(query)}}, limit: $topK'
      ') { _additional { id distance vector } } } }',
    );
    final get = body?['Get'];
    if (get is! Map) return const [];
    final list = get[collection];
    if (list is! List) return const [];

    final out = <VectorPoint>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final additional = entry['_additional'];
      if (additional is! Map) continue;
      final vector = parseVector(additional['vector']);
      if (vector == null) continue;
      out.add(
        VectorPoint(
          id: '${additional['id']}',
          vector: vector,
          // Everything on the object that is not `_additional` is a property.
          payload: <String, Object?>{
            for (final e in entry.entries)
              if (e.key != '_additional') '${e.key}': e.value,
          },
          score: (additional['distance'] as num?)?.toDouble(),
        ),
      );
    }
    return out;
  }

  /// Weaviate's BM25 keyword search, which every text property is indexed for
  /// by default — so unlike Qdrant this needs no field named in advance.
  @override
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <VectorPoint>[];

    final body = await _graphql(
      'query { Get { ${_ident(collection)}('
      'bm25: {query: ${_encodeString(trimmed)}}, limit: $limit'
      ') { _additional { id score vector } } } }',
    );
    final get = body?['Get'];
    if (get is! Map) return const <VectorPoint>[];
    final list = get[collection];
    if (list is! List) return const <VectorPoint>[];

    final out = <VectorPoint>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final additional = entry['_additional'];
      if (additional is! Map) continue;
      final vector = parseVector(additional['vector']);
      if (vector == null) continue;
      out.add(
        VectorPoint(
          id: '${additional['id']}',
          vector: vector,
          payload: <String, Object?>{
            for (final e in entry.entries)
              if (e.key != '_additional') '${e.key}': e.value,
          },
        ),
      );
    }
    return out;
  }

  /// A string literal for the query document. Escaped by hand because the
  /// query is assembled as text, and an unescaped quote in a search term would
  /// otherwise end the string and change the query.
  String _encodeString(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }

  /// Posts a GraphQL document and returns its `data`, raising anything in
  /// `errors` — GraphQL answers a broken query with HTTP 200 and a body full of
  /// errors, so a status check alone would report success on a failure.
  Future<Map<String, Object?>?> _graphql(String query) async {
    final body = await send(
      'POST',
      '/v1/graphql',
      body: <String, Object?>{'query': query},
    );
    if (body is! Map) return null;
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message = first is Map ? first['message'] : first;
      throw QueryError('Weaviate: $message');
    }
    final data = body['data'];
    return data is Map ? parsePayload(data) : null;
  }

  /// A class name goes into the query text unquoted, so it has to be a GraphQL
  /// identifier and nothing else. Weaviate enforces that on creation; checking
  /// here as well is what keeps a name from being a way to write the query.
  String _ident(String name) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw QueryError('Weaviate: "$name" is not a usable class name');
    }
    return name;
  }

  /// Vectors go inline in the query document. `toStringAsExponential` rather
  /// than `toString` because a Dart double prints as `1.0` but also as
  /// `Infinity` and `NaN`, none of which GraphQL accepts.
  String _encodeVector(List<double> vector) {
    final parts = <String>[];
    for (final v in vector) {
      if (v.isNaN || v.isInfinite) {
        throw const QueryError(
          'Weaviate: the query vector contains NaN or infinity',
        );
      }
      parts.add(v.toString());
    }
    return '[${parts.join(',')}]';
  }
}
