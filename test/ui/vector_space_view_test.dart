import 'dart:math' as math;

import 'package:dextr/core/vector/projection.dart';
import 'package:dextr/ui/workspace/vector_space_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The camera and the layout are the whole of the 3D: everything the painter
/// draws and everything a click resolves against comes through them, so they
/// are worth pinning down without a widget in the way.
VectorProjection _cube() => const VectorProjection(
  points: <ProjectedPoint>[
    ProjectedPoint(index: 0, x: -1, y: -1, z: -1),
    ProjectedPoint(index: 1, x: 1, y: -1, z: -1),
    ProjectedPoint(index: 2, x: -1, y: 1, z: -1),
    ProjectedPoint(index: 3, x: 1, y: 1, z: -1),
    ProjectedPoint(index: 4, x: -1, y: -1, z: 1),
    ProjectedPoint(index: 5, x: 1, y: -1, z: 1),
    ProjectedPoint(index: 6, x: -1, y: 1, z: 1),
    ProjectedPoint(index: 7, x: 1, y: 1, z: 1),
  ],
  explained: 1,
  dimension: 8,
  components: 3,
);

SpaceLayout _layout({
  SpaceCamera camera = SpaceCamera.flat,
  bool threeD = true,
  VectorProjection? projection,
}) => SpaceLayout(
  projection: projection ?? _cube(),
  size: const Size(400, 400),
  camera: camera,
  threeD: threeD,
);

