import 'dart:convert';
import 'dart:io';

import 'package:dextr/connectors/vector/backends/chroma_backend.dart';
import 'package:dextr/connectors/vector/vector_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in Chroma, served over real HTTP on localhost.
///
/// A real socket rather than a mocked client: what is under test is the wire
/// behaviour — status codes, error bodies, how large a page the server will
/// accept — and a fake adapter would be testing the fake.
class _FakeChroma {
  _FakeChroma._(this._server);

  final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  /// Requests seen, in order, as (method, path, decoded body).
  final List<({String method, String path, Object? body})> seen =
      <({String method, String path, Object? body})>[];

  /// Largest `limit` the server will accept on `get`; anything above is
  /// refused the way Chroma Cloud refuses an oversized page.
  int maxPageLimit = 1000;

  /// When set, `get` always fails with this status and message.
  ({int status, Object body})? getFailure;

  /// Whether the v2 heartbeat answers, for exercising the v1 fallback.
  bool speaksV2 = true;

  static Future<_FakeChroma> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeChroma._(server);
    fake._serve();
    return fake;
  }

  void _serve() {
    _server.listen((request) async {
      final path = request.uri.path;
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty ? null : jsonDecode(raw);
      seen.add((method: request.method, path: path, body: body));

      void send(int status, Object? payload) {
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload))
          ..close();
      }

      if (path == '/api/v2/heartbeat') {
        if (!speaksV2) {
          send(404, <String, Object?>{'error': 'NotFoundError'});
          return;
        }
        send(200, <String, Object?>{'nanosecond heartbeat': 1});
        return;
      }
      if (path == '/api/v1/heartbeat') {
        send(200, <String, Object?>{'nanosecond heartbeat': 1});
        return;
      }

      if (path.endsWith('/collections')) {
        send(200, <Object?>[
          <String, Object?>{
            'id': '11111111-1111-1111-1111-111111111111',
            'name': 'docs',
            'dimension': 3,
          },
        ]);
        return;
      }
      if (path.endsWith('/count')) {
        send(200, 42);
        return;
      }

      if (path.endsWith('/get')) {
        final failure = getFailure;
        if (failure != null) {
          send(failure.status, failure.body);
          return;
        }
        final limit = (body as Map?)?['limit'] as int? ?? 0;
        if (limit > maxPageLimit) {
          // Exactly the shape Chroma answers with: a category in `error` and
          // the reason in `message`.
          send(422, <String, Object?>{
            'error': 'ChromaError',
            'message': 'Requested limit $limit exceeds the maximum of '
                '$maxPageLimit for this tenant',
          });
          return;
        }
        final n = limit < 3 ? limit : 3;
        send(200, <String, Object?>{
          'ids': <String>[for (var i = 0; i < n; i++) 'doc-$i'],
          'embeddings': <List<double>>[
            for (var i = 0; i < n; i++) <double>[i.toDouble(), 0, 1],
          ],
          'metadatas': <Object?>[
            for (var i = 0; i < n; i++) <String, Object?>{'n': i},
          ],
          'documents': <String>[for (var i = 0; i < n; i++) 'text $i'],
        });
        return;
      }

      // Anything else: the collection detail lookup, which is optional.
      send(404, <String, Object?>{'error': 'NotFoundError'});
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late _FakeChroma fake;
  late ChromaBackend chroma;

  setUp(() async {
    fake = await _FakeChroma.start();
    chroma = ChromaBackend(baseUrl: fake.url);
  });

  tearDown(() async {
    await chroma.close();
    await fake.stop();
  });

  test('speaks v2 when the server does', () async {
    await chroma.connect();
    final collections = await chroma.listCollections();
    expect(collections.single.name, 'docs');
    expect(
      fake.seen.map((r) => r.path),
      contains('/api/v2/heartbeat'),
    );
    expect(
      fake.seen.last.path,
      startsWith('/api/v2/tenants/default_tenant/databases/default_database'),
    );
  });

  test('falls back to v1 when v2 is not there', () async {
    fake.speaksV2 = false;
    await chroma.connect();
    await chroma.listCollections();
    expect(fake.seen.last.path, '/api/v1/collections');
  });

  group('error reporting', () {
    test('shows the message, not the error category', () async {
      // The regression: Chroma's `error` field is a category its own code
      // falls back to for half a dozen conditions, and reading it first turned
      // every one of them into the bare word "ChromaError".
      fake.getFailure = (
        status: 422,
        body: <String, Object?>{
          'error': 'ChromaError',
          'message': 'Collection is still being indexed',
        },
      );
      await chroma.connect();

      await expectLater(
        chroma.scroll('docs', limit: 10),
        throwsA(
          isA<VectorHttpError>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('Collection is still being indexed'),
                  contains('ChromaError'),
                  contains('422'),
                ),
              ),
        ),
      );
    });

    test('a plain-text body is still reported', () async {
      fake.getFailure = (status: 500, body: 'the gateway fell over');
      await chroma.connect();
      await expectLater(
        chroma.scroll('docs', limit: 10),
        throwsA(
          isA<VectorHttpError>().having(
            (e) => e.message,
            'message',
            contains('the gateway fell over'),
          ),
        ),
      );
    });

    test('a refused credential says so plainly', () async {
      fake.getFailure = (
        status: 401,
        body: <String, Object?>{'error': 'Unauthorized', 'message': 'bad token'},
      );
      await chroma.connect();
      await expectLater(
        chroma.scroll('docs', limit: 10),
        throwsA(
          isA<VectorHttpError>().having(
            (e) => e.message,
            'message',
            allOf(contains('refused the credential'), contains('bad token')),
          ),
        ),
      );
    });
  });

  group('page size', () {
    test('never asks for more than a hosted tier accepts', () async {
      // The opening page is already modest, so a server with a ceiling of a
      // hundred is never provoked in the first place.
      fake.maxPageLimit = 100;
      await chroma.connect();
      final page = await chroma.scroll('docs', limit: 500);

      expect(page.points, hasLength(3));
      final asked = fake.seen
          .where((r) => r.path.endsWith('/get'))
          .map((r) => (r.body as Map)['limit'])
          .toList();
      expect(asked, <Object?>[100]);
    });

    test('halves the page when the server refuses it, and succeeds', () async {
      // The failure the user hit: Chroma Cloud refusing a page with a 422
      // whose ceiling is not published anywhere. Rather than guess the number,
      // the client discovers it.
      fake.maxPageLimit = 40;
      await chroma.connect();
      final page = await chroma.scroll('docs', limit: 500);

      expect(page.points, hasLength(3));
      final asked = fake.seen
          .where((r) => r.path.endsWith('/get'))
          .map((r) => (r.body as Map)['limit'])
          .toList();
      // 100 refused, 50 refused, 25 accepted.
      expect(asked, <Object?>[100, 50, 25]);
    });

    test('remembers the size that worked, rather than relearning it', () async {
      fake.maxPageLimit = 40;
      await chroma.connect();
      await chroma.scroll('docs', limit: 500);
      fake.seen.clear();

      await chroma.scroll('docs', limit: 500);
      final asked = fake.seen
          .where((r) => r.path.endsWith('/get'))
          .map((r) => (r.body as Map)['limit'])
          .toList();
      expect(asked, <Object?>[25], reason: 'no re-negotiation on later pages');
    });

    test('gives up rather than shrinking for ever', () async {
      // A 422 that is not about size at all must not turn into an endless
      // halving loop — it has to surface.
      fake.getFailure = (
        status: 422,
        body: <String, Object?>{
          'error': 'ChromaError',
          'message': 'embeddings are not available on this plan',
        },
      );
      await chroma.connect();

      await expectLater(
        chroma.scroll('docs', limit: 500),
        throwsA(
          isA<VectorHttpError>().having(
            (e) => e.message,
            'message',
            contains('embeddings are not available on this plan'),
          ),
        ),
      );
      // Bounded: it stops at the floor instead of retrying down to nothing.
      final attempts = fake.seen.where((r) => r.path.endsWith('/get')).length;
      expect(attempts, lessThanOrEqualTo(6));
    });
  });

  group('reading a page', () {
    test('zips the parallel arrays Chroma answers with', () async {
      await chroma.connect();
      final page = await chroma.scroll('docs', limit: 3);

      expect(page.points.map((p) => p.id), <String>['doc-0', 'doc-1', 'doc-2']);
      expect(page.points[1].vector, <double>[1, 0, 1]);
      expect(page.points[1].payload['n'], 1);
      // The document is the thing the embedding was made from, and the first
      // thing anyone wants on clicking a point.
      expect(page.points[1].payload['chroma:document'], 'text 1');
    });

    test('a short page ends the walk', () async {
      await chroma.connect();
      // The fake never returns more than three, so asking for ten ends it.
      final page = await chroma.scroll('docs', limit: 10);
      expect(page.cursor, isNull);
    });

    test('describe reports the count and the declared width', () async {
      await chroma.connect();
      final info = await chroma.describe('docs');
      expect(info.count, 42);
      expect(info.dimension, 3);
    });
  });

  test('text search asks the server to filter by document', () async {
    await chroma.connect();
    await chroma.searchText('docs', 'invoice', limit: 5);

    final request = fake.seen.lastWhere((r) => r.path.endsWith('/get'));
    final body = request.body! as Map;
    expect(body['where_document'], <String, Object?>{r'$contains': 'invoice'});
  });

  test('an empty text search is not a request for everything', () async {
    await chroma.connect();
    fake.seen.clear();
    expect(await chroma.searchText('docs', '   ', limit: 5), isEmpty);
    expect(fake.seen.where((r) => r.path.endsWith('/get')), isEmpty);
  });
}
