import 'dart:io';
import 'dart:typed_data';

import '../../core/errors.dart';

/// Reads the vectors out of an hnswlib index saved to disk.
///
/// Chroma persists each collection's vector segment as an hnswlib index split
/// across four files in a uuid-named directory, of which two matter here:
///
/// * `header.bin` — thirteen scalars describing the layout, written by
///   hnswlib's `writeBinaryPOD` in declaration order and therefore
///   little-endian and unpadded.
/// * `data_level0.bin` — `cur_element_count` fixed-size records, each of which
///   is `[links][vector][label]`.
///
/// Nothing here needs the graph. The links are skipped, the vector is read at
/// `offsetData`, and the label — hnswlib's own integer handle for the element —
/// is read at `labelOffset`. That is the whole format as far as plotting a
/// space is concerned.
///
/// **Elements are read on demand, not slurped.** `data_level0.bin` for a
/// hundred thousand 1536-component vectors is well over half a gigabyte, and
/// reading it whole to plot a thousand points was the difference between the
/// pane opening and the app appearing to hang. The header is 96 bytes and is
/// read eagerly; everything else is a seek and a short read.
///
/// This is the reason file mode exists for Chroma and not for the others:
/// Qdrant's on-disk store is RocksDB plus a proprietary segment format and
/// Weaviate's is an LSM tree, neither of which can be read without the engine.
class HnswIndexFile {
  HnswIndexFile._({
    required this.count,
    required this.dimension,
    required this.stride,
    required this.dataOffset,
    required this.labelOffset,
    required RandomAccessFile data,
    // An initialising formal would be `this._data`, and a named parameter may
    // not start with an underscore.
    // ignore: prefer_initializing_formals
  }) : _data = data,
       _element = Uint8List(stride);

  /// How many elements the index holds.
  final int count;

  /// How many floats wide each one is.
  final int dimension;

  /// Bytes per element in the data file.
  final int stride;

  /// Where a vector starts inside an element.
  final int dataOffset;

  /// Where the label starts inside an element.
  final int labelOffset;

  final RandomAccessFile _data;

  /// One element's worth of scratch, reused across reads. Reading a thousand
  /// vectors should not allocate a thousand buffers.
  final Uint8List _element;

  bool _closed = false;

  /// Where the twelve 8-byte scalars begin.
  ///
  /// Upstream hnswlib writes them from byte zero, for a 96-byte header. Chroma
  /// builds against its own fork, which puts a four-byte word in front and
  /// produces a 100-byte one — so every field in a real Chroma index sits four
  /// bytes further along than upstream's documentation implies. Reading a
  /// Chroma header at upstream's offsets yields a dimension in the trillions,
  /// which is how this was found.
  ///
  /// Rather than pick by file size alone, both are tried and the one that
  /// produces a self-consistent layout wins — see [_Layout.parse].
  static const List<int> _candidateBases = <int>[4, 0];

  /// A sanity ceiling on the width. The widest embedding in general use is a
  /// few thousand components; anything past this means the header was not a
  /// header, and reading on would allocate gigabytes from garbage.
  static const _maxDimension = 1 << 16;

  /// Opens the index in [directory], or returns null when it holds no index —
  /// a collection that was created and never written to has a directory with
  /// nothing in it, which is not an error.
  ///
  /// The caller owns the result and must [close] it.
  static Future<HnswIndexFile?> open(String directory) async {
    final header = File('$directory/header.bin');
    final data = File('$directory/data_level0.bin');
    if (!header.existsSync() || !data.existsSync()) return null;

    final headerBytes = await header.readAsBytes();

    _Layout? layout;
    for (final base in _candidateBases) {
      layout = _Layout.parse(headerBytes, base);
      if (layout != null) break;
    }
    if (layout == null) {
      throw ConnectError(
        'The hnsw header in $directory (${headerBytes.length} bytes) does not '
        'describe a readable layout at either of the offsets hnswlib and '
        "Chroma's fork of it write",
      );
    }

    // An index that has been allocated but never written to. Chroma leaves the
    // element slots reserved — `data_level0.bin` is `max_elements` long from the
    // moment the collection exists — so the file's size says nothing about
    // whether anything is in it, and only this count does. Trusting the file
    // size here would plot a screenful of zero vectors.
    if (layout.count == 0) return null;

    // The file's own length is still an upper bound: a header claiming more
    // elements than were flushed would send reads off the end.
    final usable = data.lengthSync() ~/ layout.stride;
    if (usable == 0) return null;

    return HnswIndexFile._(
      count: layout.count < usable ? layout.count : usable,
      dimension: layout.dimension,
      stride: layout.stride,
      dataOffset: layout.dataOffset,
      labelOffset: layout.labelOffset,
      data: await data.open(),
    );
  }

