import 'dart:math' as math;

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/vector/projection.dart';

/// Where the camera is, and how to get a projected point onto the screen.
///
/// The whole of the 3D here is this class: the points are already reduced to
/// three coordinates by PCA, so drawing them is a rotation, a weak perspective
/// divide, and a sort. There is no scene graph and no shader — a scatter plot
/// of a few thousand marks does not need one, and everything stays in ordinary
/// Dart where it can be reasoned about.
class SpaceCamera {
  const SpaceCamera({
    this.yaw = 0.6,
    this.pitch = 0.35,
    this.zoom = 1,
    this.pan = Offset.zero,
  });

  /// Rotation about the vertical axis, in radians.
  final double yaw;

  /// Rotation about the horizontal axis, in radians.
  final double pitch;

  final double zoom;
  final Offset pan;

  /// The starting view: turned a little off-axis so the volume reads as a
  /// volume. Looking straight down an axis makes a 3D scatter look exactly like
  /// a 2D one, which defeats the point of it.
  static const SpaceCamera initial = SpaceCamera();

  /// Flat on, for a two-component projection where there is nothing to turn.
  static const SpaceCamera flat = SpaceCamera(yaw: 0, pitch: 0);

  SpaceCamera copyWith({
    double? yaw,
    double? pitch,
    double? zoom,
    Offset? pan,
  }) => SpaceCamera(
    yaw: yaw ?? this.yaw,
    pitch: pitch ?? this.pitch,
    zoom: zoom ?? this.zoom,
    pan: pan ?? this.pan,
  );

  /// Pitch is clamped rather than wrapped: past vertical the scene turns upside
  /// down, which is disorienting and never what a drag meant.
  SpaceCamera turnedBy(Offset delta) => copyWith(
    yaw: yaw + delta.dx * 0.01,
    pitch: (pitch + delta.dy * 0.01).clamp(-math.pi / 2 + 0.05, math.pi / 2 - 0.05),
  );
}

/// A point ready to draw: where it landed, and how far away it is.
class PlacedPoint {
  const PlacedPoint({
    required this.index,
    required this.screen,
    required this.depth,
    required this.scale,
  });

  /// Index into the projection's point list — and so into the space's points.
  final int index;

  final Offset screen;

  /// Distance from the camera after rotation. Bigger is further away.
  final double depth;

  /// How much nearness magnifies this mark, around 1.
  final double scale;
}

/// Turns a [VectorProjection] into screen positions for one camera and one box.
///
/// Kept apart from the painter because hit testing needs exactly the same
/// arithmetic: a click has to land on the mark that was drawn, and two
/// implementations of "where does this point go" is how a plot comes to
/// highlight something other than what was clicked.
class SpaceLayout {
  SpaceLayout({
    required this.projection,
    required this.size,
    required this.camera,
    required this.threeD,
  }) {
    final centre = projection.centre;
    _cx = centre.$1;
    _cy = centre.$2;
    _cz = centre.$3;

    // One scale for all axes, from the longest side: scaling them
    // independently would stretch the space and misrepresent the distances the
    // plot exists to show.
    final extent = projection.extent;
    _unit = extent <= 0 ? 1 : extent;

    final shortest = math.min(size.width, size.height);
    // Room for the marks at the edge, and for perspective to push a near point
    // outward without clipping it.
    _fit = (shortest - _padding * 2) / 2;
    _origin = Offset(size.width / 2, size.height / 2);

    _cosYaw = math.cos(camera.yaw);
    _sinYaw = math.sin(camera.yaw);
    _cosPitch = math.cos(camera.pitch);
    _sinPitch = math.sin(camera.pitch);
  }

  static const double _padding = 28;

  /// How strongly nearer points are magnified. Weak on purpose: enough for the
  /// eye to read depth, not so much that the front of the cloud swamps it.
  static const double _perspective = 0.35;

  final VectorProjection projection;
  final Size size;
  final SpaceCamera camera;

  /// False for a two-component projection, where the rotation is skipped
  /// entirely and the third axis does not exist.
  final bool threeD;

  late final double _cx, _cy, _cz;
  late final double _unit;
  late final double _fit;
  late final Offset _origin;
  late final double _cosYaw, _sinYaw, _cosPitch, _sinPitch;

  /// Every point, placed, sorted back to front.
  ///
  /// Painter's algorithm: with no depth buffer, drawing far points first is
  /// what makes a near one occlude them. Sorting a few thousand marks per frame
  /// is cheap next to painting them.
  List<PlacedPoint> placeAll() {
    final out = <PlacedPoint>[
      for (final point in projection.points) place(point),
    ];
    if (threeD) out.sort((a, b) => b.depth.compareTo(a.depth));
    return out;
  }

