import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connectors/data_source.dart';
import '../connectors/vector/vector_types.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../core/vector/projection.dart';
import 'active_source_provider.dart';

/// A collection's vectors, and the plane they were flattened onto.
class VectorSpace {
  const VectorSpace({
    required this.info,
    required this.points,
    required this.projection,
  });

  final VectorSpaceInfo info;

  /// The sampled points, in the order [projection] indexes them.
  final List<VectorPoint> points;

  final VectorProjection projection;

  /// True when the sample stopped at the ceiling rather than at the end of the
  /// collection — the plot is then a window onto the space, not the whole of
  /// it, and the pane says so rather than letting it be assumed.
  bool get truncated {
    final total = info.count;
    return total != null && points.length < total;
  }
}

/// What identifies one projection: which collection, how much of it, and onto
/// how many axes.
///
/// A record rather than the [ContainerRef] itself, because a family key has to
/// compare by value and `ContainerRef` compares by identity — keying on it
/// would build a fresh provider on every rebuild and re-read the collection
/// each time the pane repainted.
///
/// `components` is part of the key so switching between the plane and the
/// volume re-projects rather than re-reads: the vectors are the same, but the
/// axes are not, and a two-component projection has no third axis to turn.
typedef VectorSpaceKey = ({String container, int sample, int components});

/// Reads a collection and projects it, off the UI thread.
///
/// `autoDispose`, so walking away from a tab lets a few thousand vectors go.
final vectorSpaceProvider = FutureProvider.autoDispose
    .family<VectorSpace, VectorSpaceKey>((ref, key) async {
      final source = await ref.watch(activeDataSourceProvider.future);
      if (source == null) throw const QueryError('No active connection');
      if (source is! VectorSearchable) {
        throw const CapabilityError(
          'This connection is not a vector database',
        );
      }

      final container = ContainerRef(name: key.container);
      final sw = Stopwatch()..start();

      // Concurrently, because they are independent questions asked of the same
      // connection: describing the space does not depend on having read it, and
      // running them in turn made every open pay two round trips end to end.
      final (info, points) = await (
        source.describeVectors(container),
        source.sampleVectors(container, limit: key.sample),
      ).wait;
      final read = sw.elapsedMilliseconds;

      if (points.isEmpty) {
        return VectorSpace(
          info: info,
          points: const <VectorPoint>[],
          projection: const VectorProjection.empty(),
        );
      }

      final projection = await projectVectors(<List<double>>[
        for (final p in points) p.vector,
      ], components: key.components);
      log.i(
        'Vector space ${key.container}: read ${points.length} points in '
        '${read}ms, projected in ${sw.elapsedMilliseconds - read}ms',
      );
      return VectorSpace(info: info, points: points, projection: projection);
    });
