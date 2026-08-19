import 'dart:io';

import 'package:dextr/core/version.dart';
import 'package:flutter_test/flutter_test.dart';

/// The version constant, and the ordering the update check relies on.
void main() {
  test('appVersion matches the version in pubspec.yaml', () {
    // The one thing that can silently rot: a release bumps pubspec and the
    // settings page keeps reporting the version before it, which also means the
    // update check compares against the wrong build and stops offering the
    // release the user is missing.
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final line = pubspec.firstWhere((l) => l.startsWith('version:'));
    final declared = line.split(':')[1].trim().split('+').first;

    expect(
      appVersion,
      declared,
      reason:
          'lib/core/version.dart says $appVersion and pubspec.yaml says '
          '$declared — bump both.',
    );
  });

  test('the repository is the one the installers download from', () {
    // Both install scripts hard-code it, and a mismatch here would point the
    // update check and its link at a repository the installer never uses.
    for (final script in <String>['install.sh', 'install.ps1']) {
      expect(
        File(script).readAsStringSync(),
        contains(appRepository),
        reason: '$script does not mention $appRepository',
      );
    }
  });

  group('compareAppVersions', () {
    test('orders by number, most significant first', () {
      expect(compareAppVersions('0.2.0', '0.1.9'), isPositive);
      expect(compareAppVersions('0.1.9', '0.2.0'), isNegative);
      expect(compareAppVersions('1.0.0', '0.99.99'), isPositive);
      expect(compareAppVersions('0.1.4', '0.1.4'), isZero);
    });

    test('ignores a v prefix and a build suffix', () {
      expect(compareAppVersions('v0.1.5', '0.1.4'), isPositive);
      expect(compareAppVersions('V0.1.4', 'v0.1.4'), isZero);
      // A rebuild of the same release is the same release.
      expect(compareAppVersions('0.1.4+7', '0.1.4+2'), isZero);
    });

    test('a missing segment is a zero', () {
      expect(compareAppVersions('0.2', '0.2.0'), isZero);
      expect(compareAppVersions('1', '1.0.0'), isZero);
      expect(compareAppVersions('0.2.1', '0.2'), isPositive);
    });

    test('a pre-release sorts below the release of the same numbers', () {
      // The case that matters: without it, 0.2.0-rc.1 reads as newer than
      // 0.2.0 and the prompt to update never goes away.
      expect(compareAppVersions('0.2.0-rc.1', '0.2.0'), isNegative);
      expect(compareAppVersions('0.2.0', '0.2.0-rc.1'), isPositive);
      expect(compareAppVersions('0.2.0-rc.2', '0.2.0-rc.1'), isPositive);
      expect(compareAppVersions('0.2.0-rc.1', '0.1.9'), isPositive);
    });

    test('a tag nobody expected does not throw', () {
      // Treated as the oldest thing there is, so the worst case is no prompt
      // rather than a crash on the settings page.
      expect(compareAppVersions('nightly', '0.1.4'), isNegative);
      expect(isNewerAppVersion('nightly', current: '0.1.4'), isFalse);
    });
  });

  test('isNewerAppVersion answers the question the page asks', () {
    expect(isNewerAppVersion('0.1.5', current: '0.1.4'), isTrue);
    expect(isNewerAppVersion('0.1.4', current: '0.1.4'), isFalse);
    expect(isNewerAppVersion('0.1.3', current: '0.1.4'), isFalse);
  });
}
