import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:dextr/connectors/vector/hnsw_index_file.dart';
import 'package:dextr/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a `header.bin` the way hnswlib writes one.
///
/// [base] is where the twelve 8-byte scalars start: 4 for the header a real
/// Chroma index has — its fork writes a word in front, making the file 100
/// bytes — and 0 for upstream hnswlib's 96-byte one. Both are exercised,
/// because reading a Chroma header at upstream's offsets is the bug this file
/// exists to keep out.
Uint8List hnswHeader({
  required int count,
  required int maxElements,
  required int stride,
  required int labelOffset,
  required int dataOffset,
  int base = 4,
}) {
  final header = ByteData(base + 96);
  if (base == 4) header.setInt32(0, 1, Endian.little);
  void put(int index, int value) =>
      header.setUint64(base + index * 8, value, Endian.little);

  put(0, 0); // offsetLevel0
  put(1, maxElements);
  put(2, count);
  put(3, stride);
  put(4, labelOffset);
  put(5, dataOffset);
  header.setInt32(base + 48, -1, Endian.little); // maxlevel
  header.setInt32(base + 52, -1, Endian.little); // enterpoint
  put(7, 16); // maxM
  put(8, 32); // maxM0
  put(9, 16); // M
  header.setFloat64(base + 80, 0.36067376022224085, Endian.little); // mult
  put(11, 100); // ef_construction
  return header.buffer.asUint8List();
}

/// Writes the pair of files hnswlib's `saveIndex` produces, as Chroma splits
/// them: the header scalars in one, the element blob in the other.
///
/// Layout per element is `[links][vector][label]`, which is what the reader has
/// to walk past, into and to the end of respectively.
Future<Directory> _writeIndex({
  required List<List<double>> vectors,
  int linkBytes = 40,
  int? countOverride,
  int? truncateDataTo,
  int base = 4,
}) async {
  final directory = await Directory.systemTemp.createTemp('hnsw-test');
  final dimension = vectors.isEmpty ? 0 : vectors.first.length;
  final dataOffset = linkBytes;
  final labelOffset = dataOffset + dimension * 4;
  final stride = labelOffset + 8;

  await File('${directory.path}/header.bin').writeAsBytes(
    hnswHeader(
      count: countOverride ?? vectors.length,
      maxElements: vectors.length,
      stride: stride,
      labelOffset: labelOffset,
      dataOffset: dataOffset,
      base: base,
    ),
  );

  final data = ByteData(stride * vectors.length);
  for (var i = 0; i < vectors.length; i++) {
    final base = i * stride;
    for (var j = 0; j < dimension; j++) {
      data.setFloat32(base + dataOffset + j * 4, vectors[i][j], Endian.little);
    }
    // Labels deliberately not in file order, because hnswlib's are not either.
    data.setUint64(base + labelOffset, vectors.length - 1 - i, Endian.little);
  }
  var bytes = data.buffer.asUint8List();
  if (truncateDataTo != null) bytes = bytes.sublist(0, truncateDataTo);
  await File('${directory.path}/data_level0.bin').writeAsBytes(bytes);

  return directory;
}

