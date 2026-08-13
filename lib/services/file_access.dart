import 'dart:io';

import 'package:flutter/services.dart';

import '../core/logger.dart';

/// Live access to a user-picked file, and the token that gives it back.
class FileGrant {
  const FileGrant({required this.token, required this.path, this.bookmark});

  /// Hand to [FileAccess.revoke] when done with the file.
  final String token;

  /// Where the file is *now* — not necessarily where it was when picked.
  final String path;

  /// A replacement bookmark, present only when the stored one had gone stale
  /// because the file moved. Worth persisting when it appears.
  final String? bookmark;
}

/// Keeps user-picked files reachable across launches on sandboxed macOS.
///
/// The open panel grants access to the file the user chose, but the grant dies
/// with the process: a path saved today is just a string tomorrow, and opening
/// it fails with a permission error. The sandbox's answer is a bookmark — an
/// opaque token the system redeems later for the same file — so a saved
/// connection stores one alongside its path and redeems it before connecting.
///
/// Everywhere else (Linux, Windows, tests) paths are permission enough, so the
/// whole class degrades to no-ops and callers fall back to the stored path.
class FileAccess {
  FileAccess({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('dextr/file_access');

  static final FileAccess instance = FileAccess();

  final MethodChannel _channel;

  /// Config keys a connection record uses for a picked file. Kept here so the
  /// forms that write them and the connectors that read them cannot drift.
  static const String pathKey = 'filePath';
  static const String bookmarkKey = 'fileBookmark';

  /// Whether bookmarks mean anything on this platform. An instance getter
  /// rather than a static one so a fake can answer for a platform the test is
  /// not running on.
  bool get isSupported => Platform.isMacOS;

  /// Mints a bookmark for a file the user just picked, while access is still
  /// held. Null when the platform has no need for one, or when the file cannot
  /// be bookmarked — callers treat that as "path only" rather than an error.
  Future<String?> bookmark(String path) async {
    if (!isSupported || path.isEmpty) return null;
    try {
      return await _channel.invokeMethod<String>('bookmark', {'path': path});
    } on PlatformException catch (e) {
      log.w('Could not bookmark $path: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Redeems [bookmark] for access to the file it points at. Null when the
  /// bookmark no longer resolves — deleted file, ejected volume — which is the
  /// caller's cue to ask the user to pick it again.
  Future<FileGrant?> grant(String bookmark) async {
    if (!isSupported || bookmark.isEmpty) return null;
    try {
      final res = await _channel.invokeMapMethod<String, Object?>(
        'grant',
        {'bookmark': bookmark},
      );
      if (res == null) return null;
      return FileGrant(
        token: res['token']! as String,
        path: res['path']! as String,
        bookmark: res['bookmark'] as String?,
      );
    } on PlatformException catch (e) {
      log.w('Could not redeem bookmark: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Releases a grant. Safe to call with a token that has already been
  /// released, and cheap enough to call from a `finally`.
  Future<void> revoke(String? token) async {
    if (token == null || !isSupported) return;
    try {
      await _channel.invokeMethod<void>('revoke', {'token': token});
    } on PlatformException catch (e) {
      log.w('Could not release file access $token: ${e.message}');
    } on MissingPluginException {
      // Nothing was ever held.
    }
  }
}
