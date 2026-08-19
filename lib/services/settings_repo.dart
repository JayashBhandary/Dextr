import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/app_settings.dart';

/// Persists [AppSettings] to a JSON file in the app support directory.
class SettingsRepo {
  SettingsRepo({this.overridePath});

  final String? overridePath;
  File? _cachedFile;

  Future<File> _file() async {
    if (_cachedFile != null) return _cachedFile!;
    final String dir;
    final ov = overridePath;
    if (ov != null) {
      dir = ov;
    } else {
      final d = await getApplicationSupportDirectory();
      dir = d.path;
    }
    await Directory(dir).create(recursive: true);
    final f = File(p.join(dir, 'settings.json'));
    _cachedFile = f;
    return f;
  }

  Future<AppSettings> load() async {
    final f = await _file();
    if (!await f.exists()) return const AppSettings();
    final raw = await f.readAsString();
    if (raw.trim().isEmpty) return const AppSettings();
    try {
      return AppSettings.decode(raw);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final f = await _file();
    await f.writeAsString(settings.encode());
  }

  /// Removes the settings file, so the next [load] returns the defaults.
  ///
  /// What an application reset calls instead of saving [AppSettings.new]:
  /// writing the defaults back would leave a file on disk where a machine that
  /// has never run Dextr has none.
  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
