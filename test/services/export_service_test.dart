import 'dart:convert';
import 'dart:typed_data';

import 'package:dextr/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The last step of every export: the name it is offered under, and the bytes
/// that reach the picker.
void main() {
  group('the file name', () {
    final at = DateTime(2026, 8, 14, 9, 5, 3);

    test('says what was exported and when, to the second', () {
      expect(
        ExportService.suggestFileName('tracks', 'csv', at: at),
        'tracks-20260814090503.csv',
      );
    });

    test('keeps the dot of a qualified name, which is not an extension', () {
      expect(
        ExportService.suggestFileName('public.users', 'json', at: at),
        'public.users-20260814090503.json',
      );
    });

    test('replaces what a filesystem will not take', () {
      expect(
        ExportService.sanitiseFileName('my bucket/prefix:v2'),
        'my-bucket-prefix-v2',
      );
      // A colon is illegal on Windows and trouble on macOS, and a slash would
      // silently write into another directory.
      expect(ExportService.sanitiseFileName('a/b'), contains('-'));
      expect(ExportService.sanitiseFileName('a/b'), isNot(contains('/')));
    });

    test('never produces a name that is only punctuation', () {
      expect(
        ExportService.suggestFileName('///', 'csv', at: at),
        'export-20260814090503.csv',
      );
    });
  });

  group('saving', () {
    late String? name;
    late Uint8List? written;
    late List<String>? extensions;
    late String? result;

    ExportService service() => ExportService(
      saveFile: ({
        required String fileName,
        required Uint8List bytes,
        String? dialogTitle,
        List<String>? allowedExtensions,
      }) async {
        name = fileName;
        written = bytes;
        extensions = allowedExtensions;
        return result;
      },
    );

    setUp(() {
      name = null;
      written = null;
      extensions = null;
      result = '/tmp/out.csv';
    });

    test('text goes to the picker as UTF-8, with the extension offered', () async {
      final outcome = await service().saveText(
        fileName: 'rows.csv',
        text: 'a,b\nné,2\n',
      );

      expect(name, 'rows.csv');
      expect(extensions, <String>['csv']);
      expect(utf8.decode(written!), 'a,b\nné,2\n');
      expect(outcome!.path, '/tmp/out.csv');
      // The size is the encoded length, not the character count: 'né' is three
      // bytes, and a message that said otherwise would be wrong.
      expect(outcome.bytes, utf8.encode('a,b\nné,2\n').length);
    });

    test('a byte-order mark is added once, never twice', () async {
      await service().saveText(
        fileName: 'rows.csv',
        text: 'a\n',
        byteOrderMark: true,
      );
      final once = written!;
      expect(once.take(3), <int>[0xEF, 0xBB, 0xBF]);

      await service().saveText(
        fileName: 'rows.csv',
        text: utf8.decode(once),
        byteOrderMark: true,
      );
      expect(written, once);
    });

    test('a cancelled dialog is null rather than an empty file', () async {
      result = null;

      expect(
        await service().saveText(fileName: 'rows.csv', text: 'a\n'),
        isNull,
      );
      // The bytes were still handed over — the picker is what declined — so the
      // caller must go by the return value and not by "did anything happen".
      expect(written, isNotNull);
    });

    test('bytes are passed through untouched', () async {
      final bytes = Uint8List.fromList(<int>[0, 255, 16]);

      final outcome = await service().saveBytes(
        fileName: 'blob.bin',
        bytes: bytes,
      );

      expect(written, bytes);
      expect(extensions, <String>['bin']);
      expect(outcome!.bytes, 3);
    });

    test('a name with no extension offers no filter rather than an empty one', () async {
      await service().saveBytes(
        fileName: 'noextension',
        bytes: Uint8List(0),
      );

      expect(extensions, isNull);
    });

    test('choosing a folder returns what the picker said', () async {
      final chosen = await ExportService(
        pickDirectory: ({String? dialogTitle}) async => '/tmp/dir',
      ).chooseFolder();

      expect(chosen, '/tmp/dir');
    });
  });
}
