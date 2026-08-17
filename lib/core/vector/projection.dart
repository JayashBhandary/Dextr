/// Flattening a high-dimensional space onto something you can look at.
///
/// A vector space is 384, 768 or 1536 components wide and a screen is two or
/// three, so something has to choose which. This uses PCA: the plane — or the
/// volume — through the data that keeps as much of its spread as possible,
/// which is the projection that loses the least. Points that were close in the
/// original space usually land close here, and — unlike t-SNE or UMAP — the
/// axes mean something fixed, so re-projecting the same collection twice gives
/// the same picture.
///
/// The eigenvectors are found by power iteration against the data matrix
/// directly. Forming the covariance matrix would be a 1536 × 1536 allocation
/// and O(n·d²) to fill; multiplying through X and Xᵀ in turn gets the same
/// answer in O(n·d) per iteration with nothing held but a few vectors.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// One point in the projected space, and where it came from.
class ProjectedPoint {
  const ProjectedPoint({
    required this.index,
    required this.x,
    required this.y,
    this.z = 0,
  });

  /// Position in the list that was projected, so the caller can map back to
  /// whatever it holds alongside — a `VectorPoint`, usually.
  final int index;

  final double x;
  final double y;

  /// The third component. Zero throughout a two-component projection, so a
  /// caller that only draws a plane can ignore it.
  final double z;
}

/// A projected space, plus what it cost.
class VectorProjection {
  const VectorProjection({
    required this.points,
    required this.explained,
    required this.dimension,
    required this.components,
  });

  const VectorProjection.empty()
    : points = const <ProjectedPoint>[],
      explained = null,
      dimension = 0,
      components = 0;

  final List<ProjectedPoint> points;

  /// Roughly how much of the data's spread the projection kept, 0…1.
  ///
  /// Worth showing: a projection that kept 12% is a picture of very little, and
  /// clusters read into it are as likely to be artefacts of the flattening as
  /// structure in the data. Null when it could not be computed — fewer than two
  /// points, or a space with no spread at all.
  final double? explained;

  /// The width of the space that was flattened.
  final int dimension;

  /// How many components were kept: 2 or 3.
  final int components;

  bool get isEmpty => points.isEmpty;

  /// The bounding box, as (min, max) along each axis. A degenerate axis — every
  /// point on one line or plane — is padded so a caller scaling to it never
  /// divides by zero.
  ({double minX, double minY, double minZ, double maxX, double maxY, double maxZ})
  get bounds {
    if (points.isEmpty) {
      return (minX: -1, minY: -1, minZ: -1, maxX: 1, maxY: 1, maxZ: 1);
    }
    var minX = points.first.x, maxX = minX;
    var minY = points.first.y, maxY = minY;
    var minZ = points.first.z, maxZ = minZ;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
      if (p.z < minZ) minZ = p.z;
      if (p.z > maxZ) maxZ = p.z;
    }
    if (maxX - minX < 1e-12) {
      minX -= 0.5;
      maxX += 0.5;
    }
    if (maxY - minY < 1e-12) {
      minY -= 0.5;
      maxY += 0.5;
    }
    if (maxZ - minZ < 1e-12) {
      minZ -= 0.5;
      maxZ += 0.5;
    }
    return (
      minX: minX,
      minY: minY,
      minZ: minZ,
      maxX: maxX,
      maxY: maxY,
      maxZ: maxZ,
    );
  }

  /// The longest side of the box, which is what a caller scales by to keep the
  /// three axes in proportion to one another.
  double get extent {
    final b = bounds;
    return math.max(
      b.maxX - b.minX,
      math.max(b.maxY - b.minY, b.maxZ - b.minZ),
    );
  }

  /// The middle of the box.
  (double, double, double) get centre {
    final b = bounds;
    return (
      (b.minX + b.maxX) / 2,
      (b.minY + b.maxY) / 2,
      (b.minZ + b.maxZ) / 2,
    );
  }
}

