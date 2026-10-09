import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/domain/appearance_settings.dart';
import '../../settings/presentation/appearance_settings_providers.dart';
import '../../map/presentation/weather_map_overlay.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

/// وضعیت‌های شناور نقشه عمداً از هم مستقل هستند: خاموش شدن آب‌وهوا نباید
/// جای ساعت/باتری را بگیرد یا آن‌ها را پنهان کند.
class UnifiedStatusMapOverlay extends ConsumerStatefulWidget {
  const UnifiedStatusMapOverlay({super.key});
  @override
  ConsumerState<UnifiedStatusMapOverlay> createState() =>
      _UnifiedStatusMapOverlayState();
}

class _UnifiedStatusMapOverlayState
    extends ConsumerState<UnifiedStatusMapOverlay> {
  static const _channel = MethodChannel('ir.abtin.abtin_maps/device_battery');
  Timer? _timer;
  int _battery = -1;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _readBattery();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      _readBattery();
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  Future<void> _readBattery() async {
    try {
      final value = await _channel.invokeMethod<int>('batteryLevel');
      if (mounted && value != null) setState(() => _battery = value);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appearanceSettingsProvider);
    final masterOn = s.systemInfoEnabled;
    final weatherOn = masterOn && ref.watch(weatherWidgetEnabledProvider);
    final aqiOn = masterOn && ref.watch(airQualityWidgetEnabledProvider);
    final snapshot = ref.watch(weatherSnapshotProvider);
    final clockOn = masterOn && ref.watch(clockWidgetEnabledProvider);
    final batteryOn = masterOn && ref.watch(batteryWidgetEnabledProvider);
    final anyOn = weatherOn || aqiOn || clockOn || batteryOn;

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (anyOn)
            _StatusBox(
              horizontal: s.systemInfoHorizontalPercent,
              vertical: s.systemInfoVerticalPercent,
              scale: s.systemInfoSize,
              background: s.systemInfoBgColor,
              opacity: s.systemInfoBgOpacity,
              contentAlign: s.systemInfoContentAlign,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (weatherOn || aqiOn)
                    _WeatherContent(
                      weatherOn: weatherOn,
                      aqiOn: aqiOn,
                      snapshot: snapshot,
                      textColor: s.weatherTextColor,
                      textScale: s.weatherTextSize,
                      fontFamily: s.weatherFontFamily.flutterFamily,
                    ),
                  if ((weatherOn || aqiOn) && (clockOn || batteryOn))
                    const SizedBox(height: 8),
                  if (clockOn || batteryOn)
                    _SystemContent(
                      clockOn: clockOn,
                      batteryOn: batteryOn,
                      now: _now,
                      battery: _battery,
                      textColor: s.systemInfoTextColor,
                      batteryColor: s.systemInfoBatteryColor.alpha == 0
                          ? const Color(0xFF34D058)
                          : s.systemInfoBatteryColor,
                      batteryTextColor: s.systemInfoBatteryTextColor.alpha == 0
                          ? s.systemInfoTextColor
                          : s.systemInfoBatteryTextColor,
                      batteryTextWeight:
                          s.systemInfoBatteryTextWeight.flutterWeight ??
                          FontWeight.bold,
                      clockFontSize: s.systemInfoClockFontSize,
                      batteryFontSize: s.systemInfoBatteryFontSize,
                      clockFontFamily:
                          s.systemInfoClockFontFamily.flutterFamily,
                      batteryFontFamily:
                          s.systemInfoBatteryFontFamily.flutterFamily,
                      batteryOrientation: s.systemInfoBatteryOrientation,
                      batterySizePercent: s.systemInfoBatterySizePercent,
                      contentAlign: s.systemInfoContentAlign,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({
    required this.horizontal,
    required this.vertical,
    required this.scale,
    required this.background,
    required this.opacity,
    required this.contentAlign,
    required this.child,
  });

  final double horizontal;
  final double vertical;
  final double scale;
  final Color background;
  final double opacity;
  final double contentAlign;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.of(context).padding;
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, safe.top + 12, 12, safe.bottom + 12),
        child: Align(
          alignment: Alignment(
            horizontal.clamp(0, 100).toDouble() / 50 - 1,
            vertical.clamp(0, 100).toDouble() / 50 - 1,
          ),
          child: Transform.scale(
            scale: (scale / 100).clamp(.7, 1.5).toDouble(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: background.withOpacity(opacity.clamp(0, 1).toDouble()),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(.10)),
              ),
              child: DefaultTextStyle.merge(
                textAlign: contentAlign >= 50
                    ? TextAlign.right
                    : TextAlign.left,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WeatherContent extends StatelessWidget {
  const _WeatherContent({
    required this.weatherOn,
    required this.aqiOn,
    required this.snapshot,
    required this.textColor,
    required this.textScale,
    required this.fontFamily,
  });

  final bool weatherOn;
  final bool aqiOn;
  final WeatherSnapshot? snapshot;
  final Color textColor;
  final double textScale;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (weatherOn) ...[
        Text(
          snapshot?.condition ?? '☁️',
          style: TextStyle(fontSize: 20, fontFamily: fontFamily),
        ),
        const SizedBox(height: 2),
        Text(
          snapshot == null ? '—' : '${snapshot!.temperature.round()}°C',
          style: TextStyle(
            color: textColor,
            fontSize: 16 * (textScale / 100).clamp(.6, 2.0),
            fontWeight: FontWeight.w800,
            fontFamily: fontFamily,
          ),
        ),
      ],
      if (weatherOn && aqiOn) const SizedBox(height: 6),
      if (aqiOn) ...[
        const AppIcon(Icons.air_rounded, size: 19, color: Color(0xFF56D6A0)),
        const SizedBox(height: 2),
        Text(
          'AQI ${snapshot?.airQualityIndex ?? '—'}',
          style: TextStyle(
            color: textColor,
            fontSize: 14 * (textScale / 100).clamp(.6, 2.0),
            fontWeight: FontWeight.w800,
            fontFamily: fontFamily,
          ),
        ),
      ],
    ],
  );
}

class _SystemContent extends StatelessWidget {
  const _SystemContent({
    required this.clockOn,
    required this.batteryOn,
    required this.now,
    required this.battery,
    required this.textColor,
    required this.batteryColor,
    required this.batteryTextColor,
    required this.batteryTextWeight,
    required this.clockFontSize,
    required this.batteryFontSize,
    required this.batteryOrientation,
    required this.batterySizePercent,
    required this.contentAlign,
    required this.clockFontFamily,
    required this.batteryFontFamily,
  });

  final bool clockOn;
  final bool batteryOn;
  final DateTime now;
  final int battery;
  final Color textColor;
  final Color batteryColor;
  final Color batteryTextColor;
  final FontWeight batteryTextWeight;
  final double clockFontSize;
  final double batteryFontSize;
  final BatteryIconOrientation batteryOrientation;
  final double batterySizePercent;
  final double contentAlign;
  final String? clockFontFamily;
  final String? batteryFontFamily;

  @override
  Widget build(BuildContext context) {
    final hhmm =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: contentAlign >= 50
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (clockOn)
          Text(
            hhmm,
            style: TextStyle(
              color: textColor,
              fontSize: 15 * (clockFontSize / 100).clamp(.6, 2.0),
              fontWeight: FontWeight.w800,
              fontFamily: clockFontFamily,
            ),
          ),
        if (clockOn && batteryOn) const SizedBox(height: 5),
        if (batteryOn)
          _BatteryIcon(
            level: battery,
            iconColor: batteryColor,
            textColor: batteryTextColor,
            textWeight: batteryTextWeight,
            orientation: batteryOrientation,
            sizePercent: batterySizePercent,
            textScale: batteryFontSize / 100,
            fontFamily: batteryFontFamily,
          ),
      ],
    );
  }
}

class _BatteryIcon extends StatelessWidget {
  const _BatteryIcon({
    required this.level,
    required this.iconColor,
    required this.textColor,
    required this.textWeight,
    required this.orientation,
    required this.sizePercent,
    required this.textScale,
    required this.fontFamily,
  });

  final int level;
  final Color iconColor;
  final Color textColor;
  final FontWeight textWeight;
  final BatteryIconOrientation orientation;
  final double sizePercent;
  final double textScale;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final scale = (sizePercent / 100).clamp(.5, 2.0).toDouble();
    final box = SizedBox(
      width: 29 * scale,
      height: 18 * scale,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.infinite,
            painter: _BatteryPainter(
              fraction: level < 0 ? 0 : (level / 100).clamp(0.0, 1.0),
              color: level < 0
                  ? iconColor
                  : level <= 20
                      ? const Color(0xFFFF3B4A)
                      : level <= 45
                          ? const Color(0xFFFFB020)
                          : iconColor,
            ),
          ),
          Text(
            level >= 0 ? '$level%' : '—',
            style: TextStyle(
              color: textColor,
              fontSize: ((sizePercent / 100 * 7) * textScale)
                  .clamp(5.0, 24.0)
                  .toDouble(),
              fontWeight: textWeight,
              fontFamily: fontFamily,
            ),
          ),
        ],
      ),
    );
    return orientation == BatteryIconOrientation.horizontal
        ? box
        : SizedBox(
            width: 18 * scale,
            height: 29 * scale,
            child: RotatedBox(quarterTurns: 3, child: box),
          );
  }
}

