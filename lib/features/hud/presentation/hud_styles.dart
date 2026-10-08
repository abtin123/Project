import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/hud_settings.dart';
import 'hud_bold_icon.dart';

/// داده‌ی یک فریم از HUD؛ هم صفحه‌ی زنده و هم پیش‌نمایش‌ها از همین ساخته
/// می‌شوند تا چیزی که کاربر در تنظیمات می‌بیند عیناً همان چیزی باشد که روی
/// شیشه نمایش داده می‌شود.
class HudFrameData {
  const HudFrameData({
    required this.speedKmh,
    required this.speedUnit,
    this.speedLimit,
    this.distanceLabel,
    this.maneuverIcon,
    this.arrived = false,
    this.arrivedLabel = '',
    this.clockText = '',
    this.compassLabel,
    this.alertAsset,
    this.remainingLabel,
    this.noNavigationLabel,
  });

  final int speedKmh;
  final String speedUnit;
  final int? speedLimit;
  final String? distanceLabel;
  final IconData? maneuverIcon;
  final bool arrived;
  final String arrivedLabel;
  final String clockText;
  final String? compassLabel;
  final String? alertAsset;
  final String? remainingLabel;
  final String? noNavigationLabel;

  bool get overLimit => speedLimit != null && speedKmh > speedLimit!;
}

/// بوم ثابت ۴۸۰×۲۷۰ (۱۶:۹). با [FittedBox] به هر اندازه‌ای کشیده می‌شود.
const double kHudCanvasW = 480;
const double kHudCanvasH = 270;

/// چیدمانِ انتخابیِ HUD (Type 1..4) روی بوم سیاه.
class HudStyleView extends StatelessWidget {
  const HudStyleView({
    super.key,
    required this.settings,
    required this.data,
    this.styleOverride,
  });

  final HudSettings settings;
  final HudFrameData data;

  /// برای نمایش استایل‌های دیگر در پنجره‌ی انتخاب.
  final HudStyle? styleOverride;

  @override
  Widget build(BuildContext context) {
    final style = styleOverride ?? settings.style;
    // رنگ‌های سفارشی فقط روی استایل انتخاب‌شده اعمال می‌شود؛ پیش‌نمایشِ
    // استایل‌های دیگر با پالت پیش‌فرضِ خودشان کشیده می‌شود.
    final palette = styleOverride != null && styleOverride != settings.style
        ? HudPalette.defaultFor(style)
        : settings.palette;
    final f = _Flags(settings);
    final Widget body;
    switch (style) {
      case HudStyle.type1:
        body = _Type1(f: f, d: data, p: palette);
      case HudStyle.type2:
        body = _Type2(f: f, d: data, p: palette);
      case HudStyle.type3:
        body = _Type3(f: f, d: data, p: palette);
      case HudStyle.type4:
        body = _Type4(f: f, d: data, p: palette);
    }
    return SizedBox(
      width: kHudCanvasW,
      height: kHudCanvasH,
      child: ColoredBox(color: Colors.black, child: body),
    );
  }
}

class _Flags {
  _Flags(HudSettings s)
      : speed = s.showSpeed,
        limit = s.showSpeedLimit,
        maneuver = s.showNextManeuver,
        distance = s.showDistanceToManeuver,
        compass = s.showCompassHeading,
        alerts = s.showRouteAlerts,
        other = s.showOtherInfo,
        clock = s.showClock;
  final bool speed, limit, maneuver, distance, compass, alerts, other, clock;
}

// ---------------------------------------------------------------- pieces ---

class _Txt extends StatelessWidget {
  const _Txt(this.text, this.size, this.color,
      {this.weight = FontWeight.w900, this.maxWidth});
  final String text;
  final double size;
  final Color color;
  final FontWeight weight;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final w = Text(
      text,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: weight,
        height: 1.0,
      ),
    );
    if (maxWidth == null) return w;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth!),
      child: FittedBox(fit: BoxFit.scaleDown, child: w),
    );
  }
}

class _SpeedReadout extends StatelessWidget {
  const _SpeedReadout({
    required this.d,
    required this.color,
    required this.size,
    this.align = CrossAxisAlignment.end,
  });
  final HudFrameData d;
  final Color color;
  final double size;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align,
        children: [
          _Txt('${d.speedKmh}', size, color),
          const SizedBox(height: 2),
          _Txt(d.speedUnit, size * .24, color,
              weight: FontWeight.w700, maxWidth: size * 1.9),
        ],
      );
}

class _LimitSign extends StatelessWidget {
  const _LimitSign({required this.limit, required this.over, this.size = 76});
  final int limit;
  final bool over;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: over ? Colors.red : Colors.white,
          border: Border.all(color: Colors.red, width: size * .1),
        ),
        child: Text(
          '$limit',
          style: TextStyle(
            color: over ? Colors.white : Colors.black,
            fontWeight: FontWeight.w900,
            fontSize: size * .4,
            height: 1,
          ),
        ),
      );
}

