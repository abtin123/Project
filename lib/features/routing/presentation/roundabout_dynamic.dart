import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

import '../../../shared/widgets/solid_arrow.dart';

enum BranchType { entrance, mainExit, secondaryExit }

@immutable
class ArrowData {
  const ArrowData({
    this.enabled = true,
    this.length = 30,
    this.width = 18,
    this.thickness = 1,
    this.position = .78,
    this.color,
  });
  final bool enabled;
  final double length;
  final double width;
  final double thickness;
  final double position;
  final Color? color;
}

@immutable
class BranchData {
  const BranchData({
    required this.angleDeg,
    required this.type,
    this.length = 190,
    this.curve = 0,
    this.color,
    this.opacity = 1,
    this.strokeWidth,
    this.active = false,
    this.showArrow = true,
    this.arrow,
    this.controlPoint1,
    this.controlPoint2,
    this.customPath,
    this.id,
  });
  final double angleDeg;
  final BranchType type;
  final double length;
  final double curve;
  final Color? color;
  final double opacity;
  final double? strokeWidth;
  final bool active;
  final bool showArrow;
  final ArrowData? arrow;
  final Offset? controlPoint1;
  final Offset? controlPoint2;
  final String? customPath;
  final String? id;
}

@immutable
class RoundaboutStyle {
  const RoundaboutStyle({
    this.roundaboutColor = const Color(0xFF0A90FB),
    this.entranceColor = const Color(0xFF0A90FB),
    this.mainExitColor = const Color(0xFF0A90FB),
    this.secondaryExitColor = const Color(0xFF0A90FB),
    this.laneMarkColor = Colors.white,
    this.glowColor = const Color(0xFF0A90FB),
    this.roundaboutOpacity = 1,
    this.entranceOpacity = .65,
    this.mainExitOpacity = 1,
    this.secondaryExitOpacity = .28,
    this.laneMarkOpacity = .62,
    this.glowOpacity = .18,
    this.roadWidth = 22,
    this.ringWidth = 22,
    this.laneMarkWidth = 2,
    this.glowWidth = 7,
    this.arrowLength = 30,
    this.arrowWidth = 18,
    this.arrowThickness = 1,
    this.arrowPosition = .78,
    this.glowEnabled = false,
    this.showLaneMarks = true,
    this.outlineColor = Colors.white,
    this.borderColor = Colors.black,
    this.showExitNumber = true,
  });

  /// کادرِ داخلی (پیش‌فرض سفید) و کادرِ بیرونیِ (پیش‌فرض مشکی) مسیرِ فعال.
  final Color outlineColor;
  final Color borderColor;

  /// شمارهٔ خروج وسطِ میدان (پیش‌فرض روشن).
  final bool showExitNumber;

  final Color roundaboutColor;
  final Color entranceColor;
  final Color mainExitColor;
  final Color secondaryExitColor;
  final Color laneMarkColor;
  final Color glowColor;
  final double roundaboutOpacity;
  final double entranceOpacity;
  final double mainExitOpacity;
  final double secondaryExitOpacity;
  final double laneMarkOpacity;
  final double glowOpacity;
  final double roadWidth;
  final double ringWidth;
  final double laneMarkWidth;
  final double glowWidth;
  final double arrowLength;
  final double arrowWidth;
  final double arrowThickness;
  final double arrowPosition;
  final bool glowEnabled;
  final bool showLaneMarks;
}

@immutable
class RoundaboutData {
  const RoundaboutData({
    this.canvas = const Size(512, 512),
    this.center = const Offset(256, 256),
    this.radius = 92,
    this.branches = const [],
    this.activeExit,
    this.style = const RoundaboutStyle(),
    this.roundaboutId = 'roundabout',
    this.mainEntranceAngleDeg,
    this.drivingSide = 'right',
    this.roadWidth,
  });

