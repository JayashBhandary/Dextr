import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/logger.dart';

/// The label → id mapping Chroma keeps beside an hnsw index.
///
/// hnswlib knows its elements by an integer label; Chroma knows them by a
/// string id. The mapping between the two lives in `index_metadata.pickle` —
/// a Python pickle — and without it the only way to recover an id is to line
/// labels up with insertion order, which stops being true the moment anything
/// is deleted. A real store with 9,566 index slots and 8,965 live rows has no
/// safe positional mapping at all, and every point in it reads as `#label`.
///
/// So the pickle is parsed. Not with a general-purpose pickle machine — that is
/// a security problem, because unpickling arbitrary data can construct
/// arbitrary objects — but with a reader that understands only the handful of
/// opcodes a dict of ints and strings is built from. Anything else it does not
/// recognise makes it give up and return null, and the caller falls back to
/// labels. Nothing here can execute or import anything.
class ChromaIndexMetadata {
  ChromaIndexMetadata({required this.labelToId});

  /// hnswlib label → Chroma's own string id.
  final Map<int, String> labelToId;

  /// The same mapping the other way, for going from a document match back to
  /// the element that holds its vector. Built on first use — a text search
  /// needs it and a plain walk never does.
  late final Map<String, int> idToLabel = <String, int>{
    for (final e in labelToId.entries) e.value: e.key,
  };

  bool get isEmpty => labelToId.isEmpty;

  /// Reads `index_metadata.pickle` from a segment directory.
  ///
  /// Null whenever the mapping cannot be had — absent file, a pickle shape this
  /// does not read, a truncated write. Never throws: this is an improvement on
  /// the fallback, not a thing the connection depends on.
  static Future<ChromaIndexMetadata?> open(String segmentDirectory) async {
    final file = File('$segmentDirectory/index_metadata.pickle');
    if (!file.existsSync()) return null;

    try {
      final decoded = _Unpickler(await file.readAsBytes()).run();
      if (decoded is! Map) return null;

      // `label_to_id` is what Chroma writes; `id_to_label` is the same mapping
      // the other way round, and inverting it costs nothing if only that is
      // present.
      final direct = decoded['label_to_id'];
      if (direct is Map) {
        final out = <int, String>{};
        for (final e in direct.entries) {
          if (e.key is int && e.value is String) {
            out[e.key as int] = e.value as String;
          }
        }
        if (out.isNotEmpty) return ChromaIndexMetadata(labelToId: out);
      }

      final inverse = decoded['id_to_label'];
      if (inverse is Map) {
        final out = <int, String>{};
        for (final e in inverse.entries) {
          if (e.key is String && e.value is int) {
            out[e.value as int] = e.key as String;
          }
        }
        if (out.isNotEmpty) return ChromaIndexMetadata(labelToId: out);
      }

      return null;
    } catch (e) {
      log.w('Could not read $segmentDirectory/index_metadata.pickle: $e');
      return null;
    }
  }
}

/// Thrown internally when an opcode outside the supported subset turns up.
class _UnsupportedOpcode implements Exception {
  const _UnsupportedOpcode(this.opcode, this.position);

  final int opcode;
  final int position;

  @override
  String toString() =>
      'unsupported pickle opcode 0x${opcode.toRadixString(16)} at $position';
}

/// Marks the start of a group on the stack.
const Object _mark = Object();

