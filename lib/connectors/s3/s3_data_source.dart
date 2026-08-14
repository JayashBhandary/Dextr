import 'dart:typed_data';

import 'package:minio/io.dart';
import 'package:minio/minio.dart';

import '../../core/capabilities.dart';
import '../../core/cell_value.dart';
import '../../core/errors.dart';
import '../../core/page.dart';
import '../../core/query_spec.dart';
import '../../domain/connection_record.dart';
import '../../domain/connection_secrets.dart';
import '../data_source.dart';

class S3DataSource extends DataSource with Writable, ObjectStorage, FileBrowsable {
  S3DataSource({required this.record, required this.secrets});

  final ConnectionRecord record;
  final ConnectionSecrets? secrets;
  Minio? _client;

  static const _keyField = 'key';

  @override
  String get id => record.id;
  @override
  String get displayName => record.name;
  @override
  DataSourceKind get kind => DataSourceKind.s3;
  @override
  Set<Capability> get capabilities => const {
        Capability.write,
        Capability.objectStorage,
        Capability.fileBrowse,
      };

  Minio get _open {
    final c = _client;
    if (c == null) throw const ConnectError('Not connected');
    return c;
  }

  @override
  Future<void> connect() async {
    final endpoint = record.config['endpoint'] as String? ?? 'localhost';
    final port = (record.config['port'] as num?)?.toInt();
    final region = record.config['region'] as String? ?? 'us-east-1';
    final useSSL = (record.config['useSSL'] as bool?) ?? true;

    try {
      _client = Minio(
        endPoint: endpoint,
        port: port,
        useSSL: useSSL,
        region: region,
        accessKey: secrets?.accessKeyId ?? '',
        secretKey: secrets?.secretAccessKey ?? '',
        sessionToken: secrets?.sessionToken,
      );
      await ping();
    } catch (e, st) {
      _client = null;
      // Deliberately no retry with SSL inverted. A connection that falls back
      // to plain HTTP puts the access key id, the request signature and — for
      // temporary credentials — the session token on the wire in the clear,
      // and an attacker who can break the handshake would be the one choosing
      // that. The transport is the user's decision, made once, in the form.
      throw ConnectError(
        'S3 connect failed: $e${_hintFor(e, useSSL: useSSL)}',
        cause: e,
        stack: st,
      );
    }
  }

  /// What to add to a connect failure, where the cause is recognisable.
  ///
  /// Split by *kind* of failure, because the two need opposite advice. A
  /// protocol mismatch is a misconfiguration and the fix is the checkbox. A
  /// certificate or handshake failure is a trust failure, and telling somebody
  /// to turn TLS off in response to one is telling them to accept the attack.
  static String _hintFor(Object e, {required bool useSSL}) {
    final s = e.toString().toLowerCase();
    if (_looksLikeCertificateProblem(s)) {
      return ' — the server certificate could not be verified. Do not '
          'continue unless you trust this network: an endpoint that cannot '
          'prove who it is may not be the endpoint you think.';
    }
    if (useSSL && s.contains('wrong version number')) {
      return ' — this endpoint appears to speak plain HTTP rather than HTTPS. '
          'If it is a local MinIO, edit the connection and clear "Use HTTPS".';
    }
    if (!useSSL && _looksLikeHttpsExpected(s)) {
      return ' — this endpoint appears to require HTTPS. Edit the connection '
          'and tick "Use HTTPS".';
    }
    return '';
  }

  static bool _looksLikeCertificateProblem(String lowercased) =>
      lowercased.contains('certificate') ||
      lowercased.contains('handshake') ||
      lowercased.contains('tlsexception') ||
      lowercased.contains('self signed') ||
      lowercased.contains('unable to verify');

  static bool _looksLikeHttpsExpected(String lowercased) =>
      lowercased.contains('http_request') ||
      lowercased.contains('400') ||
      lowercased.contains('plain http request was sent to https');

  @override
  Future<void> disconnect() async {
    _client = null;
  }

  @override
  Future<void> ping() async {
    await _open.listBuckets();
  }

