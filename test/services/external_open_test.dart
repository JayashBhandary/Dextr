import 'dart:io';
import 'dart:typed_data';

import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/core/files/file_kind.dart';
import 'package:dextr/services/external_open.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late List<String> launched;
  late ExternalOpen opener;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_external_open_test');
    launched = <String>[];
    opener = ExternalOpen(
      temporaryDirectory: tmp,
      launch: (path) async => launched.add(path),
    );
  });

  tearDown(() async => tmp.delete(recursive: true));

  Future<String> open(String name) =>
      opener.open(fileName: name, bytes: Uint8List.fromList(<int>[1, 2, 3]));

  group('names the system opener may be given', () {
    test('a document is written and launched', () async {
      final path = await open('quarterly-report.pdf');

      expect(File(path).existsSync(), isTrue);
      expect(launched, [path]);
      expect(p.basename(path), 'quarterly-report.pdf');
    });

    test('an image is written and launched', () async {
      await open('diagram.PNG');
      expect(launched, hasLength(1));
    });
  });

  group('names it may not', () {
    // One case per platform whose opener would execute the file, because the
    // whole point is that the name arrives from a bucket somebody else writes.
    const dangerous = <String>[
      'report.desktop', // xdg-open runs Exec=
      'invoice.command', // macOS open runs it in Terminal
      'data.bat', // cmd /c start
      'data.cmd',
      'notes.hta', // mshta
      'update.js', // wscript
      'setup.vbs',
      'installer.msi',
      'shortcut.lnk',
      'screensaver.scr',
    ];

    for (final name in dangerous) {
      test('$name is refused', () async {
        await expectLater(open(name), throwsA(isA<UnsupportedError>()));
        expect(launched, isEmpty, reason: 'nothing may be launched');
        expect(
          Directory(p.join(tmp.path, 'dextr-preview')).existsSync(),
          isFalse,
          reason: 'a refused file is not written either',
        );
      });
    }

    test('a double extension is judged on the last one', () async {
      // The trick this defeats: the row reads as a PDF in the listing.
      await expectLater(
        open('Q3-invoice-scan.pdf.desktop'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(launched, isEmpty);
    });

    test('a name with no extension is refused', () async {
      await expectLater(open('object-key'), throwsA(isA<UnsupportedError>()));
      expect(launched, isEmpty);
    });

    test('an extension that only survives sanitisation is still refused',
        () async {
      // sanitiseFileName collapses the spaces; the suffix is what matters.
      await expectLater(
        open('my report .desktop'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(launched, isEmpty);
    });

    test('the refusal says why, and what to do instead', () async {
      await expectLater(
        open('payload.bat'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(contains('.bat'), contains('Download it instead')),
          ),
        ),
      );
    });
  });

  group('path handling', () {
    test('a traversing name cannot escape the preview directory', () async {
      // Sanitisation already handled this; asserted so it stays handled.
      final path = await open('../../../../etc/passwd.pdf');
      expect(p.isWithin(tmp.path, path), isTrue);
      expect(p.basename(path), 'passwd.pdf');
    });
  });

  group('FileKind.canOpenExternally', () {
    FileEntry entry(String name, {bool isFolder = false}) =>
        FileEntry(name: name, path: name, isFolder: isFolder);

    test('agrees with the sink about what is allowed', () {
      expect(FileKind.canOpenExternally(entry('a.pdf')), isTrue);
      expect(FileKind.canOpenExternally(entry('a.desktop')), isFalse);
      expect(FileKind.canOpenExternally(entry('a')), isFalse);
    });

    test('a folder is never openable', () {
      expect(
        FileKind.canOpenExternally(entry('reports.pdf', isFolder: true)),
        isFalse,
      );
    });

    test('the allowlist contains no executable or shortcut suffix', () {
      const never = <String>{
        'desktop', 'command', 'terminal', 'app', 'bat', 'cmd', 'com', 'exe',
        'hta', 'js', 'jse', 'vbs', 'vbe', 'wsf', 'wsh', 'ps1', 'sh', 'zsh',
        'bash', 'msi', 'msp', 'scr', 'lnk', 'url', 'inf', 'reg', 'jar', 'py',
        'rb', 'pl', 'php', 'dll', 'so', 'dylib', 'pkg', 'dmg', 'deb', 'rpm',
        'appimage', 'gadget', 'cpl', 'msc', 'jnlp', 'action', 'workflow',
      };
      expect(FileKind.openableExternally.intersection(never), isEmpty);
    });
  });
}
