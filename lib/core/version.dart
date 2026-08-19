/// This build's version, and how two of them are ordered.
library;

/// The version this build reports.
///
/// Kept beside the code rather than read from the platform's package metadata:
/// the same string has to be available on every desktop target, in a unit test,
/// and in a headless run, and a plugin that answers only on a real device would
/// leave the update check with nothing to compare against. It is duplicated from
/// `pubspec.yaml`, so `test/core/version_test.dart` fails if the two drift.
const String appVersion = '0.1.4';

/// Where this application's releases are published.
///
/// Named here, once, because three places need it — the update check, the
/// release link it offers, and the install command in the settings page — and a
/// repository name typed out three times is a repository name that ends up
/// pointing somewhere else in one of them.
const String appRepository = 'JayashBhandary/dextr';

/// Orders two version strings the way a release feed does.
///
/// Returns a negative number when [a] is older than [b], zero when they are the
/// same release, and a positive number when [a] is newer.
///
/// Deliberately small: it handles `1.2.3`, a `v` prefix, a `+42` build suffix and
/// a `-dev.1` pre-release, which is every shape this project's tags have taken.
/// A pre-release sorts *below* the release of the same numbers — `0.2.0-rc.1` is
/// older than `0.2.0` — because that is the one case where comparing the numbers
/// alone gives the wrong answer, and the wrong answer here is an update prompt
/// that never goes away.
int compareAppVersions(String a, String b) {
  final left = _Version.parse(a);
  final right = _Version.parse(b);
  return left.compareTo(right);
}

/// Whether [candidate] is a release this build should offer to move to.
bool isNewerAppVersion(String candidate, {String current = appVersion}) =>
    compareAppVersions(candidate, current) > 0;

class _Version implements Comparable<_Version> {
  const _Version(this.numbers, this.preRelease);

  /// The dotted numbers, most significant first.
  final List<int> numbers;

  /// The `-…` part, or empty for a plain release.
  final String preRelease;

  static _Version parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);

    // Build metadata says nothing about order — `1.0.0+5` and `1.0.0+9` are the
    // same release built twice.
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);

    final dash = text.indexOf('-');
    final preRelease = dash >= 0 ? text.substring(dash + 1) : '';
    if (dash >= 0) text = text.substring(0, dash);

    // A segment that is not a number counts as zero rather than throwing: a tag
    // nobody expected must not be able to break the update check, and treating
    // it as the oldest possible version means the worst case is no prompt.
    final numbers = text
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList();

    return _Version(numbers, preRelease);
  }

  @override
  int compareTo(_Version other) {
    final length = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var i = 0; i < length; i++) {
      // A missing segment is a zero, so `1.2` and `1.2.0` are the same release.
      final mine = i < numbers.length ? numbers[i] : 0;
      final theirs = i < other.numbers.length ? other.numbers[i] : 0;
      if (mine != theirs) return mine.compareTo(theirs);
    }

    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    // Two pre-releases of the same numbers: alphabetical is what `rc.1` before
    // `rc.2` needs, and no tag this project has used needs more than that.
    return preRelease.compareTo(other.preRelease);
  }
}