/// A pickle reader for data, not for objects.
///
/// Implements the opcodes that dicts, lists, tuples, strings, integers, floats,
/// booleans and None are built from, across protocols 2 to 5. Deliberately
/// absent: `GLOBAL`, `REDUCE`, `INST`, `OBJ`, `BUILD`, `STACK_GLOBAL` and
/// `PERSID` — every opcode that would import a module or construct a class.
/// Their absence is what makes reading a file this app did not write safe.
class _Unpickler {
  _Unpickler(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _at = 0;

  final List<Object?> _stack = <Object?>[];
  final Map<int, Object?> _memo = <int, Object?>{};

  Object? run() {
    while (_at < _bytes.length) {
      final position = _at;
      final opcode = _bytes[_at++];
      switch (opcode) {
        case 0x80: // PROTO
          _at += 1;
        case 0x95: // FRAME
          _at += 8;
        case 0x2e: // STOP
          return _stack.isEmpty ? null : _stack.removeLast();

        case 0x28: // MARK
          _stack.add(_mark);
        case 0x4e: // NONE
          _stack.add(null);
        case 0x88: // NEWTRUE
          _stack.add(true);
        case 0x89: // NEWFALSE
          _stack.add(false);

        case 0x4a: // BININT, 4-byte signed
          _stack.add(_view.getInt32(_at, Endian.little));
          _at += 4;
        case 0x4b: // BININT1, 1 byte unsigned
          _stack.add(_bytes[_at++]);
        case 0x4d: // BININT2, 2 bytes unsigned
          _stack.add(_view.getUint16(_at, Endian.little));
          _at += 2;
        case 0x8a: // LONG1, length-prefixed little-endian signed
          _stack.add(_readLong(_bytes[_at++]));
        case 0x8b: // LONG4
          final length = _view.getInt32(_at, Endian.little);
          _at += 4;
          _stack.add(_readLong(length));
        case 0x47: // BINFLOAT, big-endian double
          _stack.add(_view.getFloat64(_at, Endian.big));
          _at += 8;

        case 0x58: // BINUNICODE, 4-byte length
          final length = _view.getUint32(_at, Endian.little);
          _at += 4;
          _stack.add(_readString(length));
        case 0x8c: // SHORT_BINUNICODE, 1-byte length
          _stack.add(_readString(_bytes[_at++]));
        case 0x8d: // BINUNICODE8, 8-byte length
          final length = _view.getUint64(_at, Endian.little);
          _at += 8;
          _stack.add(_readString(length));
        case 0x43: // SHORT_BINBYTES
          _stack.add(_readBytes(_bytes[_at++]));
        case 0x42: // BINBYTES
          final length = _view.getUint32(_at, Endian.little);
          _at += 4;
          _stack.add(_readBytes(length));

        case 0x7d: // EMPTY_DICT
          _stack.add(<Object?, Object?>{});
        case 0x5d: // EMPTY_LIST
          _stack.add(<Object?>[]);
        case 0x29: // EMPTY_TUPLE
          _stack.add(const <Object?>[]);
        case 0x85: // TUPLE1
          _stack.add(<Object?>[_stack.removeLast()]);
        case 0x86: // TUPLE2
          final b = _stack.removeLast();
          final a = _stack.removeLast();
          _stack.add(<Object?>[a, b]);
        case 0x87: // TUPLE3
          final c = _stack.removeLast();
          final b = _stack.removeLast();
          final a = _stack.removeLast();
          _stack.add(<Object?>[a, b, c]);
        case 0x74: // TUPLE, back to the mark
          _stack.add(_popToMark());

        case 0x73: // SETITEM
          final value = _stack.removeLast();
          final key = _stack.removeLast();
          _asMap(_stack.last)[key] = value;
        case 0x75: // SETITEMS, pairs back to the mark
          final items = _popToMark();
          final map = _asMap(_stack.last);
          for (var i = 0; i + 1 < items.length; i += 2) {
            map[items[i]] = items[i + 1];
          }
        case 0x61: // APPEND
          final value = _stack.removeLast();
          _asList(_stack.last).add(value);
        case 0x65: // APPENDS
          final items = _popToMark();
          _asList(_stack.last).addAll(items);

        case 0x71: // BINPUT
          _memo[_bytes[_at++]] = _stack.last;
        case 0x72: // LONG_BINPUT
          _memo[_view.getUint32(_at, Endian.little)] = _stack.last;
          _at += 4;
        case 0x94: // MEMOIZE
          _memo[_memo.length] = _stack.last;
        case 0x68: // BINGET
          _stack.add(_memo[_bytes[_at++]]);
        case 0x6a: // LONG_BINGET
          _stack.add(_memo[_view.getUint32(_at, Endian.little)]);
          _at += 4;

        default:
          // Anything else — including every opcode that would construct an
          // object — stops the read rather than being guessed at.
          throw _UnsupportedOpcode(opcode, position);
      }
    }
    return _stack.isEmpty ? null : _stack.last;
  }

  String _readString(int length) {
    final end = _at + length;
    if (end > _bytes.length) throw const FormatException('truncated pickle');
    final s = utf8.decode(_bytes.sublist(_at, end), allowMalformed: true);
    _at = end;
    return s;
  }

  Uint8List _readBytes(int length) {
    final end = _at + length;
    if (end > _bytes.length) throw const FormatException('truncated pickle');
    final b = Uint8List.sublistView(_bytes, _at, end);
    _at = end;
    return b;
  }

  /// A little-endian two's-complement integer of [length] bytes.
  int _readLong(int length) {
    if (length == 0) return 0;
    var value = 0;
    for (var i = 0; i < length; i++) {
      value |= _bytes[_at + i] << (8 * i);
    }
    // Sign-extend from the top bit of the last byte.
    if (_bytes[_at + length - 1] & 0x80 != 0) {
      value -= 1 << (8 * length);
    }
    _at += length;
    return value;
  }

  List<Object?> _popToMark() {
    final index = _stack.lastIndexOf(_mark);
    if (index < 0) throw const FormatException('pickle mark missing');
    final items = _stack.sublist(index + 1);
    _stack.removeRange(index, _stack.length);
    return items;
  }

  Map<Object?, Object?> _asMap(Object? value) {
    if (value is Map<Object?, Object?>) return value;
    throw const FormatException('pickle expected a dict');
  }

  List<Object?> _asList(Object? value) {
    if (value is List<Object?>) return value;
    throw const FormatException('pickle expected a list');
  }
}
