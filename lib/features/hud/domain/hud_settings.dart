import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

/// مدلِ واحد و غیرقابل‌تغییرِ تنظیماتِ «هد آپ دیسپلی» (HUD).
///
/// همانند AppearanceSettings، همه‌ی مقادیر در یک شیء واحد
/// نگه‌داری و با یک کلید JSON در SettingsRepository ذخیره می‌شوند.
/// چیدمان‌های آماده‌ی HUD (مثل Magic Earth: Type 1 … Type 4).
enum HudStyle { type1, type2, type3, type4 }

/// رنگ‌های نهایی HUD؛ هر رنگی که کاربر تعیین نکرده باشد از پالت پیش‌فرضِ
/// همان استایل می‌آید.
@immutable
class HudPalette {
  const HudPalette({
    required this.arrow,
    required this.distance,
    required this.speed,
    required this.info,
  });

  final Color arrow;
  final Color distance;
  final Color speed;

  /// ساعت، قطب‌نما و متن‌های جانبی.
  final Color info;

  static HudPalette defaultFor(HudStyle style) {
    switch (style) {
      case HudStyle.type1:
        return const HudPalette(
          arrow: Color(0xFF3DDC3D),
          distance: Color(0xFF3DDC3D),
          speed: Color(0xFFFFFFFF),
          info: Color(0xFFFFE23A),
        );
      case HudStyle.type2:
        return const HudPalette(
          arrow: Color(0xFF2EC4C4),
          distance: Color(0xFF2EC4C4),
          speed: Color(0xFF2EC4C4),
          info: Color(0xFF2EC4C4),
        );
      case HudStyle.type3:
        return const HudPalette(
          arrow: Color(0xFFC9C23A),
          distance: Color(0xFFC9C23A),
          speed: Color(0xFF35E04A),
          info: Color(0xFFFFFFFF),
        );
      case HudStyle.type4:
        return const HudPalette(
          arrow: Color(0xFFE6E6E6),
          distance: Color(0xFFFFFFFF),
          speed: Color(0xFF35E04A),
          info: Color(0xFFFFFFFF),
        );
    }
  }
}

@immutable
class HudSettings {
  const HudSettings({
    this.enabled = false,
    this.brightnessPercent = 70,
    this.mirrorImage = true,
    this.scalePercent = 100,
    this.showSpeed = true,
    this.showSpeedLimit = true,
    this.showNextManeuver = true,
    this.showDistanceToManeuver = true,
    this.showCompassHeading = true,
    this.showRouteAlerts = true,
    this.showOtherInfo = false,
    this.horizontalOffset = 0.0,
    this.verticalOffset = 0.0,
    this.style = HudStyle.type1,
    this.showClock = true,
    this.arrowColor,
    this.distanceColor,
    this.speedColor,
    this.infoColor,
  });

  final bool enabled;

  /// چیدمان انتخابی (Type 1 تا Type 4).
  final HudStyle style;

  /// نمایش ساعت.
  final bool showClock;

  /// رنگ‌های دلخواه (ARGB). null یعنی رنگ پیش‌فرض همان استایل.
  final int? arrowColor;
  final int? distanceColor;
  final int? speedColor;
  final int? infoColor;

  /// رنگ‌های نهایی با در نظر گرفتن انتخاب کاربر.
  HudPalette get palette {
    final base = HudPalette.defaultFor(style);
    return HudPalette(
      arrow: arrowColor == null ? base.arrow : Color(arrowColor!),
      distance: distanceColor == null ? base.distance : Color(distanceColor!),
      speed: speedColor == null ? base.speed : Color(speedColor!),
      info: infoColor == null ? base.info : Color(infoColor!),
    );
  }

  bool get hasCustomColors =>
      arrowColor != null ||
      distanceColor != null ||
      speedColor != null ||
      infoColor != null;

  /// ۱۰ تا ۱۰۰ درصد.
  final int brightnessPercent;

  /// آینه‌ای کردن تصویر برای بازتاب صحیح روی شیشه جلو.
  final bool mirrorImage;

  /// ۵۰ تا ۱۳۰ درصد.
  final int scalePercent;

  final bool showSpeed;
  final bool showSpeedLimit;
  final bool showNextManeuver;
  final bool showDistanceToManeuver;
  final bool showCompassHeading;
  final bool showRouteAlerts;
  final bool showOtherInfo;

  /// جابه‌جایی موقعیت کلی نمایش روی شیشه (-1.0 تا 1.0، نسبت به مرکز).
  final double horizontalOffset;
  final double verticalOffset;

