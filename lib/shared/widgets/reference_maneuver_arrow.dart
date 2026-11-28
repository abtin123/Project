import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'solid_arrow.dart';

class ReferenceManeuverArrow extends StatelessWidget {
  const ReferenceManeuverArrow({
    super.key,
    required this.kind,
    required this.color,
    this.outlineColor = Colors.white,
    this.borderColor = Colors.black,
    this.ghostOpacity = .28,
    this.scale = 1,
    this.thickness = .72,
  });

  final String kind;
  final Color color;
  final Color outlineColor;
  final Color borderColor;
  final double ghostOpacity;
  final double scale;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: CustomPaint(
        size: Size.infinite,
        painter: ManeuverArrowPainter(
          kind: kind,
          thickness: thickness,
          style: SolidArrowStyle(
            fill: color,
            outline: outlineColor,
            border: borderColor,
            ghostOpacity: ghostOpacity,
          ),
        ),
      ),
    );
  }
}

class ManeuverArrowPainter extends CustomPainter {
  const ManeuverArrowPainter({
    required this.kind,
    required this.style,
    required this.thickness,
  });

  final String kind;
  final SolidArrowStyle style;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _geometryFor(kind) ?? _geometryFor('straight')!;
    final side = math.min(size.width, size.height);
    if (side <= 0) return;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / 112);
    canvas.translate(6, 6);

    final w = (18.0 * thickness / .72).clamp(8.0, 22.0).toDouble();
    final m = ArrowMetrics(w);

    if (geo.ghosts.isNotEmpty || geo.bars.isNotEmpty) {
      paintGhostLayer(
        canvas,
        const Rect.fromLTRB(-6, -6, 106, 106),
        style.ghostOpacity,
        () {
          final flat = Paint()..color = style.fill;
          for (final r in geo.bars) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(r, const Radius.circular(4)),
              flat,
            );
          }
          for (final g in geo.ghosts) {
            paintArrowFlat(canvas, ArrowShape(g, m), style.fill);
          }
        },
      );
    }
    paintSolidArrow(canvas, ArrowShape(geo.active, m), style);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ManeuverArrowPainter old) =>
      old.kind != kind ||
      old.thickness != thickness ||
      old.style.fill != style.fill ||
      old.style.outline != style.outline ||
      old.style.border != style.border ||
      old.style.ghostOpacity != style.ghostOpacity;
}

class _Geo {
  const _Geo(this.active, {this.ghosts = const [], this.bars = const []});
  final Path active;
  final List<Path> ghosts;
  final List<Rect> bars;
}

class _PathBuilder {
  _PathBuilder(this.mirror);
  final bool mirror;
  final Path path = Path();

  double _x(double x) => mirror ? 100 - x : x;
  void m(double x, double y) => path.moveTo(_x(x), y);
  void l(double x, double y) => path.lineTo(_x(x), y);
  void c(double x1, double y1, double x2, double y2, double x, double y) =>
      path.cubicTo(_x(x1), y1, _x(x2), y2, _x(x), y);
  void arc(double x, double y, double r, {required bool clockwise}) =>
      path.arcToPoint(
        Offset(_x(x), y),
        radius: Radius.circular(r),
        clockwise: mirror ? !clockwise : clockwise,
      );
}

Path _build(bool mirror, void Function(_PathBuilder b) f) {
  final b = _PathBuilder(mirror);
  f(b);
  return b.path;
}

Path _straight() => _build(false, (b) {
      b.m(50, 96);
      b.l(50, 34);
    });

Path _slight(bool right) => _build(right, (b) {
      b.m(60, 96);
      b.l(60, 68);
      b.c(60, 54, 55, 48, 50, 38);
    });

Path _turn(bool right) => _build(right, (b) {
      b.m(76, 96);
      b.l(76, 68);
      b.c(76, 56, 70, 48, 58, 42);
    });

Path _sharp(bool right) => _build(right, (b) {
      b.m(76, 96);
      b.l(76, 58);
      b.c(76, 46, 68, 44, 58, 48);
    });

Path _uTurn(bool left) => _build(left, (b) {
      b.m(26, 96);
      b.l(26, 50);
      b.arc(74, 50, 24, clockwise: true);
      b.l(74, 58);
    });

Path _forkArm(bool right) => _build(right, (b) {
      b.m(50, 96);
      b.l(50, 72);
      b.c(50, 58, 42, 50, 34, 34);
    });

Path _laneShift(bool right) => _build(right, (b) {
      b.m(66, 96);
      b.l(66, 80);
      b.c(66, 72, 62, 68, 58, 64);
      b.l(42, 48);
      b.c(38, 44, 34, 40, 34, 32);
    });

const List<Rect> _lanes = [
  Rect.fromLTRB(23, 36, 45, 96),
  Rect.fromLTRB(55, 36, 77, 96),
];

_Geo? _geometryFor(String kind) {
  switch (kind) {
    case 'straight':
      return _Geo(_straight());
    case 'slight_left':
      return _Geo(_slight(false));
    case 'slight_right':
      return _Geo(_slight(true));
    case 'left':
      return _Geo(_turn(false));
    case 'right':
      return _Geo(_turn(true));
    case 'sharp_left':
      return _Geo(_sharp(false));
    case 'sharp_right':
      return _Geo(_sharp(true));
    case 'u_turn_right':
      return _Geo(_uTurn(false));
    case 'u_turn_left':
      return _Geo(_uTurn(true));
    case 'fork_left':
    case 'exit_left':
      return _Geo(_forkArm(false), ghosts: [_forkArm(true)]);
    case 'fork_right':
    case 'exit_right':
      return _Geo(_forkArm(true), ghosts: [_forkArm(false)]);
    case 'fork_straight':
    case 'fork_both':
    case 'fork_left_right':
      return _Geo(_straight(), ghosts: [_forkArm(false), _forkArm(true)]);
    case 'lane_shift_left':
      return _Geo(_laneShift(false));
    case 'lane_shift_right':
      return _Geo(_laneShift(true));
    case 'keep_left':
    case 'merge_left':
      return _Geo(_laneShift(false), bars: _lanes);
    case 'keep_right':
    case 'merge_right':
      return _Geo(_laneShift(true), bars: _lanes);
  }
  return null;
}