  /// Reads element [index] into the scratch buffer.
  void _seek(int index) {
    if (_closed) throw const ConnectError('The hnsw index is closed');
    RangeError.checkValidIndex(index, this, 'index', count);
    _data.setPositionSync(index * stride);
    _data.readIntoSync(_element);
  }

  /// The vector of element [index], copied out as doubles.
  ///
  /// hnswlib stores float32; Dart's `double` is float64, so this widens rather
  /// than reinterprets.
  List<double> vectorAt(int index) {
    _seek(index);
    final view = ByteData.sublistView(_element);
    final out = List<double>.filled(dimension, 0);
    for (var i = 0; i < dimension; i++) {
      out[i] = view.getFloat32(dataOffset + i * 4, Endian.little);
    }
    return out;
  }

  /// hnswlib's own handle for element [index]. Chroma maps these back to its
  /// string ids in `index_metadata.pickle`, which is a Python pickle and
  /// therefore not read here — see `ChromaFileBackend` for how ids are
  /// recovered instead.
  int labelAt(int index) {
    _seek(index);
    return ByteData.sublistView(_element).getUint64(labelOffset, Endian.little);
  }

  /// Both halves of one element, without seeking twice for them.
  (int label, List<double> vector) entryAt(int index) {
    _seek(index);
    final view = ByteData.sublistView(_element);
    final vector = List<double>.filled(dimension, 0);
    for (var i = 0; i < dimension; i++) {
      vector[i] = view.getFloat32(dataOffset + i * 4, Endian.little);
    }
    return (view.getUint64(labelOffset, Endian.little), vector);
  }

  /// label → file position, built once by reading just the label of each
  /// element.
  Map<int, int>? _positions;

  /// Where the element carrying [label] lives, or null if no element does.
  ///
  /// A label is not a position: hnswlib hands labels out in insertion order but
  /// stores elements wherever there is room. Finding one therefore means a pass
  /// over the file — but only over the labels, eight bytes per element rather
  /// than the several kilobytes a vector costs, so the pass is cheap and it
  /// happens once.
  int? positionOfLabel(int label) {
    if (_closed) throw const ConnectError('The hnsw index is closed');
    final known = _positions ??= _readLabels();
    return known[label];
  }

  Map<int, int> _readLabels() {
    final scratch = Uint8List(8);
    final view = ByteData.sublistView(scratch);
    final out = <int, int>{};
    for (var i = 0; i < count; i++) {
      _data.setPositionSync(i * stride + labelOffset);
      _data.readIntoSync(scratch);
      // First position wins: a label should be unique, and if a damaged file
      // repeats one, the earlier element is the one the walk would show.
      out.putIfAbsent(view.getUint64(0, Endian.little), () => i);
    }
    return out;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _positions = null;
    await _data.close();
  }

  /// So `RangeError.checkValidIndex` can report against this object.
  int get length => count;
}

/// The four numbers that matter, read at one candidate offset.
class _Layout {
  const _Layout({
    required this.count,
    required this.dimension,
    required this.stride,
    required this.dataOffset,
    required this.labelOffset,
  });

  final int count;
  final int dimension;
  final int stride;
  final int dataOffset;
  final int labelOffset;

  /// Reads the header assuming the scalars start at [base], and returns null
  /// unless the result is self-consistent.
  ///
  /// The check that does the work is `stride == labelOffset + 8`: the label is
  /// the last thing in an element, so an element is exactly its own label
  /// offset plus the eight bytes of the label. That holds at the right offset
  /// and essentially never at a wrong one, which is what makes guessing between
  /// the two layouts safe rather than a coin toss.
  static _Layout? parse(Uint8List bytes, int base) {
    // Six scalars are read; the last of them ends at base + 48.
    if (bytes.length < base + 48) return null;
    final view = ByteData.sublistView(bytes);
    int at(int index) => view.getUint64(base + index * 8, Endian.little);

    // Field order is hnswlib's `saveIndex`: offsetLevel0, max_elements,
    // cur_element_count, size_data_per_element, label_offset, offsetData.
    final count = at(2);
    final stride = at(3);
    final labelOffset = at(4);
    final dataOffset = at(5);

    if (stride == 0 || labelOffset <= dataOffset) return null;
    if (stride != labelOffset + 8) return null;

    final vectorBytes = labelOffset - dataOffset;
    if (vectorBytes % 4 != 0) return null;
    final dimension = vectorBytes ~/ 4;
    if (dimension == 0 || dimension > HnswIndexFile._maxDimension) return null;

    return _Layout(
      count: count,
      dimension: dimension,
      stride: stride,
      dataOffset: dataOffset,
      labelOffset: labelOffset,
    );
  }
}
