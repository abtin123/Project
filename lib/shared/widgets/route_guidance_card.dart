import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../features/settings/domain/appearance_settings.dart';
import '../../features/routing/presentation/roundabout_dynamic.dart';
import 'reference_maneuver_arrow.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

@immutable
class RouteGuidanceCardData {
  const RouteGuidanceCardData({
    required this.icon,
    required this.distanceText,
    required this.streetText,
    required this.etaLabel,
    required this.etaValue,
    required this.remainingLabel,
    required this.remainingValue,
    required this.durationLabel,
    required this.durationValue,
    this.onClose,
    this.iconWidget,
    this.iconScale = 1.0,
    this.subtitleText,
  });

  final IconData icon;
  final String distanceText;
  final String streetText;

  /// خطِ دومِ کوچک‌تر و کم‌رنگ‌ترِ زیرِ عنوانِ دستور (مثلاً «در ادامه مسیر»).
  /// اختیاری؛ اگر خالی/نال باشد فقط streetText (با قابلیتِ دو خط شدنِ خودش) نمایش داده می‌شود.
  final String? subtitleText;
  final String etaLabel;
  final String etaValue;
  final String remainingLabel;
  final String remainingValue;
  final String durationLabel;
  final String durationValue;
  final VoidCallback? onClose;
  final Widget? iconWidget;

  /// ضریب مستقل اندازهٔ آیکون سفارشی. برای پیکان معمولی از تنظیم «اندازه فلش»
  /// می‌آید؛ آیکون میدان اندازهٔ داخلی خودش را از style می‌گیرد و ۱ می‌ماند.
  final double iconScale;
}

/// Navigation instruction card, laid out on the measured geometry of the
/// reference screenshot: an 886 x 340 design card (measured card bbox on
/// the 841x1870 reference PNG was ~798x311 px inc. glow blur, ratio 2.57,
/// vs. 886/340 = 2.61 here — within blur-edge measurement error). All
/// coordinates below are in those design pixels, origin = card top-left,
/// and are multiplied by `scale = width / 886`. Colors, sizes, opacity,
/// radius and glow stay configurable through [AppearanceSettings]; at the
/// default settings the card matches the reference.
///
/// Left column: maneuver arrow with the distance to the maneuver under it.
/// Right block: instruction title, separator, then three stats
/// (arrival time / remaining distance / remaining time).
class RouteGuidanceCard extends StatelessWidget {
  const RouteGuidanceCard({
    super.key,
    required this.settings,
    required this.data,
    this.showManeuverDistance = true,
  });

  final AppearanceSettings settings;
  final RouteGuidanceCardData data;

  /// نوشتهٔ فاصله تا پیچ بعدی زیرِ فلش. پیش‌فرض روشن است؛ اگر [RouteGuidanceCardData.distanceText]
  /// خالی باشد، کادرِ فلش خودبه‌خود فقط خودِ فلش را نشان می‌دهد.
  final bool showManeuverDistance;

  static const double _dw = 886.0;
  // Extra vertical room is required when the user requests the two-times
  // typography scale; it keeps the distance line clear of the stats strip.
  static const double _dh = 430.0;

  /// 0 -> [min], 0.5 (default) -> 1.0 (design size), 1 -> [max].
  static double _factor(double v, {required double min, required double max}) {
    final t = v.clamp(0.0, 1.0).toDouble();
    return t <= 0.5
        ? min + (1.0 - min) * (t / 0.5)
        : 1.0 + (max - 1.0) * ((t - 0.5) / 0.5);
  }

