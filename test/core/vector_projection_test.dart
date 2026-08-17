import 'dart:math' as math;

import 'package:dextr/core/vector/projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// Points spread along one axis of a wide space, with a little variation on a
/// second and none anywhere else. PCA should find those two axes and ignore the
/// rest.
List<List<double>> _plane({int n = 200, int dimension = 64}) {
  return <List<double>>[
    for (var i = 0; i < n; i++)
      <double>[
        for (var j = 0; j < dimension; j++)
          switch (j) {
            0 => (i - n / 2) * 1.0,
            1 => math.sin(i.toDouble()) * 2,
            _ => 0.0,
          },
      ],
  ];
}

/// A cloud that genuinely occupies three axes, with a fourth that carries
/// nothing — so a three-component projection should keep everything and a
/// two-component one should visibly lose the third.
List<List<double>> _volume({int n = 300, int dimension = 32}) {
  return <List<double>>[
    for (var i = 0; i < n; i++)
      <double>[
        for (var j = 0; j < dimension; j++)
          switch (j) {
            0 => math.cos(i * 0.1) * 30,
            1 => math.sin(i * 0.1) * 20,
            2 => math.sin(i * 0.37) * 10,
            _ => 0.0,
          },
      ],
  ];
}

void main() {
  group('projectVectorsSync', () {
    test('recovers a plane hidden in a wide space', () {
      final result = projectVectorsSync(_plane(), components: 2);

      expect(result.points, hasLength(200));
      expect(result.dimension, 64);
      // Every scrap of the spread lives in the two axes that carry it, so a
      // correct projection loses essentially nothing.
      expect(result.explained, isNotNull);
      expect(result.explained, greaterThan(0.999));
    });

    test('keeps the order of the input', () {
      final result = projectVectorsSync(_plane(n: 20, dimension: 8));
      expect(
        result.points.map((p) => p.index),
        List<int>.generate(20, (i) => i),
      );
    });

    test('the leading axis follows the direction of greatest spread', () {
      // Built so component 0 runs -100…100 and component 1 barely moves; the
      // projected x should therefore be monotonic in i, up to a sign.
      final result = projectVectorsSync(_plane(n: 50, dimension: 16));
      final xs = result.points.map((p) => p.x).toList();
      final ascending = xs.last > xs.first;
      for (var i = 1; i < xs.length; i++) {
        expect(
          ascending ? xs[i] > xs[i - 1] : xs[i] < xs[i - 1],
          isTrue,
          reason: 'x should be monotonic along the dominant axis',
        );
      }
    });

    test('is deterministic — the same input projects the same way twice', () {
      final input = _plane(n: 40, dimension: 12);
      final a = projectVectorsSync(input);
      final b = projectVectorsSync(input);
      for (var i = 0; i < a.points.length; i++) {
        expect(a.points[i].x, closeTo(b.points[i].x, 1e-12));
        expect(a.points[i].y, closeTo(b.points[i].y, 1e-12));
        expect(a.points[i].z, closeTo(b.points[i].z, 1e-12));
      }
    });

    test('a space with no spread puts everything at the origin', () {
      final identical = List<List<double>>.generate(
        10,
        (_) => List<double>.filled(32, 0.5),
      );
      final result = projectVectorsSync(identical);

      expect(result.points, hasLength(10));
      expect(
        result.points.every((p) => p.x == 0 && p.y == 0 && p.z == 0),
        isTrue,
      );
      expect(result.explained, 0);
    });

    test('a single point needs no decomposition', () {
      final result = projectVectorsSync(<List<double>>[
        <double>[1, 2, 3],
      ]);
      expect(result.points, hasLength(1));
      expect(result.points.single.x, 0);
      expect(result.dimension, 3);
    });

    test('an empty space projects to nothing rather than throwing', () {
      final result = projectVectorsSync(const <List<double>>[]);
      expect(result.isEmpty, isTrue);
      expect(result.dimension, 0);
    });

    test('refuses a ragged space instead of inventing components', () {
      expect(
        () => projectVectorsSync(<List<double>>[
          <double>[1, 2, 3],
          <double>[1, 2],
        ]),
        throwsArgumentError,
      );
    });
  });

  group('three components', () {
    test('keeps a third axis the plane would have thrown away', () {
      final input = _volume();
      final flat = projectVectorsSync(input, components: 2);
      final volume = projectVectorsSync(input, components: 3);

      // The cloud really is three-dimensional, so the volume keeps essentially
      // all of it and the plane demonstrably does not.
      expect(volume.explained, greaterThan(0.999));
      expect(flat.explained, lessThan(0.98));
      expect(volume.explained!, greaterThan(flat.explained!));
    });

    test('a two-component projection leaves z flat', () {
      final result = projectVectorsSync(_volume(), components: 2);
      expect(result.components, 2);
      expect(result.points.every((p) => p.z == 0), isTrue);
    });

    test('a three-component projection actually uses z', () {
      final result = projectVectorsSync(_volume(), components: 3);
      expect(result.components, 3);
      expect(result.points.any((p) => p.z.abs() > 1e-6), isTrue);
    });

    test('all three axes are mutually orthogonal', () {
      // If a later component collapsed onto an earlier one the cloud would
      // flatten onto a line or a plane, which is exactly what the repeated
      // orthogonalisation in the power iteration is there to prevent.
      final result = projectVectorsSync(_volume(), components: 3);

      double correlation(
        double Function(ProjectedPoint) a,
        double Function(ProjectedPoint) b,
      ) {
        var dot = 0.0, na = 0.0, nb = 0.0;
        for (final p in result.points) {
          dot += a(p) * b(p);
          na += a(p) * a(p);
          nb += b(p) * b(p);
        }
        if (na == 0 || nb == 0) return 0;
        return dot / (math.sqrt(na) * math.sqrt(nb));
      }

      expect(correlation((p) => p.x, (p) => p.y).abs(), lessThan(0.05));
      expect(correlation((p) => p.x, (p) => p.z).abs(), lessThan(0.05));
      expect(correlation((p) => p.y, (p) => p.z).abs(), lessThan(0.05));
    });

    test('a space with fewer axes than the screen does not invent one', () {
      // Two-dimensional data cannot fill three components, and asking for
      // three must not produce a fabricated third.
      final input = <List<double>>[
        for (var i = 0; i < 40; i++)
          <double>[math.cos(i * 0.2), math.sin(i * 0.2)],
      ];
      final result = projectVectorsSync(input, components: 3);
      expect(result.points.every((p) => p.z.abs() < 1e-9), isTrue);
    });
  });

  group('bounds', () {
    test('pads an axis with no extent so a caller never divides by zero', () {
      // Every point on one horizontal line: the other axes have no extent.
      final result = projectVectorsSync(<List<double>>[
        for (var i = 0; i < 10; i++) <double>[i.toDouble(), 0, 0],
      ]);
      final b = result.bounds;
      expect(b.maxX - b.minX, greaterThan(0));
      expect(b.maxY - b.minY, greaterThan(0));
      expect(b.maxZ - b.minZ, greaterThan(0));
    });

    test('an empty projection still reports a usable box', () {
      const empty = VectorProjection.empty();
      final b = empty.bounds;
      expect(b.maxX, greaterThan(b.minX));
      expect(b.maxY, greaterThan(b.minY));
      expect(b.maxZ, greaterThan(b.minZ));
    });

    test('extent is the longest side, so the axes keep their proportions', () {
      final result = projectVectorsSync(_volume(), components: 3);
      final b = result.bounds;
      expect(
        result.extent,
        closeTo(
          math.max(b.maxX - b.minX, math.max(b.maxY - b.minY, b.maxZ - b.minZ)),
          1e-9,
        ),
      );
    });

    test('the centre sits in the middle of the box', () {
      final result = projectVectorsSync(_volume(), components: 3);
      final b = result.bounds;
      final (cx, cy, cz) = result.centre;
      expect(cx, closeTo((b.minX + b.maxX) / 2, 1e-9));
      expect(cy, closeTo((b.minY + b.maxY) / 2, 1e-9));
      expect(cz, closeTo((b.minZ + b.maxZ) / 2, 1e-9));
    });
  });

  group('projectVectors', () {
    test('matches the synchronous result when it runs off-isolate', () async {
      // Over the 256-point threshold, so this genuinely crosses an isolate.
      final input = _plane(n: 300, dimension: 16);
      final async = await projectVectors(input);
      final sync = projectVectorsSync(input);

      expect(async.points, hasLength(sync.points.length));
      expect(async.explained, closeTo(sync.explained!, 1e-9));
      for (var i = 0; i < sync.points.length; i++) {
        expect(async.points[i].x, closeTo(sync.points[i].x, 1e-9));
        expect(async.points[i].y, closeTo(sync.points[i].y, 1e-9));
        expect(async.points[i].z, closeTo(sync.points[i].z, 1e-9));
      }
    });

    test('carries the component count across the isolate', () async {
      final result = await projectVectors(_volume(n: 400), components: 2);
      expect(result.components, 2);
      expect(result.points.every((p) => p.z == 0), isTrue);
    });
  });
}