class _ManeuverArrow extends StatelessWidget {
  const _ManeuverArrow({required this.d, required this.color, required this.size});
  final HudFrameData d;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = d.arrived ? Icons.flag_rounded : d.maneuverIcon;
    if (icon == null) return SizedBox(width: size, height: size);
    return HudBoldIcon(icon, color: color, size: size);
  }
}

class _ClockCompass extends StatelessWidget {
  const _ClockCompass({
    required this.f,
    required this.d,
    required this.p,
    required this.size,
  });
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;
  final double size;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (f.clock && d.clockText.isNotEmpty)
            _Txt(d.clockText, size, p.info),
          if (f.compass && d.compassLabel != null) ...[
            const SizedBox(height: 4),
            _Txt(d.compassLabel!, size * .5, p.info,
                weight: FontWeight.w800, maxWidth: size * 3),
          ],
        ],
      );
}

/// ردیف پایین مشترک: هشدار مسیر، مسافت باقی‌مانده و متن «بدون مسیر».
class _Extras extends StatelessWidget {
  const _Extras({required this.f, required this.d, required this.p});
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (f.alerts && d.alertAsset != null) ...[
            Image.asset(d.alertAsset!,
                width: 40,
                height: 40,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high),
            const SizedBox(width: 12),
          ],
          if (f.other && d.remainingLabel != null)
            _Txt(d.remainingLabel!, 22, p.info,
                weight: FontWeight.w800, maxWidth: 190),
        ],
      );
}

class _NoNav extends StatelessWidget {
  const _NoNav(this.text);
  final String? text;
  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : _Txt(text!, 20, Colors.white38,
          weight: FontWeight.w600, maxWidth: 260);
}

Widget _arrowWithDistance(_Flags f, HudFrameData d, HudPalette p,
    {required double arrow, required double dist, CrossAxisAlignment align = CrossAxisAlignment.center}) {
  final hasNav = d.maneuverIcon != null || d.arrived;
  if (!hasNav) return _NoNav(d.noNavigationLabel);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: align,
    children: [
      if (f.maneuver) _ManeuverArrow(d: d, color: p.arrow, size: arrow),
      if (f.maneuver && (f.distance || d.arrived)) const SizedBox(height: 6),
      if (d.arrived)
        _Txt(d.arrivedLabel, dist * .8, p.distance, maxWidth: 230)
      else if (f.distance && d.distanceLabel != null)
        _Txt(d.distanceLabel!, dist, p.distance, maxWidth: 230),
    ],
  );
}

// --------------------------------------------------------------- layouts ---

/// Type 1: ساعت بالا-چپ، علامت سرعت مجاز بالا-راست، فلش بزرگ چپ،
/// سرعت و فاصله راست.
class _Type1 extends StatelessWidget {
  const _Type1({required this.f, required this.d, required this.p});
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Positioned(
            left: 18,
            top: 14,
            child: _ClockCompass(f: f, d: d, p: p, size: 40),
          ),
          if (f.limit && d.speedLimit != null)
            Positioned(
              right: 18,
              top: 14,
              child: _LimitSign(limit: d.speedLimit!, over: d.overLimit),
            ),
          Positioned(
            left: 26,
            top: 78,
            child: d.maneuverIcon != null || d.arrived
                ? (f.maneuver
                    ? _ManeuverArrow(d: d, color: p.arrow, size: 128)
                    : const SizedBox.shrink())
                : _NoNav(d.noNavigationLabel),
          ),
          Positioned(
            right: 18,
            top: 104,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (f.speed)
                  _SpeedReadout(d: d, color: p.speed, size: 62),
                const SizedBox(height: 10),
                if (d.arrived)
                  _Txt(d.arrivedLabel, 30, p.distance, maxWidth: 230)
                else if (f.distance && d.distanceLabel != null)
                  _Txt(d.distanceLabel!, 44, p.distance, maxWidth: 230),
              ],
            ),
          ),
          Positioned(
            left: 18,
            bottom: 12,
            child: _Extras(f: f, d: d, p: p),
          ),
        ],
      );
}

/// Type 2: فلش بزرگ چپ؛ ستون راست: فاصله، ساعت، سرعت.
class _Type2 extends StatelessWidget {
  const _Type2({required this.f, required this.d, required this.p});
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Positioned(
            left: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: d.maneuverIcon != null || d.arrived
                  ? (f.maneuver
                      ? _ManeuverArrow(d: d, color: p.arrow, size: 168)
                      : const SizedBox.shrink())
                  : _NoNav(d.noNavigationLabel),
            ),
          ),
          Positioned(
            right: 20,
            top: 14,
            bottom: 14,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (d.arrived)
                  _Txt(d.arrivedLabel, 30, p.distance, maxWidth: 220)
                else if (f.distance && d.distanceLabel != null)
                  _Txt(d.distanceLabel!, 46, p.distance, maxWidth: 220)
                else
                  const SizedBox(height: 46),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (f.compass && d.compassLabel != null) ...[
                      _Txt(d.compassLabel!, 22, p.info,
                          weight: FontWeight.w800, maxWidth: 80),
                      const SizedBox(width: 12),
                    ],
                    if (f.clock && d.clockText.isNotEmpty)
                      _Txt(d.clockText, 40, p.info),
                  ],
                ),
                if (f.speed) _SpeedReadout(d: d, color: p.speed, size: 52),
                _Extras(f: f, d: d, p: p),
              ],
            ),
          ),
          if (f.limit && d.speedLimit != null)
            Positioned(
              left: 20,
              bottom: 14,
              child: _LimitSign(
                  limit: d.speedLimit!, over: d.overLimit, size: 58),
            ),
        ],
      );
}