/// باتریِ سه‌بعدی: بدنهٔ شیشه‌ایِ تیره با لبهٔ برجسته، پرشدگیِ گرادیانیِ
/// رنگی (بالا روشن ← پایین تیره)، براقیِ نیمهٔ بالا، درخششِ ملایم و ترمینالِ
/// فلزی. رنگ از سطحِ شارژ می‌آید (سبز/کهربایی/قرمز).
class _BatteryPainter extends CustomPainter {
  const _BatteryPainter({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  static Color _shade(Color c, double amount) => amount >= 0
      ? Color.lerp(c, Colors.white, amount)!
      : Color.lerp(c, Colors.black, -amount)!;

  @override
  void paint(Canvas c, Size s) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, s.width - 5, s.height - 2),
      const Radius.circular(4.5),
    );

    // سایهٔ زیرِ بدنه (عمق).
    c.drawRRect(
      body.shift(const Offset(0, 1.4)),
      Paint()
        ..color = Colors.black.withOpacity(.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );

    // بدنهٔ شیشه‌ای.
    c.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2A3442), Color(0xFF0B1118)],
        ).createShader(body.outerRect),
    );

    // ترمینالِ فلزی.
    final term = RRect.fromRectAndRadius(
      Rect.fromLTWH(s.width - 4, s.height * .32, 3, s.height * .36),
      const Radius.circular(1.5),
    );
    c.drawRRect(
      term,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_shade(color, .45), _shade(color, -.25)],
        ).createShader(term.outerRect),
    );

    if (fraction > 0) {
      final fillRect = Rect.fromLTWH(
        2.6,
        2.6,
        ((s.width - 8.2) * fraction).clamp(2.0, s.width - 8.2).toDouble(),
        s.height - 5.2,
      );
      final fill = RRect.fromRectAndRadius(fillRect, const Radius.circular(3));

      // درخششِ رنگی.
      c.drawRRect(
        fill,
        Paint()
          ..color = color.withOpacity(.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
      );
      // پرشدگیِ گرادیانی.
      c.drawRRect(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_shade(color, .42), color, _shade(color, -.32)],
            stops: const [0, .45, 1],
          ).createShader(fillRect),
      );
      // براقیِ نیمهٔ بالا.
      c.save();
      c.clipRRect(fill);
      c.drawRect(
        Rect.fromLTWH(fillRect.left, fillRect.top, fillRect.width,
            fillRect.height * .48),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withOpacity(.55),
              Colors.white.withOpacity(.05),
            ],
          ).createShader(fillRect),
      );
      c.restore();
    }

    // لبهٔ برجستهٔ بدنه (نور از بالا).
    c.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(.75),
            _shade(color, -.1).withOpacity(.55),
          ],
        ).createShader(body.outerRect),
    );
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter old) =>
      old.fraction != fraction || old.color != color;
}