  static double _settingSize(
    double v, {
    required double min,
    required double max,
  }) =>
      min + (max - min) * v.clamp(0.0, 1.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final hf = _factor(settings.routeCardHeight, min: 0.85, max: 1.3);
    final arrowFactor = _factor(
      settings.routeCardArrowSize,
      min: 0.6,
      max: 1.5,
    );
    // اندازهٔ واقعی فونت (در فضای طراحی ۸۸۶ واحدی)؛ بدون ضریب ×۲.
    final distFont =
        _settingSize(settings.routeCardDistanceFontSize, min: 40, max: 92);
    final titleFont =
        _settingSize(settings.routeCardStreetFontSize, min: 40, max: 92);
    final statsLabelFont =
        _settingSize(settings.routeCardStatsLabelFontSize, min: 26, max: 56);
    final statsValueFont =
        _settingSize(settings.routeCardStatsValueFontSize, min: 32, max: 60);
    final family = settings.routeCardFontFamily.flutterFamily ?? 'Vazirmatn';
    final weightOverride = settings.routeCardFontWeight.flutterWeight;

    final border = settings.routeCardBorderColor;
    // Internal separators stay visible only as a subtle grouping cue; the
    // outer card border remains strong and is painted independently.
    final dividerColor = Color.lerp(
      border,
      Colors.white,
      .28,
    )!
        .withOpacity(.34);
    final softColor = Color.lerp(border, Colors.white, .22)!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final s = constraints.maxWidth / _dw;
        final cardH = _dh * hf * s;
        double x(double v) => v * s;
        double y(double v) => (v / _dh) * cardH;

        TextStyle ts(double size, FontWeight weight, Color color) => TextStyle(
              inherit: false,
              fontFamily: family,
              fontSize: size * s,
              fontWeight: weightOverride ?? weight,
              height: 1,
              color: color,
            );

        // ---- left column: only the maneuver icon ---------------------------
        final hasDistance =
            showManeuverDistance && data.distanceText.trim().isNotEmpty;
        final distSize = distFont;
        final distLineHeight = math.max(32.0, distFont * 1.45);
        final iconRegionH = hasDistance ? 150.0 : 214.0;
        final custom = data.iconWidget;
        final regionH = iconRegionH * hf;
        final iconBox = math.min(
          custom != null ? 170.0 : 190.0 * arrowFactor,
          regionH,
        );
        // مقیاسِ آیکونِ سفارشی نباید از کادرِ آیکون بیرون بزند.
        final customScale = math.min(
          data.iconScale.clamp(0.55, 1.45).toDouble(),
          regionH / iconBox,
        );
        final Widget arrowChild = custom != null
            ? Transform.scale(scale: customScale, child: custom)
            : ManeuverArrowIcon(
                modifier: _modifierForIcon(data.icon),
                color: settings.routeCardArrowColor,
                outlineColor: settings.routeCardArrowOutlineColor,
                borderColor: settings.routeCardArrowBorderColor,
                thickness: settings.routeCardArrowThickness,
              );

        // ---- stats ---------------------------------------------------------
        final labelStyle = ts(statsLabelFont, FontWeight.w700, softColor);
        final valueStyle = ts(
          statsValueFont,
          FontWeight.w800,
          settings.routeCardStatsColor,
        );
        final statIconColor = settings.routeCardStatsIconColor;

        Widget stat(
          double cx,
          double halfW,
          IconData icon,
          String label,
          String value,
        ) {
          return Positioned(
            left: x(cx - halfW),
            width: x(halfW * 2),
            top: y(304),
            height: y(100),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: x(36),
                    height: x(36),
                    child: Center(
                      child: AppIcon(icon, size: x(38), color: statIconColor),
                    ),
                  ),
                  SizedBox(width: x(9)),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(height: x(1)),
                      Text(label, maxLines: 1, style: labelStyle),
                      SizedBox(height: x(6)),
                      Text(value, maxLines: 1, style: valueStyle),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        Widget vLine(double cx, double w, double top, double bottom) =>
            Positioned(
              left: x(cx - w / 2),
              top: y(top),
              width: math.max(1.0, x(w)),
              height: y(bottom - top),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dividerColor,
                  borderRadius: BorderRadius.circular(x(w) / 2),
                ),
              ),
            );

        return MediaQuery(
          data:
              MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: SizedBox(
            width: constraints.maxWidth,
            height: cardH,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CardPainter(
                      backgroundColor: settings.routeCardBackgroundColor,
                      borderColor: border,
                      glowColor: settings.routeCardGlowColor,
                      opacity: settings.routeCardOpacity,
                      radius: settings.routeCardCornerRadius * 55.5 * s,
                      glowIntensity: settings.routeCardGlowIntensity,
                      scale: s,
                    ),
                  ),
                ),