/// How hard to work at finding the axes.
///
/// Power iteration converges fast when the leading components are well
/// separated, which for embeddings they usually are. Sixty-four passes is far
/// past the point where the picture stops changing; the cost of overshooting is
/// milliseconds, and the cost of undershooting is a plot that rotates slightly
/// every time it is recomputed.
const int _iterations = 64;

/// Projects [vectors] onto their first [components] principal components.
///
/// Runs on the calling isolate. For anything a user is waiting on, prefer
/// [projectVectors], which does the same work off the UI thread.
VectorProjection projectVectorsSync(
  List<List<double>> vectors, {
  int components = 3,
}) {
  assert(components == 2 || components == 3, 'a screen has two or three axes');
  if (vectors.isEmpty) return const VectorProjection.empty();
  final dimension = vectors.first.length;
  if (dimension == 0) return const VectorProjection.empty();

  // A ragged input is a bug in a backend rather than something to project:
  // padding short vectors would invent components and truncating long ones
  // would silently drop them.
  final n = vectors.length;
  for (final v in vectors) {
    if (v.length != dimension) {
      throw ArgumentError(
        'Cannot project a mixed-width space: found ${v.length}-component '
        'vectors alongside $dimension-component ones',
      );
    }
  }

  // A space narrower than the screen has no axes to spare; the components it
  // does have are used and the rest come out flat.
  final kept = math.min(components, math.min(n - 1, dimension));

  // A one-point space has no spread at all.
  if (kept < 1) {
    return VectorProjection(
      points: <ProjectedPoint>[
        for (var i = 0; i < n; i++) ProjectedPoint(index: i, x: 0, y: 0),
      ],
      explained: null,
      dimension: dimension,
      components: components,
    );
  }

  // Packed flat and centred in place. Float64List rather than List<double> for
  // the unboxed arithmetic; at n=5000, d=1536 this is the difference between a
  // projection that feels instant and one that does not.
  final data = Float64List(n * dimension);
  for (var i = 0; i < n; i++) {
    final row = vectors[i];
    for (var j = 0; j < dimension; j++) {
      data[i * dimension + j] = row[j];
    }
  }
  final mean = Float64List(dimension);
  for (var i = 0; i < n; i++) {
    final base = i * dimension;
    for (var j = 0; j < dimension; j++) {
      mean[j] += data[base + j];
    }
  }
  for (var j = 0; j < dimension; j++) {
    mean[j] /= n;
  }
  var totalVariance = 0.0;
  for (var i = 0; i < n; i++) {
    final base = i * dimension;
    for (var j = 0; j < dimension; j++) {
      final centred = data[base + j] - mean[j];
      data[base + j] = centred;
      totalVariance += centred * centred;
    }
  }

  // Every point identical: there is no shape to find, and every mark belongs at
  // the origin rather than scattered by floating-point noise.
  if (totalVariance <= 1e-24) {
    return VectorProjection(
      points: <ProjectedPoint>[
        for (var i = 0; i < n; i++) ProjectedPoint(index: i, x: 0, y: 0),
      ],
      explained: 0,
      dimension: dimension,
      components: components,
    );
  }

  final axes = <Float64List>[];
  for (var c = 0; c < kept; c++) {
    axes.add(_leadingComponent(data, n, dimension, orthogonalTo: axes));
  }

  final points = <ProjectedPoint>[];
  var keptVariance = 0.0;
  for (var i = 0; i < n; i++) {
    final base = i * dimension;
    final coords = Float64List(3);
    for (var c = 0; c < axes.length; c++) {
      final axis = axes[c];
      var sum = 0.0;
      for (var j = 0; j < dimension; j++) {
        sum += data[base + j] * axis[j];
      }
      coords[c] = sum;
      keptVariance += sum * sum;
    }
    points.add(
      ProjectedPoint(index: i, x: coords[0], y: coords[1], z: coords[2]),
    );
  }

  return VectorProjection(
    points: points,
    explained: (keptVariance / totalVariance).clamp(0.0, 1.0),
    dimension: dimension,
    components: components,
  );
}

