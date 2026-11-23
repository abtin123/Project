import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/routing/domain/maneuver_geometry.dart';
import 'solid_arrow.dart';

/// آیکن کارت مسیر. شکلِ خیابان کپی نمی‌شود؛ رفتارِ مسیر در ~۱۰۰ متر قبل و بعد از
/// پیچ سنجیده می‌شود ([ManeuverShape.turnDeg]) و یک فلشِ تمیز و استاندارد با
/// همان زاویهٔ دقیق رسم می‌شود (پیچ چپ/راست، نیم‌پیچ، تند، دوربرگردان…). ورود
/// همیشه از پایین است و یک سایهٔ کمرنگ از ادامهٔ مستقیم نشان می‌دهد کجا باید
/// جدا شد.
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
    final side = math.min(size.width, size.height);
    if (side <= 0) return;

    final strokeW = (18.0 * thickness / .72).clamp(8.0, 22.0).toDouble();
    final metrics = ArrowMetrics(strokeW);
    final canon = _CanonicalArrow.build(shape.turnDeg, metrics);

    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / 112);
    canvas.translate(6, 6);

    final ghost = canon.ghost;
    if (ghost != null) {
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
    paintSolidArrow(canvas, ArrowShape(canon.active, metrics), style);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RouteShapePainter old) =>
      old.shape.turnDeg != shape.turnDeg ||
      old.thickness != thickness ||
      old.style.fill != style.fill ||
      old.style.outline != style.outline ||
      old.style.border != style.border ||
      old.style.ghostOpacity != style.ghostOpacity;
}

/// فلشِ استانداردِ یک مانور با زاویهٔ دقیق، در بومِ ۱۰۰×۱۰۰ و مرکزچین‌شده.
/// ورود از پایین به بالاست؛ زاویهٔ مثبت راست و منفی چپ است.
class _CanonicalArrow {
  _CanonicalArrow(this.active, this.ghost);

  final Path active;
  final Path? ghost;

  static const double _stem = 32; // ساقهٔ قبل از پیچ
  static const double _arm = 30; // ساقهٔ بعد از پیچ

  static _CanonicalArrow build(double turnDeg, ArrowMetrics m) {
    final right = turnDeg >= 0;
    final sgn = right ? 1.0 : -1.0;
    final a = turnDeg.abs().clamp(0.0, 180.0).toDouble();

    final path = Path();
    Path? ghost;
    final pts = <Offset>[]; // برای محاسبهٔ کادر
    late Offset end;
    late Offset endDir;

    if (a < 12) {
      // ادامهٔ مستقیم
      const len = _stem + _arm;
      path
        ..moveTo(0, 0)
        ..lineTo(0, -len);
      pts.addAll(const [Offset(0, 0), Offset(0, -len)]);
      end = const Offset(0, -len);
      endDir = const Offset(0, -1);
    } else if (a >= 150) {
      // دوربرگردان: ساقهٔ رفت، نیم‌دایره، ساقهٔ برگشت
      const r = 15.0;
      final x = sgn * 2 * r;
      path
        ..moveTo(0, 0)
        ..lineTo(0, -_stem)
        ..arcToPoint(
          Offset(x, -_stem),
          radius: const Radius.circular(r),
          clockwise: right,
        )
        ..lineTo(x, -_stem + _arm * 0.95);
      pts.addAll([
        const Offset(0, 0),
        const Offset(0, -_stem - r),
        Offset(x, -_stem - r),
        Offset(x, -_stem + _arm * 0.95),
      ]);
      end = Offset(x, -_stem + _arm * 0.95);
      endDir = const Offset(0, 1);
    } else {
      final rad = a * math.pi / 180.0;
      final dir = Offset(sgn * math.sin(rad), -math.cos(rad));
      const corner = Offset(0, -_stem);
      // پیچ ملایم: قوس بلندتر؛ پیچ تند: قوس کوتاه‌تر.
      final k = a <= 45 ? 0.7 : (a >= 90 ? 0.4 : 0.7 - 0.3 * (a - 45) / 45);
      final r = _stem * k;
      final p1 = Offset(0, -_stem + r);
      final p2 = corner + dir * r;
      end = corner + dir * _arm;
      endDir = dir;
      path
        ..moveTo(0, 0)
        ..lineTo(p1.dx, p1.dy)
        ..quadraticBezierTo(corner.dx, corner.dy, p2.dx, p2.dy)
        ..lineTo(end.dx, end.dy);
      pts.addAll([const Offset(0, 0), corner, end]);
      if (a >= 20) {
        final gEnd = Offset(0, -_stem - _arm * 0.8);
        ghost = Path()
          ..moveTo(corner.dx, corner.dy)
          ..lineTo(gEnd.dx, gEnd.dy);
        pts.add(gEnd);
      }
    }

    // نوکِ فلش را هم در کادر بیاور تا مرکزچینی درست شود.
    final n = Offset(-endDir.dy, endDir.dx);
    final tip = end + endDir * m.headLength;
    final bl = end + n * (m.headWidth / 2);
    final br = end - n * (m.headWidth / 2);
    pts.addAll([tip, bl, br]);

    var minX = pts.first.dx, maxX = pts.first.dx;
    var minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final shift = Offset(50 - (minX + maxX) / 2, 50 - (minY + maxY) / 2);
    return _CanonicalArrow(path.shift(shift), ghost?.shift(shift));
  }
}
