import 'dart:convert';
import 'dart:typed_data';

import 'package:dextr/core/files/media_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading what an MP4 and a PDF say about themselves.
///
/// The MP4 fixtures are built box by box, which is also the documentation: a box
/// is four bytes of size, four of type, then its payload, and everything the
/// reader knows follows from that.
void main() {
  /// One box: size, type, payload.
  Uint8List box(String type, List<int> payload) {
    final size = 8 + payload.length;
    return Uint8List.fromList(<int>[
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      ...ascii.encode(type),
      ...payload,
    ]);
  }

  List<int> uint32(int value) => <int>[
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  Uint8List mp4(List<Uint8List> boxes) =>
      Uint8List.fromList(boxes.expand((b) => b).toList());

  group('mp4', () {
    test('duration and picture size come out of the header', () {
      final bytes = mp4(<Uint8List>[
        box('ftyp', ascii.encode('isom').toList()),
        box('moov', <int>[
          ...mvhdBox(timescale: 1000, duration: 125500),
          ...trakBox(width: 1920, height: 1080),
        ]),
      ]);

      final metadata = readMp4Metadata(bytes);

      expect(metadata, isNotNull);
      expect(metadata!.brand, 'isom');
      expect(metadata.duration, const Duration(milliseconds: 125500));
      expect(metadata.resolution, '1920 × 1080');
    });

    test('a file whose moov never arrives still reports its brand', () {
      // What a non-streaming MP4 looks like when only the head was fetched: the
      // brand is at the front, the rest is at the end and was never read.
      final bytes = mp4(<Uint8List>[
        box('ftyp', ascii.encode('mp42').toList()),
        box('mdat', List<int>.filled(64, 0)),
      ]);

      final metadata = readMp4Metadata(bytes);

      expect(metadata!.brand, 'mp42');
      expect(metadata.duration, isNull);
      expect(metadata.resolution, isNull);
    });

    test('a sound-only track reports no resolution', () {
      final bytes = mp4(<Uint8List>[
        box('ftyp', ascii.encode('M4A ').toList()),
        box('moov', <int>[
          ...mvhdBox(timescale: 44100, duration: 44100 * 30),
          // A `tkhd` of zero size is what an audio track writes.
          ...trakBox(width: 0, height: 0),
        ]),
      ]);

      final metadata = readMp4Metadata(bytes);

      expect(metadata!.duration, const Duration(seconds: 30));
      expect(metadata.resolution, isNull);
    });

    test('the unknown-duration sentinel is not reported as a length', () {
      final bytes = mp4(<Uint8List>[
        box('ftyp', ascii.encode('isom').toList()),
        box('moov', mvhdBox(timescale: 1000, duration: 0xFFFFFFFF)),
      ]);

      expect(readMp4Metadata(bytes)!.duration, isNull);
    });

    test('bytes that are not an MP4 are null, not a guess', () {
      expect(readMp4Metadata(Uint8List.fromList(<int>[1, 2, 3])), isNull);
      expect(
        readMp4Metadata(Uint8List.fromList(ascii.encode('not a video at all'))),
        isNull,
      );
    });

    test('a truncated box stops the walk instead of reading past it', () {
      // A box claiming 400 bytes in a 20-byte file.
      final bytes = Uint8List.fromList(<int>[
        ...uint32(400),
        ...ascii.encode('moov'),
        ...List<int>.filled(8, 0),
      ]);

      expect(() => readMp4Metadata(bytes), returnsNormally);
    });
  });

  group('durations', () {
    test('are written the way a player writes them', () {
      expect(formatMediaDuration(const Duration(seconds: 7)), '0:07');
      expect(formatMediaDuration(const Duration(minutes: 4, seconds: 7)), '4:07');
      expect(
        formatMediaDuration(const Duration(hours: 1, minutes: 2, seconds: 33)),
        '1:02:33',
      );
    });
  });

  group('pdf', () {
    Uint8List pdf(String body) => Uint8List.fromList(ascii.encode(body));

    test('the version comes off the first line', () {
      final facts = readPdfFacts(pdf('%PDF-1.7\n1 0 obj\n<<>>\nendobj\n'));

      expect(facts!.version, '1.7');
      expect(facts.encrypted, isFalse);
      expect(facts.linearised, isFalse);
    });

    test('an encrypted document says so', () {
      final facts = readPdfFacts(
        pdf('%PDF-1.4\ntrailer\n<< /Encrypt 9 0 R >>\n'),
      );

      expect(facts!.encrypted, isTrue);
    });

    test('linearisation is reported', () {
      final facts = readPdfFacts(pdf('%PDF-1.6\n<< /Linearized 1 >>\n'));

      expect(facts!.linearised, isTrue);
    });

    test('something that is not a PDF is null', () {
      expect(readPdfFacts(pdf('just text')), isNull);
      expect(readPdfFacts(Uint8List.fromList(<int>[0, 1])), isNull);
    });
  });
}

/// `moov` holds `mvhd` directly; the reader descends into it.
List<int> mvhdBox({required int timescale, required int duration}) {
  final payload = <int>[
    0, 0, 0, 0,
    ..._uint32(0),
    ..._uint32(0),
    ..._uint32(timescale),
    ..._uint32(duration),
  ];
  return _box('mvhd', payload);
}

/// A `trak` wrapping the `tkhd` the reader takes the picture size from.
List<int> trakBox({required int width, required int height}) {
  final tkhd = _box('tkhd', <int>[
    0, 0, 0, 0,
    ...List<int>.filled(72, 0),
    ..._uint32(width << 16),
    ..._uint32(height << 16),
  ]);
  return _box('trak', tkhd);
}

List<int> _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return <int>[..._uint32(size), ...ascii.encode(type), ...payload];
}

List<int> _uint32(int value) => <int>[
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];