void main() {
  group('two dimensions', () {
    test('ignores the third axis entirely', () {
      // Two points differing only in z must land on the same spot: in a plane
      // there is no depth for them to differ in.
      const projection = VectorProjection(
        points: <ProjectedPoint>[
          ProjectedPoint(index: 0, x: 1, y: 1, z: -5),
          ProjectedPoint(index: 1, x: 1, y: 1, z: 5),
        ],
        explained: 1,
        dimension: 3,
        components: 2,
      );
      final layout = _layout(projection: projection, threeD: false);
      final a = layout.place(projection.points[0]);
      final b = layout.place(projection.points[1]);

      expect(a.screen.dx, closeTo(b.screen.dx, 1e-9));
      expect(a.screen.dy, closeTo(b.screen.dy, 1e-9));
      expect(a.depth, 0);
      expect(a.scale, 1.0);
    });

    test('flips y, because a canvas grows downward and the maths does not', () {
      const projection = VectorProjection(
        points: <ProjectedPoint>[
          ProjectedPoint(index: 0, x: 0, y: -1),
          ProjectedPoint(index: 1, x: 0, y: 1),
        ],
        explained: 1,
        dimension: 2,
        components: 2,
      );
      final layout = _layout(projection: projection, threeD: false);
      final low = layout.place(projection.points[0]);
      final high = layout.place(projection.points[1]);

      // The point with the larger y is nearer the top of the screen, which is
      // the smaller dy.
      expect(high.screen.dy, lessThan(low.screen.dy));
    });

    test('leaves the ordering alone — there is no depth to sort by', () {
      final placed = _layout(threeD: false).placeAll();
      expect(placed.map((p) => p.index), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

  group('three dimensions', () {
    test('turning the camera moves the points', () {
      final still = _layout(camera: const SpaceCamera(yaw: 0, pitch: 0));
      final turned = _layout(camera: const SpaceCamera(yaw: 0.8, pitch: 0.3));

      final before = still.place(_cube().points.first).screen;
      final after = turned.place(_cube().points.first).screen;
      expect((before - after).distance, greaterThan(1));
    });

    test('a yaw of zero leaves x where a plane would put it', () {
      // With no rotation the only difference from 2D is the perspective
      // divide, which is symmetric about the origin — so a point on the x axis
      // stays on the horizontal centre line.
      const projection = VectorProjection(
        points: <ProjectedPoint>[ProjectedPoint(index: 0, x: 1, y: 0)],
        explained: 1,
        dimension: 3,
        components: 3,
      );
      final placed = _layout(
        projection: projection,
        camera: const SpaceCamera(yaw: 0, pitch: 0),
      ).place(projection.points.first);
      expect(placed.screen.dy, closeTo(200, 1e-6));
    });

    test('sorts back to front, so a near point paints over a far one', () {
      // No depth buffer: painter's algorithm is the only thing making
      // occlusion work, and it depends on this ordering.
      final placed = _layout(
        camera: const SpaceCamera(yaw: 0.6, pitch: 0.35),
      ).placeAll();
      for (var i = 1; i < placed.length; i++) {
        expect(
          placed[i].depth,
          lessThanOrEqualTo(placed[i - 1].depth),
          reason: 'furthest first',
        );
      }
    });

    test('nearer points are drawn larger', () {
      final placed = _layout(
        camera: const SpaceCamera(yaw: 0.6, pitch: 0.35),
      ).placeAll();
      // Sorted furthest first, so the last is the nearest.
      expect(placed.last.scale, greaterThan(placed.first.scale));
    });

    test('the depth cue stays within bounds even at the extremes', () {
      for (final camera in const <SpaceCamera>[
        SpaceCamera(yaw: 0, pitch: 0),
        SpaceCamera(yaw: 3, pitch: 1.5),
        SpaceCamera(yaw: -3, pitch: -1.5, zoom: 30),
      ]) {
        for (final placed in _layout(camera: camera).placeAll()) {
          expect(placed.scale, inInclusiveRange(0.55, 1.6));
          expect(placed.screen.dx.isFinite, isTrue);
          expect(placed.screen.dy.isFinite, isTrue);
        }
      }
    });

    test('the wireframe box has eight corners and twelve real edges', () {
      final corners = _layout().boxCorners();
      expect(corners, hasLength(8));
      expect(SpaceLayout.boxEdges, hasLength(12));
      for (final (a, b) in SpaceLayout.boxEdges) {
        expect(a, inInclusiveRange(0, 7));
        expect(b, inInclusiveRange(0, 7));
        expect(a, isNot(b));
      }
    });
  });

  group('SpaceCamera', () {
    test('a drag turns it', () {
      final turned = SpaceCamera.initial.turnedBy(const Offset(100, 50));
      expect(turned.yaw, greaterThan(SpaceCamera.initial.yaw));
      expect(turned.pitch, greaterThan(SpaceCamera.initial.pitch));
    });

    test('pitch stops short of vertical rather than tumbling past it', () {
      // Past vertical the scene turns upside down, which is disorienting and
      // never what a drag meant.
      var camera = SpaceCamera.initial;
      for (var i = 0; i < 100; i++) {
        camera = camera.turnedBy(const Offset(0, 100));
      }
      expect(camera.pitch, lessThan(math.pi / 2));
      expect(camera.pitch, greaterThan(0));

      for (var i = 0; i < 200; i++) {
        camera = camera.turnedBy(const Offset(0, -100));
      }
      expect(camera.pitch, greaterThan(-math.pi / 2));
    });

    test('yaw is free to keep turning', () {
      var camera = SpaceCamera.initial;
      for (var i = 0; i < 50; i++) {
        camera = camera.turnedBy(const Offset(100, 0));
      }
      expect(camera.yaw, greaterThan(math.pi));
    });

    test('the flat camera is square on, for a plane with nothing to turn', () {
      expect(SpaceCamera.flat.yaw, 0);
      expect(SpaceCamera.flat.pitch, 0);
    });

    test('the initial camera is off-axis, so a volume reads as one', () {
      // Looking straight down an axis makes a 3D scatter look exactly like a
      // 2D one, which defeats the point of drawing it in three.
      expect(SpaceCamera.initial.yaw, isNot(0));
      expect(SpaceCamera.initial.pitch, isNot(0));
    });
  });

  group('degenerate input', () {
    test('an empty projection places nothing and does not divide by zero', () {
      final layout = SpaceLayout(
        projection: const VectorProjection.empty(),
        size: const Size(400, 400),
        camera: SpaceCamera.initial,
        threeD: true,
      );
      expect(layout.placeAll(), isEmpty);
      // The box still has to be finite, because it is drawn regardless.
      for (final corner in layout.boxCorners()) {
        expect(corner.dx.isFinite, isTrue);
        expect(corner.dy.isFinite, isTrue);
      }
    });

    test('every point identical still lands somewhere finite', () {
      const projection = VectorProjection(
        points: <ProjectedPoint>[
          ProjectedPoint(index: 0, x: 0, y: 0, z: 0),
          ProjectedPoint(index: 1, x: 0, y: 0, z: 0),
        ],
        explained: 0,
        dimension: 4,
        components: 3,
      );
      for (final placed in _layout(projection: projection).placeAll()) {
        expect(placed.screen.dx.isFinite, isTrue);
        expect(placed.screen.dy.isFinite, isTrue);
      }
    });

    test('a zero-sized box does not produce infinities', () {
      final layout = SpaceLayout(
        projection: _cube(),
        size: Size.zero,
        camera: SpaceCamera.initial,
        threeD: true,
      );
      for (final placed in layout.placeAll()) {
        expect(placed.screen.dx.isFinite, isTrue);
        expect(placed.screen.dy.isFinite, isTrue);
      }
    });
  });
}