  @override
  Future<void> dispose() => disconnect();

  @override
  Future<List<ContainerRef>> listContainers() async {
    final buckets = await _open.listBuckets();
    return [
      for (final b in buckets) ContainerRef(name: b.name, subtype: 'bucket'),
    ];
  }

  @override
  Future<Page<RowData>> listRows(ContainerRef container, QuerySpec spec) async {
    final out = <RowData>[];
    final stream =
        _open.listObjects(container.name, prefix: '', recursive: true);
    var seen = 0;
    final cap = spec.offset + spec.limit;
    await for (final batch in stream) {
      for (final obj in batch.objects) {
        seen++;
        if (seen <= spec.offset) continue;
        if (out.length >= spec.limit) break;
        out.add(<String, CellValue>{
          _keyField: StringCell(obj.key ?? ''),
          'size': NumCell(obj.size ?? 0),
          'last_modified': obj.lastModified == null
              ? const NullCell()
              : TimestampCell(obj.lastModified!),
          'etag': StringCell(obj.eTag ?? ''),
        });
      }
      if (seen >= cap) break;
    }
    final more = out.length == spec.limit;
    return Page(
      items: out,
      nextCursor: more ? (spec.offset + spec.limit).toString() : null,
    );
  }

  String _keyOf(RowId id) {
    final v = id.fields[_keyField];
    if (v == null) throw const QueryError('Object key missing from RowId');
    return v.display();
  }

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async {
    final key = _keyOf(id);
    try {
      final stat = await _open.statObject(container.name, key);
      return <String, CellValue>{
        _keyField: StringCell(key),
        'size': NumCell(stat.size ?? 0),
        'last_modified': stat.lastModified == null
            ? const NullCell()
            : TimestampCell(stat.lastModified!),
        'etag': StringCell(stat.etag ?? ''),
        'content_type':
            StringCell(stat.metaData?['content-type'] ?? ''),
      };
    } on MinioError {
      return null;
    }
  }

  @override
  Future<RowId> insertRow(
      ContainerRef container, Map<String, CellValue> values) async {
    final keyCell = values[_keyField];
    final pathCell = values['local_path'];
    if (keyCell == null || pathCell == null) {
      throw const QueryError(
          'S3 insert needs `key` and `local_path` values; use the Upload action.');
    }
    final key = keyCell.display();
    final path = pathCell.display();
    await putObjectFromFile(container, key, path);
    return RowId({_keyField: StringCell(key)});
  }

  @override
  Future<int> updateRow(
      ContainerRef container, RowId id, Map<String, CellValue> values) async {
    final path = values['local_path']?.display();
    if (path == null) {
      throw const QueryError(
          'S3 update means replace; provide `local_path` value');
    }
    await putObjectFromFile(container, _keyOf(id), path);
    return 1;
  }

  @override
  Future<int> deleteRow(ContainerRef container, RowId id) async {
    final key = _keyOf(id);
    await _open.removeObject(container.name, key);
    return 1;
  }

  @override
  Future<void> putObjectFromFile(
      ContainerRef container, String key, String localFilePath) async {
    await _open.fPutObject(container.name, key, localFilePath);
  }

  @override
  Future<void> getObjectToFile(
      ContainerRef container, String key, String localFilePath) async {
    await _open.fGetObject(container.name, key, localFilePath);
  }

  @override
  Future<String> presignGet(ContainerRef container, String key,
      {Duration expires = const Duration(hours: 1)}) async {
    return _open.presignedGetObject(container.name, key,
        expires: expires.inSeconds);
  }

  @override
  Future<String> presignPut(ContainerRef container, String key,
      {Duration expires = const Duration(hours: 1)}) async {
    return _open.presignedPutObject(container.name, key,
        expires: expires.inSeconds);
  }

  // --- FileBrowsable --------------------------------------------------------

  @override
  Set<FileOp> get fileOps => FileOp.values.toSet();