  /// پهنای جاده (واحدِ canvas)؛ اگر null باشد از [RoundaboutStyle.roadWidth] می‌آید.
  final double? roadWidth;
  final Size canvas;
  final Offset center;
  final double radius;
  final List<BranchData> branches;
  final int? activeExit;
  final RoundaboutStyle style;
  final String roundaboutId;

  /// زاویهٔ صفحه‌ای (screen-space) ورودیِ واقعی‌ای که خودروی در حالِ
  /// مسیریابی از آن وارد میدان می‌شود. وقتی مقدار دارد، یک کمانِ واحد و
  /// پیوسته از این ورودی تا خروجیِ فعال رسم می‌شود که رویِ ورودی/خروجی‌های
  /// فرعی می‌افتد. وقتی null است (مثلاً در پیش‌نمایش)، خروجیِ فعال مثلِ
  /// یک شاخهٔ معمولی رسم می‌شود.
  final double? mainEntranceAngleDeg;

  /// 'right' یا 'left' — جهتِ چرخشِ واقعیِ ترافیک داخلِ میدان را تعیین
  /// می‌کند: پادساعتگرد برای ترافیکِ راست‌رو، ساعتگرد برای ترافیکِ چپ‌رو.
  final String drivingSide;
}

const double _kappa = .5523; // تقریبِ بزیه از ربع دایره

class RoundaboutGeometry {
  const RoundaboutGeometry(this.data);
  final RoundaboutData data;

  double get roadWidth => data.roadWidth ?? data.style.roadWidth;

  Offset direction(double degrees) {
    final a = degrees * math.pi / 180;
    return Offset(math.cos(a), math.sin(a));
  }

  /// جهتِ حرکتِ خودرو رویِ حلقه در زاویهٔ [degrees]؛ [sign]=+1 یعنی افزایشِ
  /// زاویه (ساعتگرد روی صفحه)، -1 پادساعتگرد.
  Offset travelDirection(double degrees, double sign) {
    final a = degrees * math.pi / 180;
    return Offset(-math.sin(a), math.cos(a)) * sign;
  }

  /// شعاعِ خمِ ربع‌دایره‌ای که شاخه را مماس به حلقه وصل می‌کند.
  double bendRadius(double length, double trim) => math.max(
        roadWidth * .5,
        math.min(roadWidth * 1.05, (length - trim) * .95),
      );

  /// شاخهٔ مستقیمِ کم‌رنگ از حلقه به بیرون. [trim] انتها را برای جا دادنِ
  /// سرِ فلش کوتاه می‌کند.
  Path armPath(BranchData b, {double trim = 0}) {
    final dir = direction(b.angleDeg);
    final start = data.center + dir * data.radius;
    final end = data.center + dir * (data.radius + math.max(1.0, b.length - trim));
    return Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
  }

  void _entrance(Path path, double entranceDeg, double length, double sign, double k) {
    final d = direction(entranceDeg);
    final t = travelDirection(entranceDeg, sign);
    final ring = data.center + d * data.radius;
    // ساقه کمی «پشتِ» جهتِ حرکت قرار می‌گیرد و با یک ربع‌دایره مماس به حلقه می‌رسد.
    final shaftStart = ring - t * k + d * length;
    final shaftEnd = ring - t * k + d * k;
    final c1 = shaftEnd - d * (k * _kappa);
    final c2 = ring - t * (k * _kappa);
    path
      ..moveTo(shaftStart.dx, shaftStart.dy)
      ..lineTo(shaftEnd.dx, shaftEnd.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, ring.dx, ring.dy);
  }

