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

/// A refusal from an engine, with the status it came back on.
///
/// The code is carried rather than only spelled into the message because some
/// of them are worth *acting* on: a hosted engine rejecting a page as too large
/// is a thing a client can retry smaller, and matching on a substring of a
/// human-readable sentence to find that out would be a poor way to know.
class VectorHttpError extends QueryError {
  const VectorHttpError(
    super.message, {
    required this.statusCode,
    super.cause,
    super.stack,
  });

  final int statusCode;

  /// Whether asking for less might succeed where this failed.
  ///
  /// 422 is what Chroma Cloud answers when a request is well-formed but
  /// refused; 413 is the plain "payload too large"; 429 is a rate limit that a
  /// smaller page also eases.
  bool get mightSucceedSmaller =>
      statusCode == 422 || statusCode == 413 || statusCode == 429;
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
      throw VectorHttpError(
        '$engineLabel: ${_statusMessage(code, res.data)}',
        statusCode: code,
      );
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

  /// Pulls the human half out of an error body.
  ///
  /// The **message is preferred over the error name**, and that ordering is the
  /// whole point. Chroma answers with `{"error": "ChromaError", "message":
  /// "…the actual reason…"}`, where the name is the category its own code falls
  /// back to for half a dozen conditions. Reading the name first turned every
  /// one of those into the bare word "ChromaError" and threw away the only part
  /// that said what had gone wrong.
  String? _extractDetail(Object? data) {
    if (data is String) return data.isEmpty ? null : _clip(data);
    if (data is! Map) return null;

    String? message;
    for (final key in const ['message', 'detail', 'msg', 'description']) {
      final v = data[key];
      if (v is String && v.isNotEmpty) {
        message = v;
        break;
      }
    }

    // The error's *name*, worth keeping alongside the message but never
    // instead of it.
    String? kind;
    final error = data['error'];
    if (error is String && error.isNotEmpty) {
      kind = error;
    } else if (error is Map) {
      if (error['message'] is String) message ??= error['message'] as String;
      if (error['type'] is String) kind ??= error['type'] as String;
    } else if (error is List && error.isNotEmpty) {
      final first = error.first;
      if (first is Map && first['message'] != null) {
        message ??= '${first['message']}';
      }
    }

    final status = data['status'];
    if (status is Map && status['error'] != null) {
      message ??= '${status['error']}';
    }

    if (message == null) return kind == null ? null : _clip(kind);
    if (kind == null || kind == message) return _clip(message);
    return _clip('$message ($kind)');
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
