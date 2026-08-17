import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../../../core/errors.dart';
import '../../data_source.dart';
import '../vector_backend.dart';
import '../vector_types.dart';

/// Pinecone, which is two APIs rather than one.
///
/// The control plane at `api.pinecone.io` knows what indexes exist and how wide
/// they are; the data plane lives on a per-index host and is the only thing
/// that will hand back a vector. So an index name has to be resolved to a host
/// before it can be read, and that mapping is what most of this class is for.
///
/// Cloud-only by construction: there is no Pinecone to run locally, which is
/// why [VectorProvider.pinecone] advertises only [VectorMode.cloud].
class PineconeBackend with VectorHttp implements VectorBackend {
  PineconeBackend({
    required this.apiKey,
    String? controlPlaneUrl,
    this.namespace = '',
  }) : controlPlaneUrl =
           (controlPlaneUrl == null || controlPlaneUrl.trim().isEmpty)
           ? 'https://api.pinecone.io'
           : controlPlaneUrl.trim();

  final String apiKey;
  final String controlPlaneUrl;

  /// Empty means the default namespace, which is what an index has until
  /// somebody makes another one.
  final String namespace;

  /// Pinned rather than left to float. Pinecone versions its API by header and
  /// an unversioned request is served by whatever is current, so a release
  /// could change a response shape under a build that has already shipped.
  static const _apiVersion = '2025-04';

  /// How many ids one `fetch` call may name. Bounded by URL length rather than
  /// by anything Pinecone documents: the ids go in the query string.
  static const _fetchBatch = 100;

  @override
  String get engineLabel => 'Pinecone';

  final Map<String, _PineconeIndex> _indexes = <String, _PineconeIndex>{};

  /// One client per index host, alongside the control-plane one in [http].
  final Map<String, Dio> _dataPlanes = <String, Dio>{};

  Map<String, String> get _headers => <String, String>{
    'Api-Key': apiKey,
    'X-Pinecone-Api-Version': _apiVersion,
    'content-type': 'application/json',
  };

  @override
  Future<void> connect() async {
    if (apiKey.isEmpty) {
      throw const ConnectError('Pinecone: an API key is required');
    }
    openHttp(baseUrl: controlPlaneUrl, headers: _headers);
    await _loadIndexes();
  }

  @override
  Future<void> close() async {
    for (final dio in _dataPlanes.values) {
      dio.close(force: true);
    }
    _dataPlanes.clear();
    _indexes.clear();
    closeHttp();
  }

  @override
  Future<void> ping() async {
    await send('GET', '/indexes');
  }

