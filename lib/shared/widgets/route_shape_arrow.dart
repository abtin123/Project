import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/routing/domain/maneuver_geometry.dart';
import 'solid_arrow.dart';

/// آیکن کارت مسیر که دقیقاً همان شکلِ فلشِ روی نقشه را نشان می‌دهد: مسیرِ واقعیِ
/// قبل و بعد از پیچ، چرخانده‌شده طوری که جهتِ ورود همیشه رو به بالا باشد، با نوک
/// فلش در انتها و یک سایهٔ کمرنگ از ادامهٔ مستقیمِ خیابان برای نشان‌دادن اینکه
/// کجا باید جدا شد.
class RouteShapeManeuverIcon extends StatelessWidget {
  const RouteShapeManeuverIcon({
    super.key,
    required this.shape,
    required this.color,
    this.outlineColor = Colors.white,
    this.borderColor = Colors.black,
    this.ghostOpacity = .28,
    this.thickness = .72,
  });

  final ManeuverShape shape;
  final Color color;
  final Color outlineColor;
  final Color borderColor;
  final double ghostOpacity;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _RouteShapePainter(
        shape: shape,
        style: SolidArrowStyle(
          fill: color,
          outline: outlineColor,
          border: borderColor,
          ghostOpacity: ghostOpacity,
        ),
        thickness: thickness,
      ),
    );
  }
}

class _RouteShapePainter extends CustomPainter {
  const _RouteShapePainter({
    required this.shape,
    required this.style,
    required this.thickness,
  });

  final ManeuverShape shape;
  final SolidArrowStyle style;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = shape.local;
    if (pts.length < 2) return;
    final side = math.min(size.width, size.height);
    if (side <= 0) return;

    // جهتِ ورود را به «بالا» می‌چرخانیم.
    final theta = shape.entryBearingDeg * math.pi / 180.0;
    final dx = math.sin(theta);
    final dy = math.cos(theta);
    final phi = math.pi / 2 - math.atan2(dy, dx);
    final cp = math.cos(phi);
    final sp = math.sin(phi);
    Offset rot(Offset o) => Offset(o.dx * cp - o.dy * sp, o.dx * sp + o.dy * cp);

    final rotated = <Offset>[for (final p in pts) rot(p)];
    final rc = rot(shape.center);

    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in rotated) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final w = math.max(maxX - minX, 1.0);
    final h = math.max(maxY - minY, 1.0);

    // جا برای نوک فلش و لبه‌ها.
    const box = 80.0;
    final scale = math.min(box / w, box / h);
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    Offset toBox(Offset o) =>
        Offset(50 + (o.dx - cx) * scale, 50 - (o.dy - cy) * scale);

    final path = Path();
    for (var i = 0; i < rotated.length; i++) {
      final b = toBox(rotated[i]);
      if (i == 0) {
        path.moveTo(b.dx, b.dy);
      } else {
        path.lineTo(b.dx, b.dy);
      }
    }

    final strokeW = (18.0 * thickness / .72).clamp(8.0, 22.0).toDouble();
    final metrics = ArrowMetrics(strokeW);

    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / 112);
    canvas.translate(6, 6);

    // سایهٔ ادامهٔ مستقیم، فقط وقتی واقعاً پیچی در کار است.
    final exitDir = _exitDirection(rotated);
    final turnDeg = exitDir == null
        ? 0.0
        : (math.atan2(exitDir.dx, exitDir.dy) * 180 / math.pi).abs();
    if (turnDeg >= 25) {
      final c = toBox(rc);
      final ghost = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx, math.max(2.0, c.dy - 30 * scale));
      paintGhostLayer(
        canvas,
        const Rect.fromLTRB(-6, -6, 106, 106),
        style.ghostOpacity,
        () => paintArrowFlat(
          canvas,
          ArrowShape(ghost, metrics, head: false),
          style.fill,
        ),
      );
    }

    paintSolidArrow(canvas, ArrowShape(path, metrics), style);
    canvas.restore();
  }

  /// جهتِ خروج (بردار یکه) در دستگاه چرخیده، روی ~۸ متر آخر.
  Offset? _exitDirection(List<Offset> pts) {
    if (pts.length < 2) return null;
    var i = pts.length - 2;
    var acc = 0.0;
    while (i > 0 && acc < 8.0) {
      acc += (pts[i + 1] - pts[i]).distance;
      i--;
    }
    final d = pts.last - pts[i];
    final l = d.distance;
    if (l < 0.01) return null;
    return Offset(d.dx / l, d.dy / l);
  }

  @override
  bool shouldRepaint(covariant _RouteShapePainter old) =>
      !identical(old.shape, shape) ||
      old.thickness != thickness ||
      old.style.fill != style.fill ||
      old.style.outline != style.outline ||
      old.style.border != style.border ||
      old.style.ghostOpacity != style.ghostOpacity;
}
