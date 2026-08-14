import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';

/// What kind of thing a file in an object store is, and what can be done with
/// it without leaving the application.
///
/// One classification, in one place. The browser used to carry two sets of
/// extensions — one for "is this an image", one for "is this text" — and
/// anything outside both fell into a single "no preview" case. Adding a format
/// meant adding a set and remembering every `if` that had to learn about it.
enum FileKind {
  /// A picture Flutter can decode.
  image,

  /// Anything whose bytes are meant to be read as text.
  text,

  /// Text arranged in rows and columns: CSV, TSV.
  delimited,

  /// A spreadsheet workbook — `.xlsx`. Read as a table.
  spreadsheet,

  /// A word-processing document — `.docx`. Read as its paragraphs.
  document,

  /// A PDF. Its facts are readable here; drawing its pages is not.
  pdf,

  /// A video container.
  video,

  /// An audio container.
  audio,

  /// A zip, tar or similar.
  archive,

  /// Bytes with no known shape.
  binary;

  /// Which kind [entry] is.
  ///
  /// Extension first, content type second. A store's reported content type is
  /// wrong often enough — `application/octet-stream` on everything is the
  /// classic — that the name is the better evidence when the two disagree.
  static FileKind of(FileEntry entry) {
    if (entry.isFolder) return FileKind.binary;
    final byExtension = _byExtension[extensionOf(entry.name)];
    if (byExtension != null) return byExtension;
    return _byContentType(entry.contentType);
  }

  /// The extension, lower-cased and without the dot.
  static String extensionOf(String name) =>
      p.extension(name).toLowerCase().replaceFirst('.', '');

  /// Extensions this application will hand to the operating system's opener.
  ///
  /// Documents and media, and nothing else. On every desktop it is the
  /// *extension* that chooses the program: `xdg-open` runs a `.desktop` file's
  /// `Exec=` line, `open` runs a `.command`, and `cmd /c start` runs `.bat`,
  /// `.cmd`, `.hta`, `.js`, `.vbs` and the rest. An object in a bucket is named
  /// by whoever put it there, so an unconstrained extension turns "look at this
  /// file" into "run this file".
  ///
  /// An allowlist rather than a blocklist, because the set of suffixes some
  /// platform treats as executable is not knowable from here, and a preview
  /// that refuses an unusual-but-harmless format costs one download.
  static const Set<String> openableExternally = <String>{
    // Documents
    'pdf', 'docx', 'xlsx', 'xlsm', 'csv', 'tsv', 'txt', 'md', 'json', 'log',
    // Images
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
    // Video
    'mp4', 'm4v', 'mov', 'webm', 'mkv',
    // Audio
    'mp3', 'm4a', 'wav', 'flac', 'ogg',
  };

  /// Whether [entry] may be handed to the system opener.
  ///
  /// Reads the name rather than the reported content type on purpose: a store
  /// answers `application/octet-stream` for everything, and the opener is going
  /// to go by the name regardless of what the metadata claimed. A name with no
  /// extension at all fails this, which is the safe way round.
  static bool canOpenExternally(FileEntry entry) =>
      !entry.isFolder && openableExternally.contains(extensionOf(entry.name));

  static FileKind _byContentType(String? contentType) {
    final type = contentType?.toLowerCase() ?? '';
    if (type.startsWith('image/')) return FileKind.image;
    if (type.startsWith('video/')) return FileKind.video;
    if (type.startsWith('audio/')) return FileKind.audio;
    if (type == 'application/pdf') return FileKind.pdf;
    if (type == 'text/csv' || type == 'text/tab-separated-values') {
      return FileKind.delimited;
    }
    if (type.startsWith('text/') ||
        type == 'application/json' ||
        type == 'application/xml') {
      return FileKind.text;
    }
    return FileKind.binary;
  }

  /// What this kind is called, for a badge beside the file's name.
  String get label => switch (this) {
    FileKind.image => 'image',
    FileKind.text => 'text',
    FileKind.delimited => 'table',
    FileKind.spreadsheet => 'spreadsheet',
    FileKind.document => 'document',
    FileKind.pdf => 'PDF',
    FileKind.video => 'video',
    FileKind.audio => 'audio',
    FileKind.archive => 'archive',
    FileKind.binary => 'binary',
  };

