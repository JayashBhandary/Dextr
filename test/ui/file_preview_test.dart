import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dextr/app.dart';
import 'package:dextr/connectors/data_source.dart';
import 'package:dextr/core/capabilities.dart';
import 'package:dextr/core/cell_value.dart';
import 'package:dextr/core/page.dart' as core;
import 'package:dextr/core/query_spec.dart';
import 'package:dextr/domain/connection_record.dart';
import 'package:dextr/domain/connection_secrets.dart';
import 'package:dextr/router.dart';
import 'package:dextr/services/connections_repo.dart';
import 'package:dextr/services/external_open.dart';
import 'package:dextr/services/secrets_store.dart';
import 'package:dextr/services/settings_repo.dart';
import 'package:dextr/state/active_source_provider.dart';
import 'package:dextr/state/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Previewing the formats a bucket actually holds.
///
/// The parsers have their own tests; these check that the dialog picks the right
/// one, draws it, and says something true when it cannot draw anything — which
/// is the part a unit test of a parser cannot see.
void main() {
  late Directory tmp;
  late List<String> opened;

  final record = ConnectionRecord(
    id: 's3-1',
    name: 'assets',
    kind: DataSourceKind.s3,
    config: <String, Object?>{'endpoint': 's3.example.com'},
    secretsRef: 'none',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dextr_preview_test');
    opened = <String>[];
    await ConnectionsRepo(overridePath: tmp.path).upsert(record);
  });

  tearDown(() async => tmp.delete(recursive: true));

  ProviderScope app() => ProviderScope(
    overrides: [
      connectionsRepoProvider.overrideWithValue(
        ConnectionsRepo(overridePath: tmp.path),
      ),
      settingsRepoProvider.overrideWithValue(
        SettingsRepo(overridePath: tmp.path),
      ),
      secretsStoreProvider.overrideWithValue(_NoSecrets()),
      activeDataSourceProvider.overrideWith((ref) async => _FakeStore(record)),
      // Nothing on the machine is launched, and the temporary copy lands
      // somewhere the test deletes.
      externalOpenProvider.overrideWithValue(
        ExternalOpen(
          launch: (path) async => opened.add(path),
          temporaryDirectory: tmp,
        ),
      ),
      routerProvider.overrideWith((ref) => buildRouter()),
    ],
    child: const DextrApp(),
  );

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  /// Opens the bucket and presses one file, which is what opens the preview.
  Future<void> preview(WidgetTester tester, String name) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('assets').first);
    await settle(tester);
    await tester.tap(find.text('uploads').first);
    await settle(tester);
    await tester.tap(find.text(name));
    await settle(tester);
  }

  testWidgets('a CSV is drawn as a table, not as text', (tester) async {
    await preview(tester, 'orders.csv');

    // The header row became the table's columns.
    expect(find.text('id'), findsWidgets);
    expect(find.text('customer'), findsWidgets);
    // The quoted value with a comma in it is one cell, whole.
    expect(find.text('Ford, Betty'), findsOneWidget);
    // And the facts say how it was read, including the separator it guessed.
    expect(find.text('comma'), findsOneWidget);
    expect(find.text('table'), findsWidgets);
  });

  testWidgets('a spreadsheet is drawn as a table, with a sheet to choose', (
    tester,
  ) async {
    await preview(tester, 'books.xlsx');

    expect(find.text('spreadsheet'), findsWidgets);
    // Two sheets, so there is a choice, and the first one is showing.
    expect(find.text('Titles'), findsWidgets);
    expect(find.text('Dune'), findsOneWidget);

    // The other sheet's content is not on screen until it is picked.
    expect(find.text('Paris'), findsNothing);
    await tester.tap(find.text('Titles').last);
    await settle(tester);
    await tester.tap(find.text('Places').last);
    await settle(tester);

    expect(find.text('Paris'), findsOneWidget);
    expect(find.text('Dune'), findsNothing);
  });

  testWidgets('a document is drawn as its paragraphs', (tester) async {
    await preview(tester, 'notes.docx');

    expect(find.text('document'), findsWidgets);
    expect(find.text('The first paragraph.'), findsOneWidget);
    expect(find.text('And the second.'), findsOneWidget);
    // Counted, because that is the useful fact about a wall of text.
    expect(find.text('Words'), findsOneWidget);
  });

  testWidgets('a PDF reports what it says about itself and offers a viewer', (
    tester,
  ) async {
    await preview(tester, 'contract.pdf');

    // No page is drawn, and the dialog says why in so many words.
    expect(find.text('No page preview'), findsOneWidget);
    // The facts that were read out of the file are real.
    expect(find.text('PDF version'), findsOneWidget);
    expect(find.text('1.7'), findsOneWidget);
    expect(find.text('encrypted'), findsOneWidget);

    // And the way to actually see it: the machine's own viewer.
    await tester.tap(find.text('Open externally'));
    await settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single, endsWith('contract.pdf'));
    expect(File(opened.single).existsSync(), isTrue);
  });

  testWidgets('an MP4 reports its duration and size without a player', (
    tester,
  ) async {
    await preview(tester, 'clip.mp4');

    expect(find.text('No player here'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
  });

  testWidgets('a spreadsheet too large to read whole says so instead', (
    tester,
  ) async {
    await preview(tester, 'huge.xlsx');

    expect(find.text('Too large to preview here'), findsOneWidget);
    // It did not try: half a zip is not a zip.
    expect(find.textContaining('Download it instead'), findsOneWidget);
  });
}

/// An object store holding one of each format worth previewing.
class _FakeStore extends DataSource with FileBrowsable {
  _FakeStore(this.record);

  final ConnectionRecord record;

  @override
  String get id => record.id;

  @override
  String get displayName => record.name;

  @override
  DataSourceKind get kind => DataSourceKind.s3;

  @override
  Set<Capability> get capabilities => <Capability>{Capability.fileBrowse};

  @override
  Set<FileOp> get fileOps => FileOp.values.toSet();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> ping() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<ContainerRef>> listContainers() async => const <ContainerRef>[
    ContainerRef(name: 'uploads', subtype: 'bucket'),
  ];

  @override
  Future<core.Page<RowData>> listRows(
    ContainerRef container,
    QuerySpec spec,
  ) async => const core.Page<RowData>(items: <RowData>[]);

  @override
  Future<RowData?> getRow(ContainerRef container, RowId id) async => null;

  @override
  Future<FileListing> listEntries(
    ContainerRef container,
    String path, {
    String? cursor,
  }) async => FileListing(
    entries: <FileEntry>[
      for (final entry in _files.entries)
        FileEntry(
          name: entry.key,
          path: entry.key,
          isFolder: false,
          size: entry.value.length,
          modified: DateTime.utc(2026, 5, 1),
        ),
      // Declared far larger than it is: the preview must decide from the size
      // rather than by fetching and failing.
      const FileEntry(
        name: 'huge.xlsx',
        path: 'huge.xlsx',
        isFolder: false,
        size: 200 << 20,
      ),
    ],
  );

  @override
  Future<FileEntry?> statEntry(ContainerRef container, String path) async =>
      null;

  @override
  Future<FileBytes> readBytes(
    ContainerRef container,
    String path, {
    int maxBytes = 5 << 20,
  }) async {
    final bytes = _files[path];
    if (bytes == null) throw StateError('No such object: $path');
    return FileBytes(
      bytes: bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes,
      truncated: bytes.length > maxBytes,
    );
  }

  @override
  Future<void> uploadFile(
    ContainerRef container,
    String path,
    String localFilePath,
  ) async {}

  @override
  Future<void> downloadFile(
    ContainerRef container,
    String path,
    String localFilePath,
  ) async {}

  @override
  Future<void> deleteEntries(
    ContainerRef container,
    List<String> paths,
  ) async {}

  @override
  Future<void> createFolder(ContainerRef container, String path) async {}

  @override
  Future<void> copyEntry(
    ContainerRef container,
    String from,
    String to,
  ) async {}

  @override
  Future<void> moveEntry(
    ContainerRef container,
    String from,
    String to,
  ) async {}

  @override
  Future<String?> shareLink(
    ContainerRef container,
    String path, {
    Duration expires = const Duration(hours: 1),
  }) async => 'https://example.test/$path';
}

/// The fixtures, built rather than committed so each one's shape is readable.
final Map<String, Uint8List> _files = <String, Uint8List>{
  'orders.csv': Uint8List.fromList(
    utf8.encode(
      'id,customer,total\n'
      '1,"Ford, Betty",42.50\n'
      '2,Ada Lovelace,17.00\n',
    ),
  ),
  'books.xlsx': _xlsx(),
  'notes.docx': _docx(),
  'contract.pdf': Uint8List.fromList(
    ascii.encode('%PDF-1.7\ntrailer << /Encrypt 4 0 R >>\n%%EOF\n'),
  ),
  'clip.mp4': _mp4(),
};

Uint8List _zip(Map<String, String> parts) {
  final archive = Archive();
  for (final entry in parts.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List _docx() => _zip(<String, String>{
  'word/document.xml':
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>'
      '<w:p><w:r><w:t>The first paragraph.</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>And the second.</w:t></w:r></w:p>'
      '</w:body></w:document>',
});

Uint8List _xlsx() => _zip(<String, String>{
  'xl/workbook.xml':
      '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>'
      '<sheet name="Titles" sheetId="1" r:id="rId1"/>'
      '<sheet name="Places" sheetId="2" r:id="rId2"/>'
      '</sheets></workbook>',
  'xl/_rels/workbook.xml.rels':
      '<Relationships>'
      '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Target="worksheets/sheet2.xml"/>'
      '</Relationships>',
  'xl/sharedStrings.xml':
      '<sst>'
      '<si><t>title</t></si><si><t>Dune</t></si>'
      '<si><t>city</t></si><si><t>Paris</t></si>'
      '</sst>',
  'xl/worksheets/sheet1.xml':
      '<worksheet><sheetData>'
      '<row r="1"><c r="A1" t="s"><v>0</v></c></row>'
      '<row r="2"><c r="A2" t="s"><v>1</v></c></row>'
      '</sheetData></worksheet>',
  'xl/worksheets/sheet2.xml':
      '<worksheet><sheetData>'
      '<row r="1"><c r="A1" t="s"><v>2</v></c></row>'
      '<row r="2"><c r="A2" t="s"><v>3</v></c></row>'
      '</sheetData></worksheet>',
});

/// Thirty seconds of 1920×1080, as the two header boxes that say so.
Uint8List _mp4() {
  List<int> uint32(int value) => <int>[
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
  List<int> box(String type, List<int> payload) => <int>[
    ...uint32(8 + payload.length),
    ...ascii.encode(type),
    ...payload,
  ];

  final mvhd = box('mvhd', <int>[
    0, 0, 0, 0,
    ...uint32(0),
    ...uint32(0),
    ...uint32(1000),
    ...uint32(30000),
  ]);
  final tkhd = box('tkhd', <int>[
    0, 0, 0, 0,
    ...List<int>.filled(72, 0),
    ...uint32(1920 << 16),
    ...uint32(1080 << 16),
  ]);

  return Uint8List.fromList(<int>[
    ...box('ftyp', ascii.encode('isom').toList()),
    ...box('moov', <int>[...mvhd, ...box('trak', tkhd)]),
  ]);
}

class _NoSecrets implements SecretsStore {
  @override
  Future<ConnectionSecrets?> read(String secretsRef) async => null;

  @override
  Future<void> write(String secretsRef, ConnectionSecrets secrets) async {}

  @override
  Future<void> delete(String secretsRef) async {}
  @override
  Future<int> sweepOrphans(Iterable<String> liveRefs) async => 0;

  @override
  Future<({int removed, bool complete})> deleteAll() async =>
      (removed: 0, complete: true);
}
