import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_localizations.dart';
import '../../gps/data/location_service.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../routing/data/routing_service.dart'
    show RouteAlert, RouteAlertType, RouteInstruction;
import '../../routing/presentation/road_alert_badge.dart' show roadAlertAsset;
import '../../routing/presentation/routing_providers.dart';
import '../domain/hud_maneuver_icon.dart';
import 'hud_settings_providers.dart';
import 'flat_phone_provider.dart';
import 'hud_live_data.dart';
import 'hud_styles.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

/// نزدیک‌ترین [RouteAlert] جلوی خودرو، در بازهٔ [maxDistanceM] و در مخروطِ
/// جلوی heading — همان الگویی که home_screen.dart برای نشان‌دادن هشدار
/// جاده روی نقشهٔ اصلی استفاده می‌کند، اینجا برای بلاکِ HUD تکرار شده تا
/// آیکونِ ثابتِ قبلی (که به هیچ داده‌ای وصل نبود) با یک هشدارِ واقعی
/// جایگزین شود.
RouteAlert? nearestAheadRouteAlert(
  ActiveNavigation? nav,
  VehiclePosition? position, {
  double maxDistanceM = 300.0,
  double maxBearingDeltaDeg = 70.0,
}) {
  if (nav == null || position == null) return null;
  RouteAlert? best;
  var bestDistance = double.infinity;
  for (final alert in nav.route.alerts) {
    final distance = _hudDistanceM(
      position.lat,
      position.lng,
      alert.location.latitude,
      alert.location.longitude,
    );
    if (distance > maxDistanceM || distance >= bestDistance) continue;
    if (position.headingDeg.isFinite) {
      final bearing = _hudBearingDeg(
        position.lat,
        position.lng,
        alert.location.latitude,
        alert.location.longitude,
      );
      final delta = ((bearing - position.headingDeg + 540) % 360) - 180;
      if (delta.abs() > maxBearingDeltaDeg) continue;
    }
    best = alert;
    bestDistance = distance;
  }
  return best;
}

double _hudDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _hudBearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dl = (lng2 - lng1) * math.pi / 180.0;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}

/// نمایشِ واقعیِ HUD حین رانندگی.
///
/// قبلاً این صفحه فلشِ «مستقیم» را ثابت نشان می‌داد (رجوع کنید به تصویرِ
/// باگ). حالا آیکونِ جهت از [hudManeuverIcon] و از رویِ دستورِ واقعیِ
/// ناوبریِ جاری (`activeNavigationProvider`) ساخته می‌شود؛ یعنی برای هر
/// میدان یا پیچ به هر سمت، همان جهتِ واقعی (چپ/راست/تند/ملایم/میدان/دور زدن)
/// نمایش داده می‌شود، نه یک فلشِ یکسان برای همه‌ی حالت‌ها.
class HudDisplayScreen extends ConsumerStatefulWidget {
  const HudDisplayScreen({super.key});

  @override
  ConsumerState<HudDisplayScreen> createState() => _HudDisplayScreenState();
}

class _HudDisplayScreenState extends ConsumerState<HudDisplayScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _validateHudConditions(HudSettings settings, ActiveNavigation? nav) {
    if (settings.enabled && nav != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.canPop()) context.pop();
    });
  }

  String _compassLabel(double? headingDeg, String Function(String) t) {
    if (headingDeg == null) return '--';
    const keys = [
      'hud_dir_n',
      'hud_dir_ne',
      'hud_dir_e',
      'hud_dir_se',
      'hud_dir_s',
      'hud_dir_sw',
      'hud_dir_w',
      'hud_dir_nw',
    ];
    final idx = (((headingDeg % 360) + 22.5) / 45).floor() % 8;
    return t(keys[idx]);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(hudSettingsProvider);
    final nav = ref.watch(activeNavigationProvider);
    // بعد از باز شدن، HUD فقط با دکمهٔ ضربدر بسته می‌شود؛ لرزش/شیب دیگر
    // آن را نمی‌بندد.
    // همان منبعِ سرعت‌سنجِ صفحهٔ اصلی (جریان نرم و مسیر-محور)؛ اگر هنوز چیزی
    // نداشت، GPS خام.
    final navPos = ref.watch(navigationPositionProvider).valueOrNull;
    final rawPos = ref.watch(vehiclePositionProvider).valueOrNull;
    final sharedLimit = ref.watch(hudSpeedLimitProvider);
    final sharedAlert = ref.watch(hudNextAlertProvider);
    _validateHudConditions(settings, nav);
    String t(String key) => AppStrings.get(context, ref, key);

    final vehiclePosition = navPos ?? rawPos;
    final speedKmh = vehiclePosition?.speedKmh ?? 0;
    final headingDeg = vehiclePosition?.headingDeg;
    final instruction = nav?.currentInstruction;
    final aheadAlert =
        sharedAlert ?? nearestAheadRouteAlert(nav, vehiclePosition);
    final speedLimit = instruction?.speedLimit ?? sharedLimit;

    final scale = (settings.scalePercent / 100).clamp(0.5, 1.3);
    final brightness = (settings.brightnessPercent / 100).clamp(0.10, 1.0);

    String dist(double meters) => meters >= 1000
        ? AppStrings.getWithParams(context, ref, 'route_distance_km',
            {'value': (meters / 1000).toStringAsFixed(1)})
        : AppStrings.getWithParams(
            context, ref, 'route_distance_m', {'value': meters.round()});
    final now = DateTime.now();
    final clockText =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final hasInstruction = nav != null && instruction != null;
    final frame = HudFrameData(
      speedKmh: speedKmh.round(),
      speedUnit: t('hud_speed_unit'),
      speedLimit: speedLimit,
      distanceLabel: nav == null ? null : dist(nav.distanceToNextManeuverM),
      maneuverIcon: hasInstruction
          ? hudManeuverIcon(instruction.type, instruction.modifier)
          : null,
      arrived: hasInstruction && instruction.type == 'arrive',
      arrivedLabel: t('hud_arrived'),
      clockText: clockText,
      compassLabel: _compassLabel(headingDeg, t),
      alertAsset: aheadAlert == null ? null : roadAlertAsset(aheadAlert.type),
      remainingLabel: nav == null
          ? null
          : '${t('hud_remaining')}: ${dist(nav.remainingDistanceKm * 1000)}',
      noNavigationLabel: t('hud_no_active_navigation'),
    );

    Widget content = Container(
      color: Colors.black,
      child: SafeArea(
        child: Opacity(
          opacity: brightness,
          child: LayoutBuilder(
            builder: (context, box) {
              // بومِ ۱۶:۹ تا حد امکان بزرگ می‌شود؛ مقیاس/جابه‌جایی کاربر روی
              // همین بوم اعمال می‌شود.
              final w = math.min(
                  box.maxWidth, box.maxHeight * kHudCanvasW / kHudCanvasH);
              final h = w * kHudCanvasH / kHudCanvasW;
              return Align(
                alignment: Alignment(
                  settings.horizontalOffset,
                  settings.verticalOffset,
                ),
                child: Transform.scale(
                  scale: scale,
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: HudStyleView(settings: settings, data: frame),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    if (settings.mirrorImage) {
      content = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0),
        child: content,
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const AppIcon(Icons.close_rounded, color: Colors.white54),
              onPressed: () => context.pop(),
            ),
          ),
        ],
      ),
    );
  }
}