void main() {
  late final List<Directory> temporaries = <Directory>[];

  tearDownAll(() async {
    for (final directory in temporaries) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  });

  Future<Directory> track(Future<Directory> future) async {
    final directory = await future;
    temporaries.add(directory);
    return directory;
  }

  test('reads vectors and labels out of a saved index', () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2, 3, 4],
          <double>[-1, 0.5, 0.25, 8],
          <double>[0, 0, 0, 0],
        ],
      ),
    );

    final index = await HnswIndexFile.open(directory.path);
    expect(index, isNotNull);
    addTearDown(() => index!.close());
    expect(index!.count, 3);
    // Derived from the gap between the data and the label, never from a
    // declared dimension that might disagree with the file.
    expect(index.dimension, 4);

    expect(index.vectorAt(0), <double>[1, 2, 3, 4]);
    expect(index.vectorAt(1)[3], 8);
    expect(index.vectorAt(2), <double>[0, 0, 0, 0]);

    expect(index.labelAt(0), 2);
    expect(index.labelAt(2), 0);

    // Elements are seeked to, not held, so the same one reads the same twice.
    expect(index.vectorAt(0), <double>[1, 2, 3, 4]);
  });

  test('entryAt returns the label and vector of one element together',
      () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2],
          <double>[3, 4],
        ],
      ),
    );

    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());

    final (label0, vector0) = index!.entryAt(0);
    expect(label0, index.labelAt(0));
    expect(vector0, index.vectorAt(0));

    final (label1, vector1) = index.entryAt(1);
    expect(label1, 0);
    expect(vector1, <double>[3, 4]);
  });

  test('a closed index refuses to read rather than reading a dead handle',
      () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2],
        ],
      ),
    );
    final index = await HnswIndexFile.open(directory.path);
    await index!.close();
    expect(() => index.vectorAt(0), throwsA(isA<ConnectError>()));
    // Closing twice is safe, so a `finally` can call it without checking.
    await index.close();
  });

  test('float32 on disk widens to double without losing the value', () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[0.5, -0.25, 0.125, 2],
        ],
      ),
    );
    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());
    // Powers of two survive the round trip exactly, which is what makes this
    // an equality rather than a tolerance.
    expect(index!.vectorAt(0), <double>[0.5, -0.25, 0.125, 2]);
  });

  test('a directory with no index is absence, not failure', () async {
    final directory = await track(
      Future<Directory>.value(
        await Directory.systemTemp.createTemp('hnsw-empty'),
      ),
    );
    expect(await HnswIndexFile.open(directory.path), isNull);
  });

  test('an index holding nothing reads as nothing', () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2],
        ],
        countOverride: 0,
      ),
    );
    expect(await HnswIndexFile.open(directory.path), isNull);
  });

  test('a partially written data file is read to where it actually ends',
      () async {
    // The header claims four elements; only two whole ones were flushed.
    final vectors = <List<double>>[
      <double>[1, 1, 1, 1],
      <double>[2, 2, 2, 2],
      <double>[3, 3, 3, 3],
      <double>[4, 4, 4, 4],
    ];
    const stride = 40 + 4 * 4 + 8;
    final directory = await track(
      _writeIndex(vectors: vectors, truncateDataTo: stride * 2),
    );

    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());
    expect(index!.count, 2);
    expect(index.vectorAt(1), <double>[2, 2, 2, 2]);
  });

  test("reads Chroma's 100-byte header, not upstream's 96-byte one", () async {
    // The regression: Chroma builds against a fork of hnswlib that writes a
    // four-byte word before the scalars, so every field sits four bytes further
    // along. Reading a real Chroma index at upstream's offsets reported a width
    // of 1,649,267,441,664 and refused to open the collection.
    //
    // The numbers here are taken from a real Chroma segment: 384-component
    // vectors, 32 links at level zero, so data at 132 and the label at 1668.
    const dimension = 384;
    const dataOffset = 132;
    const labelOffset = dataOffset + dimension * 4; // 1668
    const stride = labelOffset + 8; // 1676

    final directory = await track(
      Future<Directory>.value(
        await Directory.systemTemp.createTemp('hnsw-chroma'),
      ),
    );
    await File(p.join(directory.path, 'header.bin')).writeAsBytes(
      hnswHeader(
        count: 3,
        maxElements: 100,
        stride: stride,
        labelOffset: labelOffset,
        dataOffset: dataOffset,
      ),
    );
    await File(p.join(directory.path, 'data_level0.bin'))
        .writeAsBytes(Uint8List(stride * 3));

    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());
    expect(index!.dimension, dimension);
    expect(index.count, 3);
    expect(index.stride, stride);
  });

  test("still reads upstream hnswlib's 96-byte header", () async {
    // Both layouts are accepted, chosen by which one is self-consistent —
    // an index written by anything but Chroma has no leading word.
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2, 3],
          <double>[4, 5, 6],
        ],
        base: 0,
      ),
    );

    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());
    expect(index!.dimension, 3);
    expect(index.count, 2);
    expect(index.vectorAt(1), <double>[4, 5, 6]);
  });

  test('an index reserved but never written to reads as no index', () async {
    // Chroma allocates `data_level0.bin` for `max_elements` the moment a
    // collection exists, so the file is full-size while the index is empty.
    // Believing the file size here plots a screenful of zero vectors.
    const dimension = 384;
    const dataOffset = 132;
    const labelOffset = dataOffset + dimension * 4;
    const stride = labelOffset + 8;

    final directory = await track(
      Future<Directory>.value(
        await Directory.systemTemp.createTemp('hnsw-reserved'),
      ),
    );
    await File(p.join(directory.path, 'header.bin')).writeAsBytes(
      hnswHeader(
        count: 0, // nothing written
        maxElements: 100,
        stride: stride,
        labelOffset: labelOffset,
        dataOffset: dataOffset,
      ),
    );
    // Full size for a hundred elements, all of them zeroes.
    await File(p.join(directory.path, 'data_level0.bin'))
        .writeAsBytes(Uint8List(stride * 100));

    expect(await HnswIndexFile.open(directory.path), isNull);
  });

  test('a header that is not a header is refused rather than read', () async {
    final directory = await Directory.systemTemp.createTemp('hnsw-bad');
    temporaries.add(directory);
    await File('${directory.path}/header.bin').writeAsBytes(
      Uint8List(96), // all zeroes: labelOffset == dataOffset, stride == 0
    );
    await File('${directory.path}/data_level0.bin').writeAsBytes(Uint8List(64));

    await expectLater(
      HnswIndexFile.open(directory.path),
      throwsA(isA<ConnectError>()),
    );
  });

  test('a truncated header is refused rather than read past', () async {
    final directory = await Directory.systemTemp.createTemp('hnsw-short');
    temporaries.add(directory);
    await File('${directory.path}/header.bin').writeAsBytes(Uint8List(32));
    await File('${directory.path}/data_level0.bin').writeAsBytes(Uint8List(64));

    await expectLater(
      HnswIndexFile.open(directory.path),
      throwsA(isA<ConnectError>()),
    );
  });

  test('reading past the end is a range error, not garbage', () async {
    final directory = await track(
      _writeIndex(
        vectors: <List<double>>[
          <double>[1, 2],
        ],
      ),
    );
    final index = await HnswIndexFile.open(directory.path);
    addTearDown(() => index!.close());
    expect(() => index!.vectorAt(1), throwsRangeError);
    expect(() => index!.labelAt(-1), throwsRangeError);
  });
}