  Future<void> _loadIndexes() async {
    final body = await send('GET', '/indexes');
    final list = body is Map ? body['indexes'] : body;
    _indexes.clear();
    if (list is! List) return;
    for (final entry in list) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final host = entry['host'];
      if (name == null || host == null) continue;
      _indexes['$name'] = _PineconeIndex(
        name: '$name',
        host: '$host',
        dimension: (entry['dimension'] as num?)?.toInt(),
        metric: VectorMetric.parse(entry['metric']),
      );
    }
  }

  @override
  Future<List<ContainerRef>> listCollections() async {
    if (_indexes.isEmpty) await _loadIndexes();
    return <ContainerRef>[
      for (final index in _indexes.values)
        ContainerRef(name: index.name, subtype: 'collection'),
    ];
  }

  Future<_PineconeIndex> _indexOf(String name) async {
    if (!_indexes.containsKey(name)) await _loadIndexes();
    final index = _indexes[name];
    if (index == null) {
      throw QueryError('Pinecone: no index named "$name" for this API key');
    }
    return index;
  }

  /// The data-plane client for an index, made once and kept.
  Dio _dataPlane(_PineconeIndex index) => _dataPlanes.putIfAbsent(index.name, () {
    final host = index.host.startsWith('http')
        ? index.host
        : 'https://${index.host}';
    return Dio(
      BaseOptions(
        baseUrl: host,
        headers: _headers,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        validateStatus: (_) => true,
      ),
    );
  });

  /// A data-plane call. Deliberately not [send]: that one is bound to the
  /// control-plane client, and these go to a different host per index.
  Future<dynamic> _data(
    _PineconeIndex index,
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool allow404 = false,
  }) async {
    final Response<dynamic> res;
    try {
      res = await _dataPlane(index).request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method),
      );
    } on DioException catch (e, st) {
      throw ConnectError(
        'Pinecone: could not reach ${index.host} — ${e.message ?? e}',
        cause: e,
        stack: st,
      );
    }
    final code = res.statusCode ?? 0;
    if (code == 404 && allow404) return null;
    if (code < 200 || code >= 300) {
      final data = res.data;
      final detail = data is Map ? data['message'] ?? data['error'] : null;
      throw QueryError(
        'Pinecone: HTTP $code on ${index.name}'
        '${detail == null ? '' : ' — $detail'}',
      );
    }
    return res.data;
  }

  @override
  Future<VectorSpaceInfo> describe(String collection) async {
    final index = await _indexOf(collection);
    int? count;
    final stats = await _data(
      index,
      'POST',
      '/describe_index_stats',
      body: const <String, Object?>{},
      allow404: true,
    );
    if (stats is Map) {
      if (namespace.isEmpty) {
        count = (stats['totalVectorCount'] as num?)?.toInt();
      } else {
        final namespaces = stats['namespaces'];
        final entry = namespaces is Map ? namespaces[namespace] : null;
        count = entry is Map ? (entry['vectorCount'] as num?)?.toInt() : null;
      }
    }
    return VectorSpaceInfo(
      name: index.name,
      dimension: index.dimension,
      count: count,
      metric: index.metric,
    );
  }

  @override
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  }) async {
    final index = await _indexOf(collection);

    // Serverless indexes can enumerate ids; pod-based ones cannot, and answer
    // 404. The fallback below is the standard trick — search the space from a
    // point that is nowhere in particular and take what comes back.
    final listed = await _data(
      index,
      'GET',
      '/vectors/list',
      query: <String, dynamic>{
        'limit': limit,
        'paginationToken': ?cursor,
        if (namespace.isNotEmpty) 'namespace': namespace,
      },
      allow404: true,
    );
    if (listed == null) return _scrollByQuery(index, limit: limit);

    final ids = <String>[
      if (listed is Map && listed['vectors'] is List)
        for (final entry in listed['vectors'] as List)
          if (entry is Map && entry['id'] != null) '${entry['id']}',
    ];
    if (ids.isEmpty) return const VectorPage(points: <VectorPoint>[]);

    // `list` returns ids only; the values need a second call — and `fetch`
    // takes its ids in the query string, one `ids=` parameter each. Five
    // hundred of them is a twenty-kilobyte URL, which servers and proxies
    // answer with a 414 or by dropping the request on the floor, so they go in
    // batches small enough to stay inside anyone's line limit.
    final vectors = <String, Object?>{};
    for (var start = 0; start < ids.length; start += _fetchBatch) {
      final batch = ids.sublist(
        start,
        math.min(start + _fetchBatch, ids.length),
      );
      final fetched = await _data(
        index,
        'GET',
        '/vectors/fetch',
        query: <String, dynamic>{
          'ids': batch,
          if (namespace.isNotEmpty) 'namespace': namespace,
        },
      );
      final got = fetched is Map ? fetched['vectors'] : null;
      if (got is Map) {
        for (final e in got.entries) {
          vectors['${e.key}'] = e.value;
        }
      }
    }

    final points = <VectorPoint>[];
    // Walked in the order `list` gave, not the map's, so paging is stable.
    for (final id in ids) {
      final point = _toPoint(vectors[id]);
      if (point != null) points.add(point);
    }

    final pagination = listed is Map ? listed['pagination'] : null;
    final next = pagination is Map ? pagination['next'] : null;
    return VectorPage(points: points, cursor: next == null ? null : '$next');
  }

  /// What a pod-based index gets instead of enumeration: one query from the
  /// origin, which returns [limit] vectors and no way to ask for the next
  /// [limit]. Deliberately single-page — reporting a cursor here would promise
  /// a walk that cannot be continued.
  Future<VectorPage> _scrollByQuery(
    _PineconeIndex index, {
    required int limit,
  }) async {
    final dimension = index.dimension;
    if (dimension == null) {
      throw QueryError(
        'Pinecone: ${index.name} does not support listing ids, and its '
        'dimension is unknown, so it cannot be sampled either',
      );
    }
    final points = await nearest(
      index.name,
      List<double>.filled(dimension, 0),
      topK: limit,
    );
    return VectorPage(points: points);
  }

  @override
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  }) async {
    final index = await _indexOf(collection);
    final body = await _data(
      index,
      'POST',
      '/query',
      body: <String, Object?>{
        'vector': query,
        'topK': topK,
        'includeValues': true,
        'includeMetadata': true,
        if (namespace.isNotEmpty) 'namespace': namespace,
      },
    );
    final matches = body is Map ? body['matches'] : null;
    return <VectorPoint>[
      if (matches is List)
        for (final entry in matches) ?_toPoint(entry),
    ];
  }

  /// Pinecone has no text search.
  ///
  /// Its metadata filters match exact values and ranges — there is no substring
  /// or keyword operator — so there is nothing to run server-side, and saying
  /// so lets the caller fall back rather than report a collection as empty.
  @override
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  }) async => null;

  VectorPoint? _toPoint(Object? raw) {
    if (raw is! Map) return null;
    final vector = parseVector(raw['values']);
    if (vector == null || vector.isEmpty) return null;
    return VectorPoint(
      id: '${raw['id']}',
      vector: vector,
      payload: parsePayload(raw['metadata']),
      score: (raw['score'] as num?)?.toDouble(),
    );
  }
}

/// What the control plane knows about one index.
class _PineconeIndex {
  const _PineconeIndex({
    required this.name,
    required this.host,
    this.dimension,
    this.metric = VectorMetric.unknown,
  });

  final String name;
  final String host;
  final int? dimension;
  final VectorMetric metric;
}