                // Top row: maneuver icon/roundabout on the left.
                Positioned(
                  left: x(12),
                  top: y(8),
                  width: x(238),
                  height: y(iconRegionH + 6),
                  child: ClipRect(
                    child: Center(
                      child: SizedBox(
                        width: x(iconBox),
                        height: x(iconBox),
                        child: arrowChild,
                      ),
                    ),
                  ),
                ),
                // Distance to the maneuver, under the arrow.
                if (hasDistance)
                  Positioned(
                    left: x(10),
                    width: x(230),
                    top: y(166),
                    height: x(distLineHeight),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        data.distanceText,
                        maxLines: 1,
                        style: ts(
                          distSize,
                          FontWeight.w800,
                          settings.routeCardDistanceColor,
                        ),
                      ),
                    ),
                  ),

                // Divider between the top-left maneuver and route information.
                vLine(250, 3, 18, 220),

                // Instruction title: right edge x 840, baseline y 100 at 69px.
                // subtitleText is the dynamic street name, not a static
                // caption. It is shown on the second line under the maneuver.
                Positioned(
                  left: x(278),
                  width: x(574),
                  top: y(22),
                  height: y(205),
                  child: (data.subtitleText != null &&
                          data.subtitleText!.trim().isNotEmpty)
                      ? _InstructionTitleWithSubtitle(
                          title: data.streetText,
                          titleStyle: ts(
                            titleFont,
                            FontWeight.w800,
                            settings.routeCardStreetColor,
                          ),
                          subtitle: data.subtitleText!,
                          subtitleStyle: ts(
                            titleFont * 0.7,
                            FontWeight.w700,
                            softColor,
                          ),
                        )
                      : _InstructionText(
                          text: data.streetText,
                          style: ts(
                            titleFont,
                            FontWeight.w800,
                            settings.routeCardStreetColor,
                          ),
                        ),
                ),

                // Full-width lower stats strip: time / distance / arrival.
                Positioned(
                  left: x(14),
                  width: x(858),
                  top: y(300),
                  height: y(110),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: dividerColor.withOpacity(.72),
                        width: math.max(1, x(1.15)),
                      ),
                      borderRadius: BorderRadius.circular(x(22)),
                    ),
                  ),
                ),

                // Three equal lower columns spanning the whole card.
                vLine(300, 2, 310, 420),
                vLine(590, 2, 310, 420),
                stat(
                  160,
                  135,
                  Icons.schedule_outlined,
                  data.durationLabel,
                  data.durationValue,
                ),
                stat(
                  445,
                  135,
                  Icons.pin_drop_outlined,
                  data.remainingLabel,
                  data.remainingValue,
                ),
                stat(
                  730,
                  135,
                  Icons.sports_score,
                  data.etaLabel,
                  data.etaValue,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Right-aligned instruction. One line at full size when it fits; otherwise
/// two lines at 68% size (ellipsis after that).
class _InstructionText extends StatelessWidget {
  const _InstructionText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The title has a deliberately reserved rectangle. FittedBox is used
        // only as a safety net: the text can never enter the maneuver or the
        // statistics zone, even when the user increases the font size or the
        // card height changes.
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: box.maxWidth,
            height: box.maxHeight,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                text,
                maxLines: 2,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                textDirection: TextDirection.rtl,
                style: style.copyWith(height: 1.08),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Bold title on top, a smaller muted caption right under it (e.g. «در ادامه
/// مسیر») — both right-aligned, single line each, shrinking to fit their
/// shared reserved box rather than wrapping or overflowing.
class _InstructionTitleWithSubtitle extends StatelessWidget {
  const _InstructionTitleWithSubtitle({
    required this.title,
    required this.titleStyle,
    required this.subtitle,
    required this.subtitleStyle,
  });

  final String title;
  final TextStyle titleStyle;
  final String subtitle;
  final TextStyle subtitleStyle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        return SizedBox(
          width: box.maxWidth,
          height: box.maxHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.max,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: titleStyle.copyWith(height: 1.08),
                    ),
                  ),
                ),
              ),
              SizedBox(height: box.maxHeight * 0.03),
              Expanded(
                child: Align(
                  alignment: Alignment.topRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      textDirection: TextDirection.rtl,
                      style: subtitleStyle.copyWith(height: 1.08),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CardPainter extends CustomPainter {
  _CardPainter({
    required this.backgroundColor,
    required this.borderColor,
    required this.glowColor,
    required this.opacity,
    required this.radius,
    required this.glowIntensity,
    required this.scale,
  });

  final Color backgroundColor;
  final Color borderColor;
  final Color glowColor;
  final double opacity;
  final double radius;
  final double glowIntensity;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = math.max(1.0, 3.0 * scale);
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(stroke / 2),
      Radius.circular(radius),
    );
    final a = opacity.clamp(0.0, 1.0).toDouble();

    if (glowIntensity > 0) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = glowColor.withOpacity(
            (glowIntensity * .7).clamp(0.0, 1.0).toDouble(),
          )
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            (10.0 + glowIntensity * 16.0) * scale,
          ),
      );
    }

    // Reference fill: slightly brighter blue at the top, flat in the middle.
    const lift = Color(0xFF002878);
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(backgroundColor, lift, .30)!.withOpacity(a),
            backgroundColor.withOpacity(a),
            Color.lerp(backgroundColor, lift, .15)!.withOpacity(a),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // Reference border: brightest along the top edge, softer on the sides.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(borderColor, Colors.white, .6)!,
            borderColor,
            Color.lerp(borderColor, Colors.white, .3)!,
          ],
          stops: const [0.0, 0.3, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _CardPainter o) =>
      o.backgroundColor != backgroundColor ||
      o.borderColor != borderColor ||
      o.glowColor != glowColor ||
      o.opacity != opacity ||
      o.radius != radius ||
      o.glowIntensity != glowIntensity ||
      o.scale != scale;
}