/// Power iteration for the leading eigenvector of XᵀX.
///
/// [orthogonalTo] holds the components already found, and they are projected
/// out on every pass rather than only at the start: floating-point drift pulls
/// a later component back towards an earlier one otherwise, and two components
/// that are nearly the same axis collapse the picture onto a line.
Float64List _leadingComponent(
  Float64List data,
  int n,
  int dimension, {
  required List<Float64List> orthogonalTo,
}) {
  var v = _seedVector(dimension, orthogonalTo.length);
  for (final axis in orthogonalTo) {
    _orthogonalise(v, axis);
  }
  _normalise(v);

  final projected = Float64List(n);
  final next = Float64List(dimension);

  for (var iteration = 0; iteration < _iterations; iteration++) {
    // Xv, then Xᵀ(Xv) — the covariance matrix's action without the matrix.
    for (var i = 0; i < n; i++) {
      final base = i * dimension;
      var sum = 0.0;
      for (var j = 0; j < dimension; j++) {
        sum += data[base + j] * v[j];
      }
      projected[i] = sum;
    }
    next.fillRange(0, dimension, 0);
    for (var i = 0; i < n; i++) {
      final base = i * dimension;
      final weight = projected[i];
      if (weight == 0) continue;
      for (var j = 0; j < dimension; j++) {
        next[j] += data[base + j] * weight;
      }
    }

    for (final axis in orthogonalTo) {
      _orthogonalise(next, axis);
    }
    if (!_normalise(next)) {
      // The iterate collapsed: the data has no further axis worth speaking of.
      // Whatever was last held is as good an answer as exists.
      break;
    }
    v = Float64List.fromList(next);
  }
  return v;
}

/// A fixed starting vector, so the same collection always projects the same
/// way. A random seed would rotate and mirror the plot between runs, which
/// reads as the data having changed when only the seed did.
///
/// [offset] varies it per component so a later axis does not start life
/// pointing exactly where an earlier one was found, which leaves the
/// orthogonalisation with nothing but rounding error to work from.
Float64List _seedVector(int dimension, int offset) {
  final v = Float64List(dimension);
  for (var j = 0; j < dimension; j++) {
    // Irrational stride, so the seed is never accidentally orthogonal to the
    // component being looked for — which would leave power iteration with
    // nothing to amplify.
    v[j] = math.sin((j + 1 + offset * 7) * 1.6180339887498949);
  }
  return v;
}

void _orthogonalise(Float64List v, Float64List basis) {
  var dot = 0.0;
  for (var j = 0; j < v.length; j++) {
    dot += v[j] * basis[j];
  }
  for (var j = 0; j < v.length; j++) {
    v[j] -= dot * basis[j];
  }
}

/// Scales [v] to unit length. False when it had none to scale.
bool _normalise(Float64List v) {
  var sum = 0.0;
  for (var j = 0; j < v.length; j++) {
    sum += v[j] * v[j];
  }
  if (sum <= 1e-24) return false;
  final norm = math.sqrt(sum);
  for (var j = 0; j < v.length; j++) {
    v[j] /= norm;
  }
  return true;
}

/// [projectVectorsSync], on its own isolate.
///
/// Five thousand 1536-component vectors is around two billion multiplications
/// for three components, which is a second or two — long enough that doing it
/// inline would drop frames and freeze the pane it is drawing into.
Future<VectorProjection> projectVectors(
  List<List<double>> vectors, {
  int components = 3,
}) {
  // Below this the work is under a frame and the isolate handshake costs more
  // than the maths does.
  if (vectors.length < 256) {
    return Future<VectorProjection>.value(
      projectVectorsSync(vectors, components: components),
    );
  }
  return Isolate.run(
    () => projectVectorsSync(vectors, components: components),
  );
}
