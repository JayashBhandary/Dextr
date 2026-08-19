import 'package:flutter/widgets.dart';

/// The application's mark, drawn from the same asset the launcher icon is built
/// from.
///
/// One widget rather than an `Image.asset` at each site: the asset path and the
/// decode budget are the two things that go wrong when a logo is pasted around,
/// and both live here. It brings its own dark plate, so a single asset reads on
/// a light surface and a dark one without a variant for each.
class DextrLogo extends StatelessWidget {
  const DextrLogo({required this.size, super.key, this.semanticsLabel});

  /// How big the mark is drawn, in logical pixels.
  ///
  /// The asset carries about a tenth of itself as transparent margin, so the
  /// plate that is actually visible is a little smaller than this.
  final double size;

  /// A name for a screen reader, for where the mark is the only thing saying
  /// which application this is — the collapsed rail, a title page.
  ///
  /// Null leaves the image as decoration, which is right wherever the name is
  /// written beside it: announcing "Dextr" twice in a row is worse than not
  /// announcing the picture.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final label = semanticsLabel;

    final image = Image.asset(
      'assets/icon/icon.png',
      width: size,
      height: size,
      // Decoded near the size it is drawn at. The source is 1024 square, and
      // holding that to paint a thumbnail is four megabytes of texture; three
      // times the drawn size covers a 3× display with nothing to spare.
      cacheWidth: (size * 3).round(),
      cacheHeight: (size * 3).round(),
      filterQuality: FilterQuality.medium,
      // The name, where there is one, is supplied by the wrapper below: an
      // image's own semantics cannot be a label and a container at once.
      excludeFromSemantics: true,
    );

    if (label == null) return image;
    return Semantics(label: label, image: true, child: image);
  }
}