  @override
  Future<FileListing> listEntries(ContainerRef container, String path,
      {String? cursor}) async {
    final folders = <FileEntry>[];
    final files = <FileEntry>[];
    final stream = _open.listObjects(container.name, prefix: path);
    await for (final batch in stream) {
      for (final prefix in batch.prefixes) {
        // A common prefix is a sub-folder. name = segment after [path].
        final name = prefix.substring(path.length).replaceAll('/', '');
        if (name.isEmpty) continue;
        folders.add(FileEntry(name: name, path: prefix, isFolder: true));
      }
      for (final obj in batch.objects) {
        final key = obj.key ?? '';
        // Skip the placeholder object for the folder being listed.
        if (key == path || key.isEmpty) continue;
        final name = key.substring(path.length);
        if (name.isEmpty) continue;
        files.add(FileEntry(
          name: name,
          path: key,
          isFolder: false,
          size: obj.size,
          modified: obj.lastModified,
          etag: obj.eTag,
        ));
      }
    }
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return FileListing(entries: [...folders, ...files]);
  }

  @override
  Future<FileEntry?> statEntry(ContainerRef container, String path) async {
    try {
      final stat = await _open.statObject(container.name, path);
      return FileEntry(
        name: path.split('/').where((s) => s.isNotEmpty).last,
        path: path,
        isFolder: false,
        size: stat.size,
        modified: stat.lastModified,
        etag: stat.etag,
        contentType: stat.metaData?['content-type'],
      );
    } on MinioError {
      return null;
    }
  }

  @override
  Future<FileBytes> readBytes(ContainerRef container, String path,
      {int maxBytes = 5 << 20}) async {
    final stat = await _open.statObject(container.name, path);
    final size = stat.size ?? 0;
    final truncated = size > maxBytes;
    final len = size == 0 ? null : (truncated ? maxBytes : size);
    final stream = await _open.getPartialObject(container.name, path, 0, len);
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
    return FileBytes(
      bytes: bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes,
      truncated: truncated,
    );
  }

  @override
  Future<void> uploadFile(
          ContainerRef container, String path, String localFilePath) =>
      putObjectFromFile(container, path, localFilePath);

  @override
  Future<void> downloadFile(
          ContainerRef container, String path, String localFilePath) =>
      getObjectToFile(container, path, localFilePath);

  @override
  Future<void> deleteEntries(ContainerRef container, List<String> paths) async {
    final keys = <String>[];
    for (final path in paths) {
      if (path.endsWith('/')) {
        // Folder: remove every object beneath the prefix, plus the placeholder.
        final all = await _open.listAllObjects(container.name,
            prefix: path, recursive: true);
        keys.addAll(all.objects.map((o) => o.key).whereType<String>());
        keys.add(path);
      } else {
        keys.add(path);
      }
    }
    if (keys.isEmpty) return;
    await _open.removeObjects(container.name, keys);
  }

  @override
  Future<void> createFolder(ContainerRef container, String path) async {
    final key = path.endsWith('/') ? path : '$path/';
    await _open.putObject(
      container.name,
      key,
      Stream<Uint8List>.value(Uint8List(0)),
      size: 0,
    );
  }

  @override
  Future<void> copyEntry(
      ContainerRef container, String from, String to) async {
    final bucket = container.name;
    if (from.endsWith('/')) {
      // Folder: copy every object beneath [from] under the new prefix.
      final dest = to.endsWith('/') ? to : '$to/';
      final all =
          await _open.listAllObjects(bucket, prefix: from, recursive: true);
      for (final obj in all.objects) {
        final key = obj.key;
        if (key == null) continue;
        final rel = key.substring(from.length);
        await _open.copyObject(bucket, '$dest$rel', '$bucket/$key');
      }
    } else {
      await _open.copyObject(bucket, to, '$bucket/$from');
    }
  }

  @override
  Future<void> moveEntry(
      ContainerRef container, String from, String to) async {
    await copyEntry(container, from, to);
    await deleteEntries(container, [from]);
  }

  @override
  Future<String?> shareLink(ContainerRef container, String path,
          {Duration expires = const Duration(hours: 1)}) =>
      presignGet(container, path, expires: expires);
}