  void _exit(Path path, double exitDeg, double length, double trim, double sign, double k) {
    final d = direction(exitDeg);
    final t = travelDirection(exitDeg, sign);
    final ring = data.center + d * data.radius;
    final bendEnd = ring + t * k + d * k;
    final c1 = ring + t * (k * _kappa);
    final c2 = bendEnd - d * (k * _kappa);
    final tip = ring + t * k + d * math.max(k, length - trim);
    path
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, bendEnd.dx, bendEnd.dy)
      ..lineTo(tip.dx, tip.dy);
  }

  /// مسیرِ پیوستهٔ ورودی ← حلقه ← خروجیِ فعال. انتهایش به‌اندازهٔ [trim]
  /// کوتاه است تا سرِ فلش پشتِ آن قرار بگیرد.
  Path activePath(BranchData exit, double entranceDeg, {double trim = 0}) {
    final sweep = _travelSweepDeg(entranceDeg, exit.angleDeg, data.drivingSide);
    final sign = sweep >= 0 ? 1.0 : -1.0;
    final k = bendRadius(exit.length, trim);
    final path = Path();
    _entrance(path, entranceDeg, exit.length, sign, k);
    path.arcTo(
      Rect.fromCircle(center: data.center, radius: data.radius),
      entranceDeg * math.pi / 180,
      sweep * math.pi / 180,
      false,
    );
    _exit(path, exit.angleDeg, exit.length, trim, sign, k);
    return path;
  }

  /// فقط ورودی (وقتی خروجیِ فعال معلوم نیست).
  Path entrancePath(double entranceDeg, double length) {
    final sign = data.drivingSide == 'left' ? 1.0 : -1.0;
    final k = bendRadius(length, 0);
    final path = Path();
    _entrance(path, entranceDeg, length, sign, k);
    return path;
  }

  /// خروجیِ فعال وقتی ورودی معلوم نیست: یک شاخهٔ مستقیمِ پررنگ.
  Path exitOnlyPath(BranchData b, {double trim = 0}) => armPath(b, trim: trim);
}

/// مقدارِ چرخشِ (درجه، با علامت) لازم برای رفتن از زاویهٔ ورودی به زاویهٔ
/// خروجی، در جهتِ واقعیِ گردشِ ترافیک: پادساعتگرد (منفی) برای راست‌رو،
/// ساعتگرد (مثبت) برای چپ‌رو.
double _travelSweepDeg(double fromDeg, double toDeg, String drivingSide) {
  var cw = (toDeg - fromDeg) % 360;
  if (cw < 0) cw += 360;
  if (cw == 0) cw = 360;
  if (drivingSide == 'left') return cw;
  final ccw = 360 - cw;
  return -(ccw == 0 ? 360.0 : ccw.toDouble());
}

double _angularDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// میدان به سبکِ فلش‌های توپر: مسیرِ ورودی→خروجیِ فعال پررنگ (بدنهٔ رنگی +
/// کادرِ سفید + کادرِ مشکی)، حلقه و بقیهٔ خروجی‌ها کم‌رنگ و بدون کادر.
class RoundaboutPainter extends CustomPainter {
  const RoundaboutPainter(this.data);
  final RoundaboutData data;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / data.canvas.width;
    final sy = size.height / data.canvas.height;
    canvas.save();
    canvas.scale(sx, sy);

    final s = data.style;
    final g = RoundaboutGeometry(data);
    final w = g.roadWidth;
    final m = ArrowMetrics(w, headLengthRatio: 1.25, headWidthRatio: 2.1);
    final trim = m.headLength - m.cornerRadius / 2;
    final entranceDeg = data.mainEntranceAngleDeg;

    BranchData? found;
    for (final b in data.branches) {
      if (b.type == BranchType.mainExit) {
        found = b;
        break;
      }
    }
    final main = found;

    // ۱) لایهٔ کم‌رنگ: حلقه + همهٔ شاخه‌های غیرفعال (یک‌جا با یک شفافیت).
    final ghost = s.secondaryExitColor;
    paintGhostLayer(
      canvas,
      (Offset.zero & data.canvas).inflate(w * 2),
      s.secondaryExitOpacity,
      () {
        canvas.drawCircle(
          data.center,
          data.radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w
            ..color = ghost,
        );
        for (final b in data.branches) {
          if (identical(b, main)) continue;
          // بازوی ورودیِ خودرو را خودِ مسیرِ فعال نشان می‌دهد.
          if (entranceDeg != null && _angularDistance(b.angleDeg, entranceDeg) < 10) {
            continue;
          }
          final hasHead = b.type != BranchType.entrance;
          paintArrowFlat(
            canvas,
            ArrowShape(g.armPath(b, trim: hasHead ? trim : 0), m, head: hasHead),
            ghost,
          );
        }
      },
    );

