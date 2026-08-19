import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/version.dart';

/// What a completed check found.
class UpdateCheck {
  const UpdateCheck({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    this.notes,
  });

  /// What this build reports.
  final String currentVersion;

  /// The newest published release.
  final String latestVersion;

  /// Where that release can be read and downloaded.
  ///
  /// Built here from the tag rather than taken from the response, so no URL out
  /// of a network reply is ever handed to the machine's browser.
  final Uri releaseUrl;

  /// The release's own description, when it published one.
  final String? notes;

  /// Whether the newest release is ahead of this build.
  bool get isUpdateAvailable =>
      isNewerAppVersion(latestVersion, current: currentVersion);
}

/// A check that could not be completed, with a line the user can act on.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the release feed whether there is anything newer than this build.
///
/// Reads only: it reports what is published and where to get it, and it never
/// writes to the installed application. Replacing `/opt/dextr` or
/// `/Applications/Dextr.app` needs the privileges the install scripts ask for,
/// and a GUI process that could elevate itself silently to overwrite its own
/// binary is a worse thing to own than the update it saves. So the last step
/// stays with the user: the release page, and the one-line command that installs
/// it.
class UpdateService {
  UpdateService({
    http.Client? client,
    this.currentVersion = appVersion,
    this.repository = appRepository,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// What to compare against. A parameter so a test does not have to ship a
  /// release to have something newer to find.
  final String currentVersion;

  /// `owner/name` of the repository the releases live in.
  final String repository;

  /// How long to wait before giving up on the feed.
  final Duration timeout;

  /// The newest published release, or a throw explaining why not.
  ///
  /// `releases/latest` is the endpoint on purpose: GitHub excludes drafts and
  /// pre-releases from it, so a tagged release candidate never prompts anybody.
  Future<UpdateCheck> check() async {
    final url = Uri.https(
      'api.github.com',
      '/repos/$repository/releases/latest',
    );

    final http.Response response;
    try {
      response = await _client
          .get(url, headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
            // GitHub rejects an API request with no user agent.
            'User-Agent': 'dextr-update-check',
          })
          .timeout(timeout);
    } on SocketException {
      throw const UpdateException(
        'No network connection, so the release feed could not be reached.',
      );
    } on http.ClientException catch (e) {
      throw UpdateException('The release feed could not be reached: ${e.message}');
    } on Exception {
      throw const UpdateException(
        'The release feed did not answer in time. Try again in a moment.',
      );
    }

    if (response.statusCode == 404) {
      throw const UpdateException(
        'The release feed returned nothing. This build may predate the first '
        'published release.',
      );
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      // Unauthenticated GitHub API calls are limited per address, and a shared
      // office address reaches it without anybody checking sixty times.
      throw const UpdateException(
        'GitHub is rate-limiting this address. Try again later, or open the '
        'releases page in a browser.',
      );
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        'The release feed answered with HTTP ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const UpdateException('The release feed sent something unreadable.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const UpdateException('The release feed sent something unreadable.');
    }

    final tag = decoded['tag_name'];
    if (tag is! String || tag.trim().isEmpty) {
      throw const UpdateException('The newest release has no version tag.');
    }
    // The tag becomes part of a URL the browser is asked to open, so it is held
    // to the characters a git tag is allowed to use rather than trusted because
    // it arrived over TLS. Anything else and the version is still reported — it
    // is only the link that is withheld.
    if (!_safeTag.hasMatch(tag)) {
      throw const UpdateException(
        'The newest release is tagged with something this cannot link to. '
        'Open the releases page in a browser.',
      );
    }

    final notes = decoded['body'];

    return UpdateCheck(
      currentVersion: currentVersion,
      latestVersion: tag,
      releaseUrl: Uri.https('github.com', '/$repository/releases/tag/$tag'),
      notes: notes is String && notes.trim().isNotEmpty ? notes.trim() : null,
    );
  }

  /// The command that installs the newest release on this platform.
  ///
  /// The same one-liner the README documents, so what the settings page offers
  /// and what the project tells people to run are the same thing.
  static String installCommand({String? operatingSystem}) {
    final os = operatingSystem ?? Platform.operatingSystem;
    const raw = 'https://raw.githubusercontent.com/$appRepository/main';
    return os == 'windows'
        ? 'irm $raw/install.ps1 | iex'
        : 'curl -fsSL $raw/install.sh | sh';
  }

  /// Which shell the command above is for, for the label on the block.
  static String installShell({String? operatingSystem}) =>
      (operatingSystem ?? Platform.operatingSystem) == 'windows'
      ? 'powershell'
      : 'sh';

  void dispose() => _client.close();

  /// What a git tag may contain. No slashes, so it cannot walk the URL path.
  static final RegExp _safeTag = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
}