  /// Whether this application can show the *content* rather than only facts
  /// about it.
  bool get hasInlinePreview => switch (this) {
    FileKind.image ||
    FileKind.text ||
    FileKind.delimited ||
    FileKind.spreadsheet ||
    FileKind.document => true,
    FileKind.pdf ||
    FileKind.video ||
    FileKind.audio ||
    FileKind.archive ||
    FileKind.binary => false,
  };

  /// Whether a partial read is useless.
  ///
  /// A zip keeps its index at the end and an MP4 may keep its header there, so
  /// the first few megabytes of one are not the beginning of anything. Text and
  /// images degrade gracefully; these do not.
  bool get needsWholeFile => switch (this) {
    FileKind.spreadsheet ||
    FileKind.document ||
    FileKind.archive => true,
    // A media header is usually at the front, and where it is not the reader
    // says what it could not find rather than refusing to fetch anything.
    FileKind.video ||
    FileKind.audio ||
    FileKind.pdf ||
    FileKind.image ||
    FileKind.text ||
    FileKind.delimited ||
    FileKind.binary => false,
  };

  /// How much of the object to fetch for a preview.
  ///
  /// Chosen per kind rather than one number for everything: two megabytes of a
  /// CSV is thousands of rows and nobody reads past the first screen, while two
  /// megabytes of a `.xlsx` is not a `.xlsx` at all.
  int get previewByteLimit => switch (this) {
    FileKind.text || FileKind.delimited => 2 << 20,
    FileKind.image => 8 << 20,
    FileKind.spreadsheet || FileKind.document => 32 << 20,
    // Only the head is read, and only to find the metadata boxes in it.
    FileKind.video || FileKind.audio || FileKind.pdf => 4 << 20,
    FileKind.archive || FileKind.binary => 1 << 20,
  };

  static const Map<String, FileKind> _byExtension = <String, FileKind>{
    // Images
    'png': FileKind.image,
    'jpg': FileKind.image,
    'jpeg': FileKind.image,
    'gif': FileKind.image,
    'webp': FileKind.image,
    'bmp': FileKind.image,
    // Tables
    'csv': FileKind.delimited,
    'tsv': FileKind.delimited,
    // Office
    'xlsx': FileKind.spreadsheet,
    'xlsm': FileKind.spreadsheet,
    'docx': FileKind.document,
    'pdf': FileKind.pdf,
    // Media
    'mp4': FileKind.video,
    'm4v': FileKind.video,
    'mov': FileKind.video,
    'webm': FileKind.video,
    'mkv': FileKind.video,
    'mp3': FileKind.audio,
    'm4a': FileKind.audio,
    'wav': FileKind.audio,
    'flac': FileKind.audio,
    'ogg': FileKind.audio,
    // Archives
    'zip': FileKind.archive,
    'gz': FileKind.archive,
    'tar': FileKind.archive,
    'tgz': FileKind.archive,
    'bz2': FileKind.archive,
    '7z': FileKind.archive,
    'rar': FileKind.archive,
    // Text
    'txt': FileKind.text,
    'json': FileKind.text,
    'jsonl': FileKind.text,
    'md': FileKind.text,
    'log': FileKind.text,
    'yaml': FileKind.text,
    'yml': FileKind.text,
    'xml': FileKind.text,
    'html': FileKind.text,
    'htm': FileKind.text,
    'dart': FileKind.text,
    'js': FileKind.text,
    'ts': FileKind.text,
    'jsx': FileKind.text,
    'tsx': FileKind.text,
    'py': FileKind.text,
    'java': FileKind.text,
    'c': FileKind.text,
    'cpp': FileKind.text,
    'h': FileKind.text,
    'hpp': FileKind.text,
    'go': FileKind.text,
    'rs': FileKind.text,
    'rb': FileKind.text,
    'sh': FileKind.text,
    'sql': FileKind.text,
    'ini': FileKind.text,
    'toml': FileKind.text,
    'conf': FileKind.text,
    'env': FileKind.text,
    'css': FileKind.text,
  };
}

/// A byte count as a person reads it.
///
/// Binary multiples, because that is what an object store reports and what every
/// other tool beside this one will say about the same file.
String humanFileSize(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