    // ۲) مسیرِ فعال، پررنگ و با کادر.
    final solid = SolidArrowStyle(
      fill: s.mainExitColor.withOpacity(s.mainExitOpacity.clamp(0.0, 1.0).toDouble()),
      outline: s.outlineColor,
      border: s.borderColor,
    );
    if (main != null && entranceDeg != null) {
      paintSolidArrow(canvas, ArrowShape(g.activePath(main, entranceDeg, trim: trim), m), solid);
    } else if (main != null) {
      paintSolidArrow(canvas, ArrowShape(g.exitOnlyPath(main, trim: trim), m), solid);
    } else if (entranceDeg != null) {
      final len = data.branches.isEmpty ? w * 3 : data.branches.first.length;
      paintSolidArrow(canvas, ArrowShape(g.entrancePath(entranceDeg, len), m, head: false), solid);
    }

    if (s.showExitNumber && data.activeExit != null) {
      _drawCenterNumber(canvas, data.activeExit!, s);
    }
    canvas.restore();
  }

  void _drawCenterNumber(Canvas canvas, int exitNumber, RoundaboutStyle s) {
    final w = data.roadWidth ?? s.roadWidth;
    // شعاعِ داخلیِ حلقه (لبهٔ داخلیِ خط ضخیم) منهای کمی حاشیه.
    final inner = math.max(8.0, data.radius - w * .5 - w * .25);
    final label = '$exitNumber';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          inherit: false,
          color: s.mainExitColor,
          fontSize: math.max(12.0, inner * (label.length > 1 ? 1.05 : 1.3)),
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, data.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant RoundaboutPainter oldDelegate) => oldDelegate.data != data;
}

class RoundaboutManeuverIcon extends StatelessWidget {
  const RoundaboutManeuverIcon({
    super.key,
    required this.color,
    this.exit,
    this.exitCount,
    this.angleDegrees,
    this.branchAngles = const [],
    this.entranceAngles = const [],
    this.exitAngles = const [],
    this.activeExitAngle,
    this.drivingSide = 'right',
    this.thickness = .72,
    this.sizeFactor = .88,
    this.style,
  });

