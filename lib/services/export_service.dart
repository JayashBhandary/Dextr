import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Where an export ended up.
class ExportOutcome {
  const ExportOutcome({required this.path, required this.bytes});

  /// The absolute path the file was written to. On the web the picker starts a
  /// download and reports no path, so this is the file *name* there.
  final String path;

  /// How much was written, for the message afterwards. "Exported 3,400 rows"
  /// says nothing about whether the file is 4 KB or 400 MB.
  final int bytes;
}

/// Puts an export on disk.
///
/// The unstructured half of exporting, and the last step of the structured
/// half: whatever the format decided, something has to ask the user where the
/// file goes and write the bytes. Kept out of the encoders so those stay pure,
/// and kept out of the panes so the save dialog is asked for the same way
/// everywhere.
///
/// [saveFile] and [pickDirectory] are injected rather than called statically so
/// a test can watch what would have been written without a file picker opening.
class ExportService {
  ExportService({SaveFile? saveFile, PickDirectory? pickDirectory})
    : _saveFile = saveFile ?? _defaultSaveFile,
      _pickDirectory = pickDirectory ?? _defaultPickDirectory;

  final SaveFile _saveFile;
  final PickDirectory _pickDirectory;

  /// Saves text as UTF-8. Null when the user cancelled the dialog.
  ///
  /// [byteOrderMark] prefixes a UTF-8 BOM. For CSV opened in Excel on Windows
  /// and nothing else: without one Excel reads a UTF-8 file as the local code
  /// page and every non-ASCII name arrives as mojibake.
  Future<ExportOutcome?> saveText({
    required String fileName,
    required String text,
    String? dialogTitle,
    bool byteOrderMark = false,
  }) => saveBytes(
    fileName: fileName,
    bytes: Uint8List.fromList(
      utf8.encode(
        byteOrderMark && !text.startsWith(_bom) ? '$_bom$text' : text,
      ),
    ),
    dialogTitle: dialogTitle,
  );

  /// Saves bytes as they are — the unstructured export.
  Future<ExportOutcome?> saveBytes({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  }) async {
    final extension = _filterExtension(fileName);
    final path = await _saveFile(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: dialogTitle ?? 'Export $fileName',
      allowedExtensions: extension == null ? null : <String>[extension],
    );
    if (path == null) return null;
    return ExportOutcome(path: path, bytes: bytes.length);
  }

  /// Asks for a folder, for an export of more than one file.
  ///
  /// A save dialog per object would mean one prompt per file, and the bytes of
  /// an object store's contents must never be buffered in memory first — those
  /// stream straight to disk through the connector.
  Future<String?> chooseFolder({String? dialogTitle}) =>
      _pickDirectory(dialogTitle: dialogTitle);

  /// A file name that says what the export is and when it was taken.
  ///
  /// The timestamp is passed in rather than read from the clock so the name is
  /// a function of its inputs, which is the only way to test it. Second
  /// precision, no colons: a colon is illegal in a Windows file name and
  /// invisible trouble on macOS.
  static String suggestFileName(
    String base,
    String extension, {
    required DateTime at,
  }) {
    final stamp = <String>[
      at.year.toString().padLeft(4, '0'),
      at.month.toString().padLeft(2, '0'),
      at.day.toString().padLeft(2, '0'),
      at.hour.toString().padLeft(2, '0'),
      at.minute.toString().padLeft(2, '0'),
      at.second.toString().padLeft(2, '0'),
    ].join();
    final safe = sanitiseFileName(base);
    return '${safe.isEmpty ? 'export' : safe}-$stamp.$extension';
  }

  /// The extension to narrow the save dialog to, or null for no filter.
  ///
  /// A file name can carry a container or connection name that came from the
  /// server, so the extension is only used as a filter when it is a bare
  /// alphanumeric token. Anything else — a separator, a quote, a space, a
  /// wildcard — is dropped rather than passed down to the platform dialog,
  /// which takes the filter as a list of raw strings. The file still saves; it
  /// just saves without the type filter.
  static String? _filterExtension(String fileName) {
    final extension = p.extension(fileName).replaceFirst('.', '');
    if (!RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(extension)) return null;
    return extension.toLowerCase();
  }

  /// Reduces a container or connection name to something every filesystem
  /// accepts. A qualified name like `public.users` keeps its dot — that is not
  /// an extension and it is the most useful part of the name.
  static String sanitiseFileName(String name) => name
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');

  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) {
    // file_picker only accepts an extension filter alongside FileType.custom,
    // and only accepts FileType.custom with a non-empty filter — asking for
    // either half on its own throws before the dialog ever opens.
    final filtered = allowedExtensions?.isNotEmpty ?? false;
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: dialogTitle,
      type: filtered ? FileType.custom : FileType.any,
      allowedExtensions: filtered ? allowedExtensions : null,
      // The dialog stays in front of the window on Windows; without it the save
      // sheet can end up behind the app and the app looks frozen.
      lockParentWindow: true,
    );
  }

  static Future<String?> _defaultPickDirectory({String? dialogTitle}) =>
      FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle,
        lockParentWindow: true,
      );
}

/// The UTF-8 byte-order mark, as an escape rather than an invisible character.
const _bom = '\uFEFF';

/// The save dialog, as a function so it can be replaced in a test.
typedef SaveFile =
    Future<String?> Function({
      required String fileName,
      required Uint8List bytes,
      String? dialogTitle,
      List<String>? allowedExtensions,
    });

/// The folder dialog, likewise.
typedef PickDirectory = Future<String?> Function({String? dialogTitle});
