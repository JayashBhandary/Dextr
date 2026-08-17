import 'package:dio/dio.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../data_source.dart';
import 'vector_types.dart';

/// What one vector engine has to be able to do.
///
/// Deliberately five methods and no more. Everything the app asks of a vector
/// store is here — what collections exist, how wide the space is, walk it, and
/// find the neighbours of a vector — and a backend that cannot do one of them
/// throws rather than the interface growing a capability flag per engine.
///
/// Writes are absent on purpose: Dextr reads vector spaces, and an accidental
/// upsert into a production index is not a mistake worth making possible.
abstract class VectorBackend {
  /// Opens whatever the engine needs open. Throws [ConnectError] on failure.
  Future<void> connect();

  Future<void> close();

  /// Cheapest call that proves the engine is answering.
  Future<void> ping();

  Future<List<ContainerRef>> listCollections();

  Future<VectorSpaceInfo> describe(String collection);

  /// One page of the collection, in whatever order the engine walks it.
  ///
  /// [cursor] is the previous page's [VectorPage.cursor], or null to start.
  Future<VectorPage> scroll(
    String collection, {
    required int limit,
    String? cursor,
  });

  /// The [topK] points closest to [query].
  Future<List<VectorPoint>> nearest(
    String collection,
    List<double> query, {
    required int topK,
  });

  /// Points whose text matches [query], searched across the whole collection.
  ///
  /// Returns null — rather than an empty list — when the engine cannot do this
  /// itself. The two mean different things: empty is "searched, found nothing",
  /// null is "did not search", and the caller falls back to filtering what it
  /// has already read and says so. Reporting an unsearched collection as an
  /// empty result would be a lie about coverage.
  ///
  /// This is literal text matching, not semantic search. It is the way to *find*
  /// a point to search vectors from, which is a different question from what is
  /// near it.
  Future<List<VectorPoint>?> searchText(
    String collection,
    String query, {
    required int limit,
  });
}

/// The HTTP plumbing three of the four backends share.
///
/// Every hosted vector engine is a JSON API behind a base URL with one auth
/// header, and each of them reports failure as a status code with a differently
/// shaped body. Writing that out four times produced four different error
/// messages for the same 401, which is how a wrong API key came to read as
/// "Instance of 'DioException'".
mixin VectorHttp {
  Dio? _dio;

  /// The name of the engine, for error messages.
  String get engineLabel;

  Dio get http {
    final d = _dio;
    if (d == null) throw ConnectError('$engineLabel: not connected');
    return d;
  }

  /// Builds the client. [baseUrl] may carry a path; a trailing slash is
  /// dropped so a joined path never doubles it.
  ///
  /// The two timeouts are deliberately different. Getting a TCP connection to
  /// an engine is either quick or never — a URL with nothing behind it should
  /// say so in seconds, not leave someone watching a spinner — while *reading*
  /// a page of a thousand 1536-component vectors is megabytes of JSON and
  /// legitimately takes a while.
  void openHttp({
    required String baseUrl,
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 8),
    Duration transferTimeout = const Duration(seconds: 60),
  }) {
    final trimmed = baseUrl.trim();
    _dio = Dio(
      BaseOptions(
        baseUrl: trimmed.endsWith('/')
            ? trimmed.substring(0, trimmed.length - 1)
            : trimmed,
        headers: {'content-type': 'application/json', ...headers},
        connectTimeout: connectTimeout,
        receiveTimeout: transferTimeout,
        sendTimeout: transferTimeout,
        // Statuses are read by hand in [unwrap] so a 4xx carries the engine's
        // own message instead of Dio's generic one.
        validateStatus: (_) => true,
      ),
    );
  }

  void closeHttp() {
    _dio?.close(force: true);
    _dio = null;
  }

  /// Runs a request and returns its decoded body, or throws with whatever the
  /// engine said went wrong.
  ///
  /// [allow404] is for probing: a path that does not exist on an older server
  /// is an answer, not a failure, and the caller falls back to the older one.
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool allow404 = false,
  }) async {
    final Response<dynamic> res;
    final sw = Stopwatch()..start();
    try {
      res = await http.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method),
      );
      // Logged at every call, because "the pane is stuck" is answered by
      // knowing which request it is stuck in and how long it has been there.
      // Cheap enough to leave in: one line per round trip, not per point.
      if (sw.elapsedMilliseconds > 1000) {
        log.i('$engineLabel $method $path took ${sw.elapsedMilliseconds}ms');
      }
    } on DioException catch (e, st) {
      log.w('$engineLabel $method $path failed after ${sw.elapsedMilliseconds}ms');
      throw ConnectError(
        '$engineLabel: ${_transportMessage(e)}',
        cause: e,
        stack: st,
      );
    }
    final code = res.statusCode ?? 0;
    if (code == 404 && allow404) return null;
    if (code < 200 || code >= 300) {
      throw QueryError('$engineLabel: ${_statusMessage(code, res.data)}');
    }
    return res.data;
  }

  String _transportMessage(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => 'timed out reaching ${e.requestOptions.baseUrl}',
    DioExceptionType.connectionError =>
      'could not reach ${e.requestOptions.baseUrl} — is it running, and is the '
          'URL right?',
    DioExceptionType.badCertificate =>
      'the TLS certificate for ${e.requestOptions.baseUrl} was rejected',
    _ => e.message ?? e.toString(),
  };

  /// Pulls the human half out of an error body. Engines nest it differently —
  /// Qdrant `status.error`, Chroma `error`/`detail`, Pinecone `message`,
  /// Weaviate `error[0].message` — so all four are tried before falling back to
  /// the raw body.
  String _statusMessage(int code, Object? data) {
    final detail = _extractDetail(data);
    final prefix = switch (code) {
      401 || 403 => 'refused the credential (HTTP $code)',
      404 => 'no such collection or endpoint (HTTP 404)',
      _ => 'HTTP $code',
    };
    return detail == null ? prefix : '$prefix — $detail';
  }

  String? _extractDetail(Object? data) {
    if (data is String) return data.isEmpty ? null : _clip(data);
    if (data is! Map) return null;
    final status = data['status'];
    if (status is Map && status['error'] != null) {
      return _clip('${status['error']}');
    }
    for (final key in const ['error', 'detail', 'message', 'msg']) {
      final v = data[key];
      if (v is String && v.isNotEmpty) return _clip(v);
      if (v is Map && v['message'] is String) return _clip('${v['message']}');
    }
    final errors = data['error'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      if (first is Map && first['message'] != null) {
        return _clip('${first['message']}');
      }
    }
    return null;
  }

  /// A server that answers a bad path with an HTML page should not paste the
  /// page into a banner.
  String _clip(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 300 ? one : '${one.substring(0, 300)}…';
  }
}

/// Reads a JSON array of numbers into a vector, tolerating ints.
///
/// Every engine sends floats, and JSON being JSON, a component that happens to
/// be whole arrives as an int. Left to itself that produces a `List<dynamic>`
/// that throws the moment it is used as a `List<double>`.
List<double>? parseVector(Object? raw) {
  if (raw is! List) return null;
  final out = List<double>.filled(raw.length, 0);
  for (var i = 0; i < raw.length; i++) {
    final v = raw[i];
    if (v is num) {
      out[i] = v.toDouble();
    } else {
      final parsed = double.tryParse('$v');
      if (parsed == null) return null;
      out[i] = parsed;
    }
  }
  return out;
}

/// Coerces a decoded JSON map to the payload type, whatever its key type.
Map<String, Object?> parsePayload(Object? raw) {
  if (raw is! Map) return const {};
  return {for (final e in raw.entries) e.key.toString(): e.value};
}