  PlacedPoint place(ProjectedPoint point) {
    // Centred on the cloud and scaled to the unit box, so the camera works the
    // same whatever units the projection came out in.
    final x = (point.x - _cx) / _unit;
    final y = (point.y - _cy) / _unit;
    final z = (point.z - _cz) / _unit;

    double sx, sy, depth;
    if (threeD) {
      // Yaw about the vertical, then pitch about the horizontal.
      final rx = x * _cosYaw + z * _sinYaw;
      final rz = -x * _sinYaw + z * _cosYaw;
      final ry = y * _cosPitch - rz * _sinPitch;
      depth = y * _sinPitch + rz * _cosPitch;

      // Weak perspective: one divide, no near plane to fall through.
      final shrink = 1 / (1 + _perspective * (depth + 1));
      sx = rx * shrink;
      sy = ry * shrink;
    } else {
      sx = x;
      sy = y;
      depth = 0;
    }

    final scale = threeD ? 1 / (1 + _perspective * (depth + 1)) * 1.35 : 1.0;

    return PlacedPoint(
      index: point.index,
      screen: Offset(
        _origin.dx + sx * _fit * camera.zoom + camera.pan.dx,
        // Negated: the projection's y grows upward and a canvas's grows down.
        _origin.dy - sy * _fit * camera.zoom + camera.pan.dy,
      ),
      depth: depth,
      scale: scale.clamp(0.55, 1.6),
    );
  }

  /// The eight corners of the cloud's bounding box, placed.
  ///
  /// Drawn as a wireframe because a scatter with nothing around it gives the
  /// eye no reference for the rotation — the cloud appears to wobble rather
  /// than turn. A box fixes that for the cost of twelve lines.
  List<Offset> boxCorners() {
    final b = projection.bounds;
    final corners = <ProjectedPoint>[
      for (final x in <double>[b.minX, b.maxX])
        for (final y in <double>[b.minY, b.maxY])
          for (final z in <double>[b.minZ, b.maxZ])
            ProjectedPoint(index: -1, x: x, y: y, z: z),
    ];
    return <Offset>[for (final c in corners) place(c).screen];
  }

  /// Which corners are joined, for [boxCorners] in the order it builds them.
  static const List<(int, int)> boxEdges = <(int, int)>[
    (0, 1), (0, 2), (0, 4), (1, 3), (1, 5), (2, 3),
    (2, 6), (3, 7), (4, 5), (4, 6), (5, 7), (6, 7),
  ];
}

/// The scatter itself: a canvas, the gestures that move it, and the keyboard
/// that reaches it.
class VectorSpaceView extends StatefulWidget {
  const VectorSpaceView({
    super.key,
    required this.projection,
    required this.threeD,
    required this.colourFor,
    required this.selected,
    required this.probe,
    required this.neighbours,
    required this.matches,
    required this.focusNode,
    required this.onSelected,
    required this.semanticsLabel,
    required this.semanticsValue,
  });

  final VectorProjection projection;
  final bool threeD;

  /// Palette slot for a point, or -1 for the default mark colour.
  final int Function(int index) colourFor;

  final int? selected;

  /// The point a text search settled on, drawn as the origin of the search.
  final int? probe;

  /// Points returned as near the probe.
  final Set<int> neighbours;

  /// Points that matched the text search but were not chosen.
  final Set<int> matches;

  final FocusNode focusNode;
  final ValueChanged<int> onSelected;
  final String semanticsLabel;
  final String semanticsValue;

  @override
  State<VectorSpaceView> createState() => _VectorSpaceViewState();
}

class _VectorSpaceViewState extends State<VectorSpaceView> {
  SpaceCamera _camera = SpaceCamera.initial;
  Size _size = Size.zero;

  /// True while a drag is panning rather than turning.
  bool _panning = false;

  /// The furthest a click may be from a mark and still be that mark, in logical
  /// pixels. Generous, because a 3-pixel dot is not a 3-pixel target.
  static const double _hitRadius = 18;

  @override
  void didUpdateWidget(VectorSpaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switching between the plane and the volume resets the camera: a yaw
    // carried over from 3D would leave a 2D plot looking skewed for no visible
    // reason, and the reverse leaves the volume face-on and looking flat.
    if (oldWidget.threeD != widget.threeD) {
      _camera = widget.threeD ? SpaceCamera.initial : SpaceCamera.flat;
    }
  }

  void _reset() => setState(() {
    _camera = widget.threeD ? SpaceCamera.initial : SpaceCamera.flat;
  });