String _modifierForIcon(IconData icon) {
  if (icon == Icons.turn_slight_left_rounded) return 'slight left';
  if (icon == Icons.turn_left_rounded) return 'left';
  if (icon == Icons.turn_sharp_left_rounded) return 'sharp left';
  if (icon == Icons.turn_slight_right_rounded) return 'slight right';
  if (icon == Icons.turn_right_rounded) return 'right';
  if (icon == Icons.turn_sharp_right_rounded) return 'sharp right';
  if (icon == Icons.u_turn_left_rounded) return 'u turn left';
  if (icon == Icons.u_turn_right_rounded) return 'u turn right';
  return 'straight';
}

/// Pixel-traced, vector maneuver arrow used by the navigation card.
/// The geometry is based on the supplied reference artwork and remains
/// resolution-independent. Color, scale and thickness are applied at runtime.
class ManeuverArrowIcon extends StatelessWidget {
  const ManeuverArrowIcon({
    super.key,
    required this.modifier,
    this.angleDegrees,
    this.color,
    this.outlineColor = Colors.white,
    this.borderColor = Colors.black,
    this.ghostOpacity = .28,
    this.thickness = .72,
  });

  final String? modifier;
  final double? angleDegrees;
  final Color? color;

  /// کادرِ داخلی (سفید) و بیرونی (مشکی) و شفافیتِ مسیرهای جایگزینِ کم‌رنگ.
  final Color outlineColor;
  final Color borderColor;
  final double ghostOpacity;
  final double thickness;

  String get _normalized => (modifier ?? 'straight')
      .trim()
      .toLowerCase()
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ');

  String get _kind {
    final m = _normalized;
    final right = m.contains('right');
    final left = m.contains('left');

    // In right-hand-traffic routing (including Iran), a normal U-turn is
    // represented by the left-curving U-turn glyph. Explicit left/right
    // modifiers remain respected when the routing engine supplies them.
    if (m.contains('uturn') || m.contains('u turn') || m.contains('u-turn')) {
      return right ? 'u_turn_right' : 'u_turn_left';
    }
    if (m.contains('lane')) return right ? 'lane_shift_right' : 'lane_shift_left';
    if (m.contains('fork')) {
      if (left && right) return 'fork_both';
      if (left) return 'fork_left';
      if (right) return 'fork_right';
      return 'fork_straight';
    }
    if (m.contains('merge')) return right ? 'merge_right' : 'merge_left';
    if (m.contains('keep')) return right ? 'keep_right' : 'keep_left';
    if (m.contains('sharp')) return right ? 'sharp_right' : 'sharp_left';
    if (m.contains('slight')) return right ? 'slight_right' : 'slight_left';
    if (left) return 'left';
    if (right) return 'right';

    final a = angleDegrees;
    if (a != null && a.isFinite && a.abs() >= 12) {
      if (a.abs() >= 155) return a < 0 ? 'u_turn_left' : 'u_turn_right';
      if (a.abs() >= 115) return a < 0 ? 'sharp_left' : 'sharp_right';
      if (a.abs() >= 58) return a < 0 ? 'left' : 'right';
      return a < 0 ? 'slight_left' : 'slight_right';
    }
    return 'straight';
  }

  @override
  Widget build(BuildContext context) {
    return ReferenceManeuverArrow(
      kind: _kind,
      color: color ?? const Color(0xFF0A90FB),
      outlineColor: outlineColor,
      borderColor: borderColor,
      ghostOpacity: ghostOpacity,
      thickness: thickness,
    );
  }
}
