/// How a MySQL connection treats transport security.
///
/// Two modes, where Postgres offers three — and the missing one is the point of
/// this file. There is no `verifyFull`, because this application cannot deliver
/// one for MySQL: the bundled driver, `mysql_client 0.0.27`, upgrades the socket
/// with
///
/// ```dart
/// // lib/src/mysql_client/connection.dart:360
/// final secureSocket = await SecureSocket.secure(
///   _socket,
///   onBadCertificate: (certificate) => true,
/// );
/// ```
///
/// — a callback that accepts every certificate it is shown, for any hostname,
/// with no parameter or security context to change it. MySQL's TLS is an upgrade
/// negotiated inside the protocol rather than a plain socket, and the driver
/// neither accepts a socket from outside nor exposes the one it made, so there
/// is nowhere to insert a check. Verifying out of band before connecting would
/// only verify a *different* connection, which an on-path attacker chooses
/// independently — assurance that reads real and is not.
///
/// So the mode is absent rather than aspirational, and [MysqlSslMode.require]
/// says in the user's own view that the certificate is not verified. An option
/// that quietly did not do what its name says is worse than one that is missing:
/// somebody would rely on it.
///
/// Removing this caveat means changing the driver — verified TLS behind a
/// `verifyFull` mode, either from a driver that exposes certificate checking or
/// from a patched fork of this one. See `SECURITY_AUDIT.md`, F-01.
library;

enum MysqlSslMode {
  /// Plain TCP. Credentials and rows cross the network in the clear.
  disable,

  /// TLS, with the server's certificate accepted unchecked.
  ///
  /// Stops a passive observer reading the traffic. Does nothing against an
  /// active one: any self-signed certificate is accepted for any name, so this
  /// does not establish that the server is the server it claims to be.
  require;

  /// Reads the stored value, accepting what earlier versions wrote.
  ///
  /// Before this existed the setting was a `secure` bool, so a record saved by
  /// an older build has that instead. Mapping it here keeps a saved connection
  /// working across the upgrade rather than silently resetting its transport.
  static MysqlSslMode fromConfig(Object? sslMode, {Object? legacySecure}) {
    if (sslMode is String) {
      for (final mode in values) {
        if (mode.name == sslMode) return mode;
      }
    }
    if (legacySecure is bool) {
      return legacySecure ? MysqlSslMode.require : MysqlSslMode.disable;
    }
    // Matches the old default, which was `secure: false`. Changing the default
    // is tracked separately (F-08) and is not a silent side effect of this.
    return MysqlSslMode.disable;
  }

  bool get encrypts => this == MysqlSslMode.require;

  String get label => switch (this) {
    MysqlSslMode.disable => 'disable',
    MysqlSslMode.require => 'require',
  };

  /// What the option says for itself where it is chosen.
  String get description => switch (this) {
    MysqlSslMode.disable =>
      'Plain TCP. For a database on this machine or a network you trust.',
    MysqlSslMode.require =>
      'Encrypted, certificate not verified — it does not prove you reached '
          'the right server.',
  };
}