  HudSettings copyWith({
    bool? enabled,
    int? brightnessPercent,
    bool? mirrorImage,
    int? scalePercent,
    bool? showSpeed,
    bool? showSpeedLimit,
    bool? showNextManeuver,
    bool? showDistanceToManeuver,
    bool? showCompassHeading,
    bool? showRouteAlerts,
    bool? showOtherInfo,
    double? horizontalOffset,
    double? verticalOffset,
    HudStyle? style,
    bool? showClock,
    int? arrowColor,
    int? distanceColor,
    int? speedColor,
    int? infoColor,
    bool resetColors = false,
  }) {
    return HudSettings(
      style: style ?? this.style,
      showClock: showClock ?? this.showClock,
      arrowColor: resetColors ? null : (arrowColor ?? this.arrowColor),
      distanceColor:
          resetColors ? null : (distanceColor ?? this.distanceColor),
      speedColor: resetColors ? null : (speedColor ?? this.speedColor),
      infoColor: resetColors ? null : (infoColor ?? this.infoColor),
      enabled: enabled ?? this.enabled,
      brightnessPercent: brightnessPercent ?? this.brightnessPercent,
      mirrorImage: mirrorImage ?? this.mirrorImage,
      scalePercent: scalePercent ?? this.scalePercent,
      showSpeed: showSpeed ?? this.showSpeed,
      showSpeedLimit: showSpeedLimit ?? this.showSpeedLimit,
      showNextManeuver: showNextManeuver ?? this.showNextManeuver,
      showDistanceToManeuver:
          showDistanceToManeuver ?? this.showDistanceToManeuver,
      showCompassHeading: showCompassHeading ?? this.showCompassHeading,
      showRouteAlerts: showRouteAlerts ?? this.showRouteAlerts,
      showOtherInfo: showOtherInfo ?? this.showOtherInfo,
      horizontalOffset: horizontalOffset ?? this.horizontalOffset,
      verticalOffset: verticalOffset ?? this.verticalOffset,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'brightnessPercent': brightnessPercent,
        'mirrorImage': mirrorImage,
        'scalePercent': scalePercent,
        'showSpeed': showSpeed,
        'showSpeedLimit': showSpeedLimit,
        'showNextManeuver': showNextManeuver,
        'showDistanceToManeuver': showDistanceToManeuver,
        'showCompassHeading': showCompassHeading,
        'showRouteAlerts': showRouteAlerts,
        'showOtherInfo': showOtherInfo,
        'horizontalOffset': horizontalOffset,
        'verticalOffset': verticalOffset,
        'style': style.index,
        'showClock': showClock,
        'arrowColor': arrowColor,
        'distanceColor': distanceColor,
        'speedColor': speedColor,
        'infoColor': infoColor,
      };

  String serialize() => jsonEncode(toJson());

  static bool _boolOr(dynamic raw, bool fallback) =>
      raw is bool ? raw : fallback;

  static int _intOr(dynamic raw, int fallback) =>
      raw is num ? raw.toInt() : fallback;

  static double _numOr(dynamic raw, double fallback) =>
      raw is num ? raw.toDouble() : fallback;

  factory HudSettings.deserialize(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      const fallback = HudSettings();
      return HudSettings(
        enabled: _boolOr(map['enabled'], fallback.enabled),
        brightnessPercent:
            _intOr(map['brightnessPercent'], fallback.brightnessPercent),
        mirrorImage: _boolOr(map['mirrorImage'], fallback.mirrorImage),
        scalePercent: _intOr(map['scalePercent'], fallback.scalePercent),
        showSpeed: _boolOr(map['showSpeed'], fallback.showSpeed),
        showSpeedLimit: _boolOr(map['showSpeedLimit'], fallback.showSpeedLimit),
        showNextManeuver:
            _boolOr(map['showNextManeuver'], fallback.showNextManeuver),
        showDistanceToManeuver: _boolOr(
            map['showDistanceToManeuver'], fallback.showDistanceToManeuver),
        showCompassHeading:
            _boolOr(map['showCompassHeading'], fallback.showCompassHeading),
        showRouteAlerts:
            _boolOr(map['showRouteAlerts'], fallback.showRouteAlerts),
        showOtherInfo: _boolOr(map['showOtherInfo'], fallback.showOtherInfo),
        horizontalOffset:
            _numOr(map['horizontalOffset'], fallback.horizontalOffset),
        verticalOffset: _numOr(map['verticalOffset'], fallback.verticalOffset),
        style: () {
          final raw = map['style'];
          if (raw is num &&
              raw.toInt() >= 0 &&
              raw.toInt() < HudStyle.values.length) {
            return HudStyle.values[raw.toInt()];
          }
          return fallback.style;
        }(),
        showClock: _boolOr(map['showClock'], fallback.showClock),
        arrowColor: map['arrowColor'] is num
            ? (map['arrowColor'] as num).toInt()
            : null,
        distanceColor: map['distanceColor'] is num
            ? (map['distanceColor'] as num).toInt()
            : null,
        speedColor: map['speedColor'] is num
            ? (map['speedColor'] as num).toInt()
            : null,
        infoColor: map['infoColor'] is num
            ? (map['infoColor'] as num).toInt()
            : null,
      );
    } catch (_) {
      return const HudSettings();
    }
  }
}