/// Type 3: سرعت بزرگ بالا-چپ، علامت سرعت مجاز وسط-بالا، فلش و فاصله راست.
class _Type3 extends StatelessWidget {
  const _Type3({required this.f, required this.d, required this.p});
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          if (f.speed)
            Positioned(
              left: 20,
              top: 40,
              child: _SpeedReadout(
                  d: d,
                  color: p.speed,
                  size: 96,
                  align: CrossAxisAlignment.start),
            ),
          if (f.limit && d.speedLimit != null)
            Positioned(
              left: 150,
              top: 10,
              child: _LimitSign(
                  limit: d.speedLimit!, over: d.overLimit, size: 70),
            ),
          Positioned(
            right: 22,
            top: 24,
            child: _arrowWithDistance(f, d, p, arrow: 124, dist: 42),
          ),
          Positioned(
            left: 20,
            bottom: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ClockCompass(f: f, d: d, p: p, size: 28),
                const SizedBox(width: 16),
                _Extras(f: f, d: d, p: p),
              ],
            ),
          ),
        ],
      );
}

/// Type 4: گیج دایره‌ای سرعت، فلش در مرکز، ساعت پایین-چپ، فاصله پایین-راست.
class _Type4 extends StatelessWidget {
  const _Type4({required this.f, required this.d, required this.p});
  final _Flags f;
  final HudFrameData d;
  final HudPalette p;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _GaugePainter(
                speed: f.speed ? d.speedKmh.toDouble() : 0,
                limit: d.speedLimit,
                good: p.speed,
                tickColor: p.info,
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (d.maneuverIcon != null || d.arrived) ...[
                  if (f.maneuver)
                    _ManeuverArrow(d: d, color: p.arrow, size: 88),
                ] else
                  _NoNav(d.noNavigationLabel),
                if (f.speed) ...[
                  const SizedBox(height: 2),
                  _Txt('${d.speedKmh}', 34, p.speed),
                ],
              ],
            ),
          ),
          Positioned(
            left: 18,
            bottom: 12,
            child: _ClockCompass(f: f, d: d, p: p, size: 34),
          ),
          Positioned(
            right: 18,
            bottom: 12,
            child: d.arrived
                ? _Txt(d.arrivedLabel, 26, p.distance, maxWidth: 180)
                : (f.distance && d.distanceLabel != null
                    ? _Txt(d.distanceLabel!, 40, p.distance, maxWidth: 180)
                    : const SizedBox.shrink()),
          ),
          if (f.limit && d.speedLimit != null)
            Positioned(
              right: 18,
              top: 12,
              child: _LimitSign(
                  limit: d.speedLimit!, over: d.overLimit, size: 62),
            ),
          Positioned(
            left: 18,
            top: 12,
            child: _Extras(f: f, d: d, p: p),
          ),
        ],
      );
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.speed,
    required this.limit,
    required this.good,
    required this.tickColor,
  });

  final double speed;
  final int? limit;
  final Color good;
  final Color tickColor;

  static const double _max = 240;
  static const double _start = 3 * math.pi / 4; // 135°
  static const double _sweep = 3 * math.pi / 2; // 270°

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 6);
    final radius = math.min(size.width, size.height) / 2 - 6;
    final warnFrom = (limit ?? 130).toDouble();

    // ticks
    for (var v = 0; v <= _max; v += 10) {
      final a = _start + _sweep * (v / _max);
      final major = v % 20 == 0;
      final len = major ? 14.0 : 8.0;
      final o = Offset(math.cos(a), math.sin(a));
      final p1 = center + o * radius;
      final p2 = center + o * (radius - len);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..strokeWidth = major ? 3 : 2
          ..strokeCap = StrokeCap.round
          ..color = v > warnFrom
              ? Colors.redAccent.withOpacity(.85)
              : tickColor.withOpacity(.75),
      );
    }

    // progress arc
    final rect = Rect.fromCircle(center: center, radius: radius - 24);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.butt
      ..color = Colors.white.withOpacity(.10);
    canvas.drawArc(rect, _start, _sweep, false, track);

    final s = speed.clamp(0, _max).toDouble();
    final okTo = math.min(s, warnFrom);
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.butt;
    if (okTo > 0) {
      canvas.drawArc(rect, _start, _sweep * (okTo / _max), false,
          fill..color = good);
    }
    if (s > warnFrom) {
      canvas.drawArc(
        rect,
        _start + _sweep * (warnFrom / _max),
        _sweep * ((s - warnFrom) / _max),
        false,
        fill..color = Colors.redAccent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.speed != speed ||
      old.limit != limit ||
      old.good != good ||
      old.tickColor != tickColor;
}
