/// Facts about a media file, read out of its own header.
///
/// No decoder involved. An MP4 is a tree of boxes — four bytes of length, four
/// of type, then either payload or more boxes — and the two that matter here say
/// how long the file is (`mvhd`) and how big its picture is (`tkhd`). A PDF says
/// its version on the first line and whether it is encrypted in its trailer.
///
/// This is what "support" honestly means for these formats in this application:
/// the facts, an accurate description of what cannot be shown, and a way to open
/// the file in something that can. Playing video or drawing PDF pages needs a
/// bundled decoder — pdfium, libmpv — and that is a dependency decision, not a
/// parsing one.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What an MP4-family header says about itself.
class Mp4Metadata {
  const Mp4Metadata({this.duration, this.width, this.height, this.brand});

  /// Total play time, or null when the header did not reach this far.
  final Duration? duration;

  /// The picture size of the first video track, in pixels.
  final int? width;
  final int? height;

  /// The `ftyp` brand — `isom`, `mp42`, `qt  ` — which is what actually says
  /// which flavour of the container this is.
  final String? brand;

  bool get isEmpty => duration == null && width == null && brand == null;

  /// The picture size as `1920 × 1080`, or null when it is not known.
  String? get resolution =>
      width == null || height == null ? null : '$width × $height';
}

/// Reads what it can from the head of an MP4.
///
/// Returns null only when the bytes are not an MP4 at all. A file whose `moov`
/// box sits at the end — anything not written for streaming — yields a result
/// with a brand and nothing else, which is the truth about what was read.
Mp4Metadata? readMp4Metadata(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String? brand;
  Duration? duration;
  int? width;
  int? height;

  void walk(int start, int end, int depth) {
    // Boxes nest a few levels at most; the bound is a guard against a malformed
    // file describing a cycle rather than a real limit.
    if (depth > 6) return;
    var offset = start;
    while (offset + 8 <= end) {
      var size = data.getUint32(offset);
      final type = _boxType(bytes, offset + 4);
      var headerSize = 8;
      if (size == 1) {
        // A 64-bit size follows the type.
        if (offset + 16 > end) return;
        size = data.getUint64(offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        // "To the end of the file."
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) {
        // Truncated or nonsense: stop rather than read past the box.
        return;
      }

      final payload = offset + headerSize;
      switch (type) {
        case 'ftyp':
          if (payload + 4 <= end) brand = _boxType(bytes, payload).trim();
        case 'moov':
        case 'trak':
        case 'mdia':
          walk(payload, offset + size, depth + 1);
        case 'mvhd':
          duration ??= _readDuration(data, payload, offset + size);
        case 'tkhd':
          final size2 = _readTrackSize(data, payload, offset + size);
          // The first track with a picture is the video one; a sound track
          // reports zero.
          if (size2 != null && width == null) {
            width = size2.$1;
            height = size2.$2;
          }
      }
      offset += size;
    }
  }

  try {
    walk(0, bytes.length, 0);
  } on RangeError {
    // A truncated head is expected — the caller only fetched the first few
    // megabytes — and whatever was read before it ran out still stands.
  }

  if (brand == null && duration == null) return null;
  return Mp4Metadata(
    duration: duration,
    width: width,
    height: height,
    brand: brand,
  );
}

/// `mvhd`: version, flags, times, then timescale and duration.
Duration? _readDuration(ByteData data, int payload, int end) {
  if (payload + 4 > end) return null;
  final version = data.getUint8(payload);
  final timescale = version == 1 ? payload + 20 : payload + 12;
  final durationAt = version == 1 ? payload + 24 : payload + 16;
  final needs = version == 1 ? durationAt + 8 : durationAt + 4;
  if (needs > end) return null;

  final scale = data.getUint32(timescale);
  if (scale == 0) return null;
  final units = version == 1
      ? data.getUint64(durationAt)
      : data.getUint32(durationAt);
  // 0xFFFFFFFF is the "unknown duration" sentinel a fragmented file writes.
  if (units == 0 || units == 0xFFFFFFFF) return null;
  return Duration(milliseconds: (units * 1000 / scale).round());
}

/// `tkhd`: the last eight bytes are width and height as 16.16 fixed point.
(int, int)? _readTrackSize(ByteData data, int payload, int end) {
  if (end - payload < 8) return null;
  final width = data.getUint32(end - 8) >> 16;
  final height = data.getUint32(end - 4) >> 16;
  if (width == 0 || height == 0) return null;
  return (width, height);
}

String _boxType(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return '';
  return String.fromCharCodes(bytes.sublist(offset, offset + 4));
}

/// What a PDF's own header and trailer say.
class PdfFacts {
  const PdfFacts({required this.version, this.encrypted = false, this.linearised = false});

  /// The `%PDF-1.7` on the first line, without the prefix.
  final String version;

  /// Whether the document declares an `/Encrypt` dictionary. Worth saying: an
  /// encrypted PDF is one that another application may refuse to open too.
  final bool encrypted;

  /// Whether the file is linearised for progressive loading.
  final bool linearised;
}

/// Reads the facts a PDF states about itself.
///
/// Deliberately narrow. A page count would need the cross-reference table, which
/// in a modern PDF is itself a compressed object stream, and counting `/Type
/// /Page` in the raw bytes gets it wrong on exactly the files people care about.
/// A number that is sometimes wrong is worse here than no number.
PdfFacts? readPdfFacts(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final head = ascii.decode(
    bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024),
    allowInvalid: true,
  );
  final match = RegExp(r'%PDF-(\d\.\d)').firstMatch(head);
  if (match == null) return null;

  // Both markers live near the start in any file this reader has: `/Encrypt` is
  // in the trailer, which a linearised PDF repeats at the front.
  final sample = ascii.decode(
    bytes.sublist(0, bytes.length < (1 << 20) ? bytes.length : 1 << 20),
    allowInvalid: true,
  );
  return PdfFacts(
    version: match.group(1)!,
    encrypted: sample.contains('/Encrypt'),
    linearised: sample.contains('/Linearized'),
  );
}

/// A duration as `4:07` or `1:02:33`.
String formatMediaDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  if (hours == 0) return '$minutes:$paddedSeconds';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$paddedSeconds';
}
