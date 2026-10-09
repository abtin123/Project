import 'dart:math' as math;

import 'package:flutter/material.dart';

/// رنگ‌های سبکِ «فلشِ توپر»: بدنهٔ رنگی + کادرِ داخلی (پیش‌فرض سفید) +
/// کادرِ بیرونی (پیش‌فرض مشکی). مسیرهای غیرفعال با [fill] و شفافیتِ کم
/// (بدون کادر) رسم می‌شوند.
@immutable
class SolidArrowStyle {
  const SolidArrowStyle({
    this.fill = const Color(0xFF0A90FB),
    this.outline = Colors.white,
    this.border = Colors.black,
    this.ghostOpacity = .28,
  });

  final Color fill;
  final Color outline;
  final Color border;
  final double ghostOpacity;
}

/// همهٔ اندازه‌ها نسبت به پهنای بدنهٔ فلش ([width]) محاسبه می‌شوند.
@immutable
class ArrowMetrics {
  const ArrowMetrics(
    this.width, {
    this.headLengthRatio = 1.55,
    this.headWidthRatio = 2.3,
  });

  final double width;
  final double headLengthRatio;
  final double headWidthRatio;

  double get headLength => width * headLengthRatio;
  double get headWidth => width * headWidthRatio;
  double get outlineWidth => width * .16;
  double get borderWidth => width * .20;
  double get cornerRadius => width * .22;
}

Offset _unit(Offset v) {
  final d = v.distance;
  return d == 0 ? const Offset(0, -1) : Offset(v.dx / d, v.dy / d);
}

/// یک فلش = خطِ مرکزیِ بدنه ([Path]) + مثلثِ سرِ فلش که از انتهای مسیر و
/// در جهتِ مماسِ آخرِ آن ساخته می‌شود. مسیر باید دقیقاً در «پایهٔ سر» تمام شود.
class ArrowShape {
  ArrowShape._({
    required this.body,
    required this.head,
    required this.start,
    required this.startDir,
    required this.width,
    required this.rounding,
    required this.outlineWidth,
    required this.borderWidth,
    required this.bounds,
  });

  factory ArrowShape(Path path, ArrowMetrics m, {bool head = true}) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) {
      return ArrowShape._(
        body: path,
        head: null,
        start: Offset.zero,
        startDir: const Offset(0, -1),
        width: m.width,
        rounding: m.cornerRadius,
        outlineWidth: m.outlineWidth,
        borderWidth: m.borderWidth,
        bounds: Rect.zero,
      );
    }
    final first = metrics.first;
    final last = metrics.last;
    final t0 = first.getTangentForOffset(0);
    final t1 = last.getTangentForOffset(last.length);
    final start = t0?.position ?? Offset.zero;
    final startDir = _unit(t0?.vector ?? const Offset(0, -1));

    // ابتدای بدنه با یک مستطیلِ گوشه‌گرد ساخته می‌شود (نه cap)، پس خودِ
    // مسیر کمی از ابتدا کوتاه می‌شود تا گوشه‌های تیز دیده نشود.
    var body = path;
    if (metrics.length == 1 && first.length > m.width) {
      body = first.extractPath(
        math.min(m.width * .5, first.length * .5),
        first.length,
      );
    }

    Path? headPath;
    if (head && t1 != null) {
      final d = _unit(t1.vector);
      final n = Offset(-d.dy, d.dx);
      final r = m.cornerRadius;
      // مثلث کمی کوچک‌تر ساخته می‌شود چون با stroke گردِ r بزرگ‌تر می‌شود.
      final base = t1.position + d * (r / 2);
      final tip = t1.position + d * (m.headLength - r / 2);
      final half = math.max(1.0, m.headWidth / 2 - r / 2);
      final a = base + n * half;
      final b = base - n * half;
      headPath = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(b.dx, b.dy)
        ..close();
    }

    var bounds = path.getBounds();
    if (headPath != null) bounds = bounds.expandToInclude(headPath.getBounds());
    return ArrowShape._(
      body: body,
      head: headPath,
      start: start,
      startDir: startDir,
      width: m.width,
      rounding: m.cornerRadius,
      outlineWidth: m.outlineWidth,
      borderWidth: m.borderWidth,
      bounds: bounds,
    );
  }

  final Path body;
  final Path? head;
  final Offset start;
  final Offset startDir;
  final double width;
  final double rounding;
  final double outlineWidth;
  final double borderWidth;
  final Rect bounds;
}

/// یک لایه از فلش (بدنه + ته‌گرد + سر) با [extra] پهنای اضافه.
/// لایه‌های کادر با extra>0 و لایهٔ اصلی با extra=0 رسم می‌شوند؛ چون هر لایه
/// از کلِ شکل (بدنه ∪ سر) ساخته می‌شود، کادرها دورِ اتحادِ شکل می‌افتند.
void _drawLayer(Canvas canvas, ArrowShape a, double extra, Paint paint) {
  paint
    ..style = PaintingStyle.stroke
    ..strokeWidth = a.width + extra
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.butt;
  canvas.drawPath(a.body, paint);

  final hw = (a.width + extra) / 2;
  final cap = Path()
    ..addRRect(
      RRect.fromLTRBR(
        -hw,
        -a.width * .6,
        hw,
        extra / 2,
        Radius.circular(a.rounding * .8),
      ),
    );
  final m4 = Matrix4.identity()
    ..translate(a.start.dx, a.start.dy)
    ..rotateZ(math.atan2(a.startDir.dx, -a.startDir.dy));
  paint.style = PaintingStyle.fill;
  canvas.drawPath(cap.transform(m4.storage), paint);

  final head = a.head;
  if (head != null) {
    paint.style = PaintingStyle.fill;
    canvas.drawPath(head, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = a.rounding + extra
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(head, paint);
  }
}

/// فلشِ پررنگ: کادر بیرونی ← کادر داخلی ← بدنهٔ رنگی (کمی تیره‌تر به‌سمتِ پایین‌راست).
void paintSolidArrow(Canvas canvas, ArrowShape a, SolidArrowStyle style) {
  final ow = a.outlineWidth;
  final bw = a.borderWidth;
  _drawLayer(canvas, a, 2 * (ow + bw), Paint()..color = style.border);
  _drawLayer(canvas, a, 2 * ow, Paint()..color = style.outline);
  final shader = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      style.fill,
      style.fill,
      Color.lerp(style.fill, Colors.black, .24)!,
    ],
    stops: const [0.0, 0.62, 1.0],
  ).createShader(a.bounds.inflate(a.width));
  _drawLayer(canvas, a, 0, Paint()..shader = shader);
}

/// فلشِ تخت (بدون کادر) — برای مسیرهای غیرفعال؛ داخلِ [paintGhostLayer] صدا بزنید.
void paintArrowFlat(Canvas canvas, ArrowShape a, Color color) {
  _drawLayer(canvas, a, 0, Paint()..color = color);
}

/// همهٔ اشکالِ داخل [draw] با رنگِ کاملِ خودشان رسم و سپس یک‌جا با
/// [opacity] ترکیب می‌شوند؛ پس جاهایی که اشکال روی هم می‌افتند تیره‌تر نمی‌شود.
void paintGhostLayer(
  Canvas canvas,
  Rect bounds,
  double opacity,
  VoidCallback draw,
) {
  canvas.saveLayer(
    bounds,
    Paint()..color = Colors.white.withOpacity(opacity.clamp(0.0, 1.0).toDouble()),
  );
  draw();
  canvas.restore();
}
