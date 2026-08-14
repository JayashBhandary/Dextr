import 'package:dextr/connectors/mysql/mysql_ssl.dart';
import 'package:dextr/core/hosts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MysqlSslMode.fromConfig', () {
    test('reads the stored mode', () {
      expect(MysqlSslMode.fromConfig('require'), MysqlSslMode.require);
      expect(MysqlSslMode.fromConfig('disable'), MysqlSslMode.disable);
    });

    test('reads the legacy secure bool a previous version wrote', () {
      // A saved connection must keep the transport it had across the upgrade.
      expect(
        MysqlSslMode.fromConfig(null, legacySecure: true),
        MysqlSslMode.require,
      );
      expect(
        MysqlSslMode.fromConfig(null, legacySecure: false),
        MysqlSslMode.disable,
      );
    });

    test('the stored mode wins over a stale legacy bool', () {
      expect(
        MysqlSslMode.fromConfig('require', legacySecure: false),
        MysqlSslMode.require,
      );
    });

    test('an unknown or absent value falls back to the old default', () {
      expect(MysqlSslMode.fromConfig(null), MysqlSslMode.disable);
      expect(MysqlSslMode.fromConfig('verifyFull'), MysqlSslMode.disable);
      expect(MysqlSslMode.fromConfig(42), MysqlSslMode.disable);
    });

    test('there is no mode that claims to verify the certificate', () {
      // The driver accepts any certificate and exposes no way to change that,
      // so a verifying mode here would be a promise the app cannot keep.
      // If this fails, either the driver changed or somebody added a lie.
      expect(MysqlSslMode.values.map((m) => m.name), ['disable', 'require']);
      expect(
        MysqlSslMode.require.description,
        contains('certificate not verified'),
      );
    });
  });

  group('isLocalOrPrivateHost', () {
    test('loopback and link-local names are local', () {
      for (final host in <String>[
        'localhost',
        'LOCALHOST',
        '127.0.0.1',
        '127.1.2.3',
        '::1',
        '[::1]',
        'db.local',
        'mysql.localhost',
      ]) {
        expect(isLocalOrPrivateHost(host), isTrue, reason: host);
      }
    });

    test('RFC 1918 and shared address space are private', () {
      for (final host in <String>[
        '10.0.0.5',
        '192.168.1.20',
        '172.16.0.1',
        '172.31.255.254',
        '169.254.10.1',
        '100.64.0.1',
        'fd00::1',
        'fe80::1',
      ]) {
        expect(isLocalOrPrivateHost(host), isTrue, reason: host);
      }
    });

    test('a socket path never touches the network', () {
      expect(isLocalOrPrivateHost('/tmp/mysql.sock'), isTrue);
    });

    test('public hosts are not local', () {
      for (final host in <String>[
        'db.production.example.com',
        '8.8.8.8',
        '172.32.0.1', // just outside 172.16/12
        '192.169.1.1', // just outside 192.168/16
        '11.0.0.1',
        '2001:4860:4860::8888',
      ]) {
        expect(isLocalOrPrivateHost(host), isFalse, reason: host);
      }
    });

    test('anything unrecognisable is treated as remote', () {
      // Being wrong this way costs a warning nobody needed. The other way
      // costs a silence somebody did.
      expect(isLocalOrPrivateHost(''), isFalse);
      expect(isLocalOrPrivateHost('   '), isFalse);
      expect(isLocalOrPrivateHost('not a host'), isFalse);
    });
  });
}