  void _zoomBy(double factor, Offset focus) {
    final next = (_camera.zoom * factor).clamp(0.3, 40.0);
    if (next == _camera.zoom) return;
    final centre = Offset(_size.width / 2, _size.height / 2);
    setState(() {
      // Keeps whatever is under [focus] under it: the ratio of the old and new
      // zooms is applied to the vector from the focus to the current pan, which
      // is what makes wheel-zoom feel like it is zooming at the cursor rather
      // than at the middle of the box.
      _camera = _camera.copyWith(
        pan: focus - centre - (focus - centre - _camera.pan) * (next / _camera.zoom),
        zoom: next,
      );
    });
  }

  SpaceLayout get _layout => SpaceLayout(
    projection: widget.projection,
    size: _size,
    camera: _camera,
    threeD: widget.threeD,
  );

  void _selectAt(Offset local) {
    final layout = _layout;
    var best = -1;
    var bestDistance = double.infinity;
    for (final point in widget.projection.points) {
      final placed = layout.place(point);
      final d = (placed.screen - local).distanceSquared;
      if (d < bestDistance) {
        bestDistance = d;
        best = point.index;
      }
    }
    if (best >= 0 && bestDistance <= _hitRadius * _hitRadius) {
      widget.onSelected(best);
    }
  }

  /// Arrow keys walk the plot in projected order, which is the only ordering
  /// the marks have. Without this the plot is unreachable without a mouse.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final count = widget.projection.points.length;
    if (count == 0) return KeyEventResult.ignored;
    final current = widget.selected;
    final turning = HardwareKeyboard.instance.isShiftPressed;

