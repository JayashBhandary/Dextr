import Cocoa
import FlutterMacOS

/// Trades security-scoped bookmarks for live access to user-picked files.
///
/// The sandbox grants access to a file the user picks in an open panel, but
/// only for the life of the process. A connection the user saved once and
/// reopens next week therefore cannot be reopened from its path alone — the
/// path is not the permission. A bookmark is: an opaque token the system will
/// redeem later for that same file, wherever it has since moved to.
///
/// Dart owns the storage (the bookmark rides along in the connection record)
/// and this class owns the redemption.
final class FileAccess {
  static let channelName = "dextr/file_access"

  /// URLs whose access is currently held open, keyed by the token handed to
  /// Dart. The URL object itself is what we keep because
  /// `stopAccessingSecurityScopedResource` only balances a `start` call made
  /// on the very same object.
  private var held: [String: URL] = [:]
  private var issued = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    let instance = FileAccess()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "bookmark":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(Self.badArgs("path"))
        return
      }
      result(Self.bookmark(for: URL(fileURLWithPath: path)))

    case "grant":
      guard let encoded = args["bookmark"] as? String,
            let data = Data(base64Encoded: encoded)
      else {
        result(Self.badArgs("bookmark"))
        return
      }
      result(grant(data))

    case "revoke":
      guard let token = args["token"] as? String else {
        result(Self.badArgs("token"))
        return
      }
      held.removeValue(forKey: token)?.stopAccessingSecurityScopedResource()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func badArgs(_ name: String) -> FlutterError {
    FlutterError(code: "BAD_ARGS", message: "\(name) is required", details: nil)
  }

  /// Returns a base64 app-scoped bookmark, or nil if one cannot be made —
  /// which is what happens when the app has no access to `url` to begin with.
  private static func bookmark(for url: URL) -> String? {
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return data.base64EncodedString()
    } catch {
      NSLog("dextr: could not bookmark \(url.path): \(error)")
      return nil
    }
  }

  /// Resolves a bookmark and starts access, returning the path it resolved to
  /// plus the token that later ends that access. Nil when the bookmark no
  /// longer resolves — the file was deleted, or sits on a volume that is gone.
  private func grant(_ data: Data) -> [String: Any]? {
    var stale = false
    let url: URL
    do {
      url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    } catch {
      NSLog("dextr: could not resolve bookmark: \(error)")
      return nil
    }
    guard url.startAccessingSecurityScopedResource() else {
      NSLog("dextr: bookmark resolved to \(url.path) but access was refused")
      return nil
    }
    issued += 1
    let token = "scope-\(issued)"
    held[token] = url
    var payload: [String: Any] = ["token": token, "path": url.path]
    // A stale bookmark still resolves; it just describes a file that has since
    // moved. Mint a replacement now, while access is held, so the record can
    // be corrected instead of leaning on the old one every launch.
    if stale, let refreshed = Self.bookmark(for: url) {
      payload["bookmark"] = refreshed
    }
    return payload
  }
}
