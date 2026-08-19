import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/files/file_kind.dart';
import '../core/logger.dart';
import '../services/export_service.dart';

/// Hands a file to whatever the operating system opens it with.
///
/// The answer for the formats this application can describe but not draw. A PDF
/// or an MP4 in a bucket is a file somebody wants to *look at*, and the choice
/// is between bundling a renderer for every format anyone might store — pdfium,
/// a video decoder, a font stack — or spending three lines on the viewer already
/// installed on the machine. This is the second option.
///
/// The bytes are written to a temporary file first, because the object is in a
/// bucket and the system viewer can only open a path.
class ExternalOpen {
  ExternalOpen({Launch? launch, Directory? temporaryDirectory})
    : _launch = launch ?? _defaultLaunch,
      // Written out rather than an initialising formal: the pair reads as one
      // decision — how to launch, and where to put the file first.
      // ignore: prefer_initializing_formals
      _temporaryDirectory = temporaryDirectory;

  final Launch _launch;

  /// Where the temporary copy goes. Null means the system's own temp directory;
  /// a test points it somewhere it can delete afterwards.
  final Directory? _temporaryDirectory;

  /// Whether this platform has a documented way to do it.
  ///
  /// False on mobile and the web, where a bare "open this path" does not exist
  /// and the caller should offer a download instead.
  bool get isSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Whether a file of this name may be handed to the system opener at all.
  ///
  /// Exposed so a caller can hide the affordance rather than offer a button
  /// that refuses. [open] checks it again regardless — see there for why.
  static bool canOpen(String fileName) => FileKind.openableExternally
      .contains(FileKind.extensionOf(p.basename(fileName)));

  /// Writes [bytes] somewhere temporary and opens it. Returns the path written.
  ///
  /// The name is sanitised and the file goes in a directory of its own, so an
  /// object called `../../etc/passwd` cannot land anywhere but inside it.
  ///
  /// Throws [UnsupportedError] for a name whose extension is not on
  /// [FileKind.openableExternally].
  Future<String> open({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (!isSupported) {
      throw UnsupportedError(
        'Opening a file in another application is not available on this '
        'platform. Download it instead.',
      );
    }

    final safe = ExportService.sanitiseFileName(p.basename(fileName));

    // Checked here and not only where the button is drawn. The extension is
    // what selects the program that runs, the name comes from whoever put the
    // object in the bucket, and this method is the one place every route to the
    // system opener passes through — so this is where the refusal belongs.
    // Sanitised first, so the check sees the same string the file will be
    // written under rather than the one the store reported.
    final extension = FileKind.extensionOf(safe);
    if (!FileKind.openableExternally.contains(extension)) {
      throw UnsupportedError(
        extension.isEmpty
            ? 'Dextr will not hand a file with no extension to the system '
                  'opener, because the extension is what chooses the program '
                  'that runs. Download it instead, and open it somewhere you '
                  'have decided to trust.'
            : 'Dextr will not hand a .$extension file to the system opener, '
                  'because the extension is what chooses the program that '
                  'runs. Download it instead, and open it somewhere you have '
                  'decided to trust.',
      );
    }

    final root = _temporaryDirectory ?? Directory.systemTemp;
    final directory = await Directory(
      p.join(root.path, 'dextr-preview'),
    ).create(recursive: true);
    final file = File(p.join(directory.path, safe));
    await file.writeAsBytes(bytes, flush: true);

    await _launch(file.path);
    return file.path;
  }

  /// Hands a web address to the machine's browser.
  ///
  /// HTTPS only, and no character a Windows shell would take as an operator: on
  /// Windows the opener *is* a `cmd` builtin, so an `&` in a URL would end the
  /// command and start another one. Every URL this application opens is one it
  /// built itself, and this is the check that keeps that true if one day it is
  /// not.
  Future<void> openUrl(Uri url) async {
    if (!isSupported) {
      throw UnsupportedError(
        'Opening a link in a browser is not available on this platform.',
      );
    }
    if (url.scheme != 'https') {
      throw UnsupportedError(
        'Dextr only opens https links, and this one is ${url.scheme}.',
      );
    }
    final text = url.toString();
    if (_shellOperators.hasMatch(text)) {
      throw UnsupportedError(
        'This link contains a character the system opener would take as a '
        'command, so it will not be opened.',
      );
    }

    await _launch(text);
  }

  /// The characters a Windows `start` invocation would act on rather than pass.
  static final RegExp _shellOperators = RegExp('[&|^<>"\\r\\n]');

  /// The platform's opener, invoked with the path as one argument rather than
  /// through a shell — a file name with a space or a quote in it is common in a
  /// bucket, and a shell would take it apart.
  static Future<void> _defaultLaunch(String path) async {
    final (executable, arguments) = switch (Platform.operatingSystem) {
      'linux' => ('xdg-open', <String>[path]),
      'macos' => ('open', <String>[path]),
      // `start` is a cmd builtin, and the empty string is the window title that
      // `start` would otherwise take the path for.
      _ => ('cmd', <String>['/c', 'start', '', path]),
    };

    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) {
      log.w('$executable exited ${result.exitCode}: ${result.stderr}');
      throw ProcessException(
        executable,
        arguments,
        'Nothing on this machine offered to open the file.',
        result.exitCode,
      );
    }
  }
}

/// Launching, as a function, so a test does not start a PDF viewer.
typedef Launch = Future<void> Function(String path);
