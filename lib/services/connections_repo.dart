import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/connection_record.dart';

class ConnectionsRepo {
  ConnectionsRepo({this.overridePath});

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
    final f = File(p.join(dir, 'connections.json'));
    _cachedFile = f;
    return f;
  }

  Future<List<ConnectionRecord>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    final raw = await f.readAsString();
    if (raw.trim().isEmpty) return [];
    return ConnectionRecord.decodeList(raw);
  }

  Future<void> saveAll(List<ConnectionRecord> records) async {
    final f = await _file();
    await f.writeAsString(ConnectionRecord.encodeList(records));
  }

  Future<List<ConnectionRecord>> upsert(ConnectionRecord record) async {
    final existing = await load();
    final idx = existing.indexWhere((r) => r.id == record.id);
    if (idx >= 0) {
      existing[idx] = record;
    } else {
      existing.add(record);
    }
    await saveAll(existing);
    return existing;
  }

  /// Removes the connections file itself, for an application reset.
  ///
  /// Not `saveAll([])`: an empty file and no file load the same, and the point
  /// of a reset is to leave nothing behind.
  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }

  Future<List<ConnectionRecord>> remove(String id) async {
    final existing = await load();
    existing.removeWhere((r) => r.id == id);
    await saveAll(existing);
    return existing;
  }
}