    // Shift turns the camera; unmodified arrows move the selection. Without
    // that split a keyboard user could reach every point but never see the
    // volume from another side.
    if (turning && widget.threeD) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          setState(() => _camera = _camera.turnedBy(const Offset(-12, 0)));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          setState(() => _camera = _camera.turnedBy(const Offset(12, 0)));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          setState(() => _camera = _camera.turnedBy(const Offset(0, -12)));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          setState(() => _camera = _camera.turnedBy(const Offset(0, 12)));
          return KeyEventResult.handled;
      }
    }

    int? next;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowDown:
        next = current == null ? 0 : (current + 1) % count;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowUp:
        next = current == null ? count - 1 : (current - 1 + count) % count;
      case LogicalKeyboardKey.home:
        next = 0;
      case LogicalKeyboardKey.end:
        next = count - 1;
      case LogicalKeyboardKey.escape:
        _reset();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.add:
        _zoomBy(1.25, Offset(_size.width / 2, _size.height / 2));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.minus:
      case LogicalKeyboardKey.numpadSubtract:
        _zoomBy(1 / 1.25, Offset(_size.width / 2, _size.height / 2));
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
    widget.onSelected(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);

        return Focus(
          focusNode: widget.focusNode,
          onKeyEvent: _onKey,
          child: Semantics(
            container: true,
            label: widget.semanticsLabel,
            value: widget.semanticsValue,
            hint: widget.threeD
                ? 'Drag to turn, shift-drag to move, scroll to zoom. Arrow keys '
                      'move between points, shift with arrows turns the view, '
                      'escape resets it.'
                : 'Drag to move, scroll to zoom. Arrow keys move between '
                      'points, escape resets the view.',
            child: Listener(
              onPointerSignal: (signal) {
                if (signal is! PointerScrollEvent) return;
                _zoomBy(
                  signal.scrollDelta.dy > 0 ? 1 / 1.12 : 1.12,
                  signal.localPosition,
                );
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  widget.focusNode.requestFocus();
                  _selectAt(details.localPosition);
                },
                onPanStart: (_) {
                  // Shift moves the cloud; a plain drag turns it. In two
                  // dimensions there is nothing to turn, so every drag moves.
                  _panning = !widget.threeD ||
                      HardwareKeyboard.instance.isShiftPressed;
                },
                onPanUpdate: (details) => setState(() {
                  _camera = _panning
                      ? _camera.copyWith(pan: _camera.pan + details.delta)
                      : _camera.turnedBy(details.delta);
                }),
                onDoubleTap: _reset,
                child: CustomPaint(
                  painter: _SpacePainter(
                    layout: _layout,
                    colourFor: widget.colourFor,
                    selected: widget.selected,
                    probe: widget.probe,
                    neighbours: widget.neighbours,
                    matches: widget.matches,
                    threeD: widget.threeD,
                    grid: theme.color(AstryxColorToken.border),
                    mark: theme.color(AstryxColorToken.accent),
                    dim: theme.color(AstryxColorToken.textDisabled),
                    highlight: theme.color(AstryxColorToken.textPrimary),
                    probeColour: theme.color(AstryxColorToken.iconOrange),
                    palette: <Color>[
                      for (final token in spacePalette) theme.color(token),
                    ],
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The hues marks are coloured by when a payload field drives the colouring.
///
/// Eight is what the palette has distinct hues for, and about as many as a
/// legend can be scanned at a glance.
const List<AstryxColorToken> spacePalette = <AstryxColorToken>[
  AstryxColorToken.iconBlue,
  AstryxColorToken.iconOrange,
  AstryxColorToken.iconGreen,
  AstryxColorToken.iconPurple,
  AstryxColorToken.iconTeal,
  AstryxColorToken.iconPink,
  AstryxColorToken.iconYellow,
  AstryxColorToken.iconCyan,
];

class _SpacePainter extends CustomPainter {
  _SpacePainter({
    required this.layout,
    required this.colourFor,
    required this.selected,
    required this.probe,
    required this.neighbours,
    required this.matches,
    required this.threeD,
    required this.grid,
    required this.mark,
    required this.dim,
    required this.highlight,
    required this.probeColour,
    required this.palette,
  });

  final SpaceLayout layout;
  final int Function(int index) colourFor;
  final int? selected;
  final int? probe;
  final Set<int> neighbours;
  final Set<int> matches;
  final bool threeD;
  final Color grid;
  final Color mark;
  final Color dim;
  final Color highlight;
  final Color probeColour;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    _paintFrame(canvas, size);

    final placed = layout.placeAll();
    // A probe search is a question about a handful of points; the rest step
    // back — but only in opacity, never out of the picture, because the shape
    // of the space is the context that makes the answer mean anything.
    final focused = probe != null || neighbours.isNotEmpty || matches.isNotEmpty;

    Offset? probeAt;
    final neighbourAt = <Offset>[];

    final fill = Paint()..style = PaintingStyle.fill;
    for (final point in placed) {
      // Culled rather than clipped: at a deep zoom most of the collection is
      // off-canvas, and asking the canvas to reject each one costs more than
      // this test does.
      if (point.screen.dx < -12 ||
          point.screen.dy < -12 ||
          point.screen.dx > size.width + 12 ||
          point.screen.dy > size.height + 12) {
        continue;
      }

      final index = point.index;
      final isProbe = index == probe;
      final isSelected = index == selected;
      final isNeighbour = neighbours.contains(index);
      final isMatch = matches.contains(index);

      if (isProbe) probeAt = point.screen;
      if (isNeighbour) neighbourAt.add(point.screen);

      final slot = colourFor(index);
      var colour = slot < 0 ? mark : palette[slot % palette.length];
      if (isProbe) {
        colour = probeColour;
      } else if (focused && !isNeighbour && !isMatch && !isSelected) {
        colour = dim.withValues(alpha: 0.3);
      }

      // Depth is carried by size as well as by occlusion. Colour alone would
      // not do it: a viewer who cannot separate these hues still reads a near
      // point as the bigger one.
      final radius = (isProbe
              ? 7.0
              : isSelected
              ? 5.5
              : isNeighbour
              ? 4.5
              : 2.6) *
          point.scale;

      fill.color = colour;
      canvas.drawCircle(point.screen, radius, fill);

      if (isProbe || isNeighbour || isSelected) {
        canvas.drawCircle(
          point.screen,
          radius + (isProbe ? 5 : 3),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isProbe || isSelected ? 2 : 1.5
            ..color = isSelected && !isProbe ? highlight : colour,
        );
      }
    }

    // Drawn last so the threads sit over the cloud rather than under it: the
    // relationship between the probe and its neighbours is the thing being
    // asked about, and it should not be occluded by the points it is about.
    if (probeAt != null && neighbourAt.isNotEmpty) {
      final thread = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = probeColour.withValues(alpha: 0.45);
      for (final target in neighbourAt) {
        canvas.drawLine(probeAt, target, thread);
      }
    }
  }

  /// The reference the eye needs to read a rotation: a wireframe box in three
  /// dimensions, a pair of rules through the middle in two.
  void _paintFrame(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid.withValues(alpha: 0.5);

    if (!threeD) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        paint,
      );
      return;
    }

    final corners = layout.boxCorners();
    for (final (a, b) in SpaceLayout.boxEdges) {
      canvas.drawLine(corners[a], corners[b], paint);
    }
  }

  @override
  bool shouldRepaint(_SpacePainter old) => true;
}
