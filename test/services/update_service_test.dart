import 'dart:convert';

import 'package:dextr/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the update check reports, and what it refuses to.
///
/// The refusals are the point of most of these: the reply comes off the network,
/// and one field of it ends up in a URL the machine's browser is asked to open.
void main() {
  /// A feed that answers every request with [body] and [status].
  ///
  /// Records the request too, because "asked the right endpoint with a user
  /// agent" is part of what has to hold — GitHub rejects a call without one.
  ({UpdateService service, List<http.Request> asked}) feed(
    String body, {
    int status = 200,
    String currentVersion = '0.1.4',
  }) {
    final asked = <http.Request>[];
    final client = MockClient((request) async {
      asked.add(request);
      return http.Response(
        body,
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    return (
      service: UpdateService(client: client, currentVersion: currentVersion),
      asked: asked,
    );
  }

  String release(String tag, {String? body}) => jsonEncode(<String, Object?>{
    'tag_name': tag,
    'body': body,
    // Present in a real reply and deliberately unused: the URL that gets opened
    // is built from the tag instead. A test that fed a hostile one is below.
    'html_url': 'https://evil.example.com/pwned',
  });

  test('reports a newer release as available', () async {
    final f = feed(release('v0.2.0', body: 'Faster vectors.'));

    final check = await f.service.check();

    expect(check.latestVersion, 'v0.2.0');
    expect(check.currentVersion, '0.1.4');
    expect(check.isUpdateAvailable, isTrue);
    expect(check.notes, 'Faster vectors.');
    expect(
      f.asked.single.url.toString(),
      'https://api.github.com/repos/JayashBhandary/dextr/releases/latest',
    );
    expect(f.asked.single.headers['User-Agent'], isNotEmpty);
  });

  test('the release link is built from the tag, never taken from the reply',
      () async {
    // The reply above carries an `html_url` pointing somewhere else entirely.
    // Opening that is handing a URL from the network to the user's browser.
    final check = await feed(release('v0.2.0')).service.check();

    expect(
      check.releaseUrl.toString(),
      'https://github.com/JayashBhandary/dextr/releases/tag/v0.2.0',
    );
  });

  test('the same and older releases are not offered', () async {
    expect(
      (await feed(release('v0.1.4')).service.check()).isUpdateAvailable,
      isFalse,
    );
    expect(
      (await feed(release('v0.1.3')).service.check()).isUpdateAvailable,
      isFalse,
    );
  });

  test('a tag that could reshape the URL is refused', () async {
    // A slash would walk the path; the version is worth nothing if the link
    // beside it goes somewhere else.
    for (final tag in <String>[
      '../../evil',
      'v1.0.0/../../../attacker',
      'v1 0',
      '',
    ]) {
      await expectLater(
        feed(release(tag)).service.check(),
        throwsA(isA<UpdateException>()),
        reason: 'accepted the tag "$tag"',
      );
    }
  });

  test('rate limiting says so rather than reading as no update', () async {
    await expectLater(
      feed('{}', status: 403).service.check(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('rate-limiting'),
        ),
      ),
    );
  });

  test('a missing feed, a server error and nonsense all explain themselves',
      () async {
    await expectLater(
      feed('{}', status: 404).service.check(),
      throwsA(isA<UpdateException>()),
    );
    await expectLater(
      feed('{}', status: 500).service.check(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('500'),
        ),
      ),
    );
    await expectLater(
      feed('<html>not json</html>').service.check(),
      throwsA(isA<UpdateException>()),
    );
    await expectLater(
      feed('[]').service.check(),
      throwsA(isA<UpdateException>()),
    );
    await expectLater(
      feed('{"tag_name": 7}').service.check(),
      throwsA(isA<UpdateException>()),
    );
  });

  test('an unreachable feed is reported, not thrown raw', () async {
    final service = UpdateService(
      client: MockClient(
        (_) async => throw http.ClientException('Connection refused'),
      ),
    );

    await expectLater(
      service.check(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('could not be reached'),
        ),
      ),
    );
  });

  test('the install command is the one the installers document', () {
    expect(
      UpdateService.installCommand(operatingSystem: 'linux'),
      'curl -fsSL '
      'https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.sh '
      '| sh',
    );
    expect(
      UpdateService.installCommand(operatingSystem: 'macos'),
      contains('install.sh'),
    );
    expect(
      UpdateService.installCommand(operatingSystem: 'windows'),
      'irm '
      'https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.ps1 '
      '| iex',
    );
    expect(UpdateService.installShell(operatingSystem: 'windows'), 'powershell');
    expect(UpdateService.installShell(operatingSystem: 'linux'), 'sh');
  });
}
