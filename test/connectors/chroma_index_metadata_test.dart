import 'dart:io';
import 'dart:typed_data';

import 'package:dextr/connectors/vector/chroma_index_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Builds pickles by hand, opcode by opcode, so the reader is tested against
/// the byte stream CPython actually emits rather than against itself.
class _Pickle {
  final BytesBuilder _out = BytesBuilder();

  _Pickle([int protocol = 3]) {
    _out.addByte(0x80); // PROTO
    _out.addByte(protocol);
  }

  void emptyDict() => _out.addByte(0x7d);
  void mark() => _out.addByte(0x28);
  void setItems() => _out.addByte(0x75);
  void setItem() => _out.addByte(0x73);
  void none() => _out.addByte(0x4e);
  void emptyList() => _out.addByte(0x5d);
  void appends() => _out.addByte(0x65);
  void newTrue() => _out.addByte(0x88);

  /// BINUNICODE: 4-byte little-endian length, then UTF-8.
  void str(String value) {
    final bytes = Uint8List.fromList(value.codeUnits);
    _out.addByte(0x58);
    final length = ByteData(4)..setUint32(0, bytes.length, Endian.little);
    _out.add(length.buffer.asUint8List());
    _out.add(bytes);
  }

  /// SHORT_BINUNICODE, protocol 4's 1-byte-length form.
  void shortStr(String value) {
    final bytes = Uint8List.fromList(value.codeUnits);
    _out.addByte(0x8c);
    _out.addByte(bytes.length);
    _out.add(bytes);
  }

  /// BININT: 4-byte signed.
  void int32(int value) {
    _out.addByte(0x4a);
    final b = ByteData(4)..setInt32(0, value, Endian.little);
    _out.add(b.buffer.asUint8List());
  }

  /// BININT1: one unsigned byte.
  void int8(int value) {
    _out.addByte(0x4b);
    _out.addByte(value);
  }

  void memoize() => _out.addByte(0x94);

  /// An opcode the reader does not implement — GLOBAL, which is the one that
  /// would name a module and a class to construct.
  void global(String module, String name) {
    _out.addByte(0x63);
    _out.add(Uint8List.fromList('$module\n$name\n'.codeUnits));
  }

  Uint8List done() {
    _out.addByte(0x2e); // STOP
    return _out.toBytes();
  }
}

Future<Directory> _write(Uint8List pickle) async {
  final directory = await Directory.systemTemp.createTemp('chroma-meta');
  await File(p.join(directory.path, 'index_metadata.pickle'))
      .writeAsBytes(pickle);
  return directory;
}

void main() {
  final temporaries = <Directory>[];

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

  test('reads label_to_id out of the shape Chroma writes', () async {
    // The real file is exactly this: an outer dict with four keys, one of which
    // is a dict of int → string built with MARK … SETITEMS.
    final pickle = _Pickle()
      ..emptyDict()
      ..mark()
      ..str('dimensionality')
      ..none()
      ..str('total_elements_added')
      ..int32(9566)
      ..str('label_to_id')
      ..emptyDict()
      ..mark()
      ..int32(4986)
      ..str('doc-a_chunk_3')
      ..int32(1542)
      ..str('doc-b_chunk_2')
      ..int8(7)
      ..str('doc-c_chunk_0')
      ..setItems()
      ..str('id_to_seq_id')
      ..emptyDict()
      ..setItems();

    final directory = await track(_write(pickle.done()));
    final meta = await ChromaIndexMetadata.open(directory.path);

    expect(meta, isNotNull);
    expect(meta!.labelToId, <int, String>{
      4986: 'doc-a_chunk_3',
      1542: 'doc-b_chunk_2',
      7: 'doc-c_chunk_0',
    });
  });

  test('inverts id_to_label when that is the only mapping present', () async {
    final pickle = _Pickle()
      ..emptyDict()
      ..mark()
      ..str('id_to_label')
      ..emptyDict()
      ..mark()
      ..str('doc-a')
      ..int32(11)
      ..str('doc-b')
      ..int32(22)
      ..setItems()
      ..setItems();

    final directory = await track(_write(pickle.done()));
    final meta = await ChromaIndexMetadata.open(directory.path);

    expect(meta!.labelToId, <int, String>{11: 'doc-a', 22: 'doc-b'});
  });

  test('reads protocol 4 short strings and memo opcodes', () async {
    final pickle = _Pickle(4)
      ..emptyDict()
      ..memoize()
      ..mark()
      ..shortStr('label_to_id')
      ..emptyDict()
      ..memoize()
      ..mark()
      ..int8(3)
      ..shortStr('doc-z')
      ..setItems()
      ..setItems();

    final directory = await track(_write(pickle.done()));
    final meta = await ChromaIndexMetadata.open(directory.path);
    expect(meta!.labelToId, <int, String>{3: 'doc-z'});
  });

  test('handles SETITEM one pair at a time, and lists', () async {
    final pickle = _Pickle()
      ..emptyDict()
      ..str('label_to_id')
      ..emptyDict()
      ..int8(1)
      ..str('only')
      ..setItem()
      ..setItem();

    final directory = await track(_write(pickle.done()));
    final meta = await ChromaIndexMetadata.open(directory.path);
    expect(meta!.labelToId, <int, String>{1: 'only'});
  });

  test('refuses a pickle that would construct an object', () async {
    // GLOBAL names a module and a class. A general unpickler would import and
    // instantiate it, which is the reason unpickling untrusted data is unsafe.
    // This reader has no opcode for it and gives up instead.
    final pickle = _Pickle()
      ..emptyDict()
      ..mark()
      ..str('label_to_id')
      ..global('os', 'system')
      ..setItems();

    final directory = await track(_write(pickle.done()));
    expect(await ChromaIndexMetadata.open(directory.path), isNull);
  });

  test('a missing pickle is absence, not failure', () async {
    final directory = await track(
      Future<Directory>.value(
        await Directory.systemTemp.createTemp('chroma-nometa'),
      ),
    );
    expect(await ChromaIndexMetadata.open(directory.path), isNull);
  });

  test('a truncated pickle gives up rather than half-reading it', () async {
    final full = (_Pickle()
          ..emptyDict()
          ..mark()
          ..str('label_to_id')
          ..emptyDict()
          ..mark()
          ..int32(1)
          ..str('doc-a')
          ..setItems()
          ..setItems())
        .done();

    final directory = await track(_write(full.sublist(0, full.length - 12)));
    expect(await ChromaIndexMetadata.open(directory.path), isNull);
  });

  test('a pickle that is not a mapping at all reads as nothing', () async {
    final pickle = _Pickle()
      ..emptyList()
      ..mark()
      ..str('nope')
      ..newTrue()
      ..appends();

    final directory = await track(_write(pickle.done()));
    expect(await ChromaIndexMetadata.open(directory.path), isNull);
  });

  test('a file of random bytes is refused', () async {
    final directory = await track(
      _write(Uint8List.fromList(List<int>.generate(256, (i) => i))),
    );
    expect(await ChromaIndexMetadata.open(directory.path), isNull);
  });
}