  final Color color;
  final int? exit;
  final int? exitCount;
  final double? angleDegrees;
  final List<double> branchAngles;
  final List<double> entranceAngles;
  final List<double> exitAngles;
  final double? activeExitAngle;
  final String drivingSide;
  final double thickness;
  final double sizeFactor;
  final RoundaboutStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (_, c) {
          final side = math.min(c.maxWidth.isFinite ? c.maxWidth : 92,
              c.maxHeight.isFinite ? c.maxHeight : 92);
          final data = _makeData(side.toDouble());
          return Center(
            child: CustomPaint(
              size: Size.square(side * sizeFactor),
              painter: RoundaboutPainter(data),
            ),
          );
        },
      );

  RoundaboutData _makeData(double side) {
    // زاویه‌ها از موتورِ مسیریابی به‌صورتِ قطب‌نما می‌آیند (0=شمال، ساعتگرد)؛
    // بومِ آیکون زاویهٔ ریاضی می‌خواهد (0=راست، 90=پایین). آیکون «جهت‌محور»
    // است: بازوی ورودیِ خودرو همیشه پایینِ بوم (90) رسم می‌شود و بقیهٔ
    // بازوها/خروجی نسبت به آن می‌چرخند. اگر ورودی معلوم نباشد چرخشی اعمال
    // نمی‌شود (شمال‌بالا).
    final shift = angleDegrees != null ? 90 - angleDegrees! : -90.0;
    double toCanvas(double raw) => ((raw + shift) % 360 + 360) % 360;

    final angles = <double>[];
    void addAngle(double normalized) {
      if (!angles.any((a) => _angularDistance(a, normalized) <= 7.5)) {
        angles.add(normalized);
      }
    }

    for (final raw in branchAngles) {
      addAngle(toCanvas(raw));
    }

    bool matchesAny(double angle, List<double> targets) => targets.any(
          (target) => _angularDistance(angle, toCanvas(target)) <= 12,
        );

    final activeAngle =
        activeExitAngle == null ? null : toCanvas(activeExitAngle!);
    final entranceAngle = angleDegrees == null ? null : 90.0;

    // بازوی ورودی و خروجیِ فعال حتماً باید وجود داشته باشند، حتی اگر در
    // فهرستِ بازوها نبودند؛ وگرنه مسیر روی بازوی اشتباه رسم می‌شود.
    if (entranceAngle != null) addAngle(entranceAngle);
    if (activeAngle != null) addAngle(activeAngle);
    final active = exit == null
        ? null
        : exit!.clamp(1, math.max(angles.length, 1)).toInt();

    // هندسه: همه‌چیز نسبت به اندازهٔ بوم است تا نوکِ فلش‌ها و کادرها بیرون نزنند.
    double minGap = 180;
    for (var i = 0; i < angles.length; i++) {
      for (var j = i + 1; j < angles.length; j++) {
        final gap = _angularDistance(angles[i], angles[j]);
        if (gap > 0 && gap < minGap) minGap = gap;
      }
    }
    final crowding = angles.length > 1 && minGap < 55
        ? ((55 - minGap) / 55).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final radius = side * (0.26 + 0.03 * crowding);
    final tipRadius = side * .455;
    final armLength = tipRadius - radius;
    final roadWidth = side * (0.05 + thickness.clamp(0.35, 1.5).toDouble() * 0.055);

    final branches = <BranchData>[];
    for (var i = 0; i < angles.length; i++) {
      final angle = angles[i];
      final isMain = activeAngle != null
          ? _angularDistance(angle, activeAngle) <= 12
          : active == i + 1;
      final isEntrance = matchesAny(angle, entranceAngles);
      final isExit = exitAngles.isNotEmpty ? matchesAny(angle, exitAngles) : !isEntrance;
      final type = isMain
          ? BranchType.mainExit
          : isExit
              ? BranchType.secondaryExit
              : BranchType.entrance;
      branches.add(BranchData(
        angleDeg: angle,
        type: type,
        length: armLength,
        showArrow: false,
        id: isMain
            ? 'mainExit'
            : isEntrance
                ? 'entrance_$i'
                : 'secondaryExit_$i',
        active: isMain,
      ));
    }

    // اگر فقط یک بازو «فعال» علامت خورده باشد ولی چند بازو نزدیک به هم
    // باشند، اولی می‌ماند؛ مسیرِ فعال باید یکتا باشد.
    var seenMain = false;
    for (var i = 0; i < branches.length; i++) {
      if (branches[i].type != BranchType.mainExit) continue;
      if (seenMain) {
        final b = branches[i];
        branches[i] = BranchData(
          angleDeg: b.angleDeg,
          type: BranchType.secondaryExit,
          length: b.length,
          showArrow: false,
          id: 'secondaryExit_$i',
        );
      }
      seenMain = true;
    }

    return RoundaboutData(
      canvas: Size.square(side),
      center: Offset(side / 2, side / 2),
      radius: radius,
      branches: branches,
      // شمارهٔ واقعیِ خروج از موتور مسیریابی؛ نه مقدارِ clamp‌شده به تعداد بازوها.
      activeExit: (exit != null && exit! > 0) ? exit : null,
      mainEntranceAngleDeg: entranceAngle,
      drivingSide: drivingSide,
      roadWidth: roadWidth,
      style: style ?? RoundaboutStyle(mainExitColor: color, secondaryExitColor: color),
    );
  }
}
