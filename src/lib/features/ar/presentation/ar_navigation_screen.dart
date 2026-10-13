import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/localization/app_localizations.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../hud/domain/hud_maneuver_icon.dart';
import '../../hud/presentation/hud_display_screen.dart'
    show nearestAheadRouteAlert;
import '../../hud/presentation/hud_live_data.dart';
import '../../routing/data/routing_service.dart' show RouteAlertType;
import '../../routing/presentation/road_alert_badge.dart' show roadAlertAsset;
import '../../routing/presentation/routing_providers.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

class ArNavigationScreen extends ConsumerStatefulWidget {
  const ArNavigationScreen({super.key});

  @override
  ConsumerState<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends ConsumerState<ArNavigationScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _permanentlyDenied = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final c = _controller;
      _controller = null;
      c?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _startCamera();
    }
  }

  Future<void> _startCamera() async {
    if (_starting) return;
    _starting = true;
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() {
          _permanentlyDenied = status.isPermanentlyDenied;
          _error = 'برای نمای واقعی، اجازه‌ی دسترسی به دوربین لازم است.';
        });
        return;
      }
      final cams = await availableCameras();
      final back = cams.where((c) => c.lensDirection == CameraLensDirection.back);
      if (back.isEmpty) {
        if (!mounted) return;
        setState(() => _error = 'دوربین پشت گوشی پیدا نشد.');
        return;
      }
      final controller = CameraController(
        back.first,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'راه‌اندازی دوربین ناموفق بود.');
    } finally {
      _starting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(activeNavigationProvider);
    final navPos = ref.watch(navigationPositionProvider).valueOrNull;
    final rawPos = ref.watch(vehiclePositionProvider).valueOrNull;
    final sharedLimit = ref.watch(hudSpeedLimitProvider);
    final sharedAlert = ref.watch(hudNextAlertProvider);

    final pos = navPos ?? rawPos;
    final speed = (pos?.speedKmh ?? 0).round();
    final instruction = nav?.currentInstruction;
    final limit = instruction?.speedLimit ?? sharedLimit;
    final alert = sharedAlert ?? nearestAheadRouteAlert(nav, pos);
    final alertDistance = (alert != null && pos != null)
        ? _distanceM(pos.lat, pos.lng, alert.location.latitude,
            alert.location.longitude)
        : null;
    final overSpeed = limit != null && speed > limit + 2;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCamera(),
          const _EdgeShade(),
          if (nav == null || instruction == null)
            Center(
              child: _Pill(
                  text: AppStrings.get(context, ref, 'hud_no_active_navigation')),
            )
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: _ManeuverBanner(
                        icon: hudManeuverIcon(
                            instruction.type, instruction.modifier),
                        distance: _fmtDist(nav.distanceToNextManeuverM),
                        street: instruction.text,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _SpeedCluster(
                        limit: limit,
                        speed: speed,
                        over: overSpeed,
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: _TripInfo(
                        text: _tripText(nav),
                      ),
                    ),
                    if (alert != null)
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _AlertChip(
                            asset: roadAlertAsset(alert.type),
                            label: _alertLabel(alert.type),
                            distance: alertDistance == null
                                ? null
                                : _fmtDist(alertDistance),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  style: IconButton.styleFrom(
                      backgroundColor: Colors.black45),
                  icon: const AppIcon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => context.pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCamera() {
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      return ValueListenableBuilder<CameraValue>(
        valueListenable: c,
        builder: (context, v, _) {
          final o = v.lockedCaptureOrientation ?? v.deviceOrientation;
          final landscape = o == DeviceOrientation.landscapeLeft ||
              o == DeviceOrientation.landscapeRight;
          final ar = v.aspectRatio;
          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: landscape ? 100 * ar : 100,
                height: landscape ? 100 : 100 * ar,
                child: CameraPreview(c),
              ),
            ),
          );
        },
      );
    }
    if (_error != null) {
      return Container(
        color: const Color(0xFF10151C),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _permanentlyDenied ? openAppSettings : _startCamera,
              child: Text(_permanentlyDenied ? 'باز کردن تنظیمات' : 'تلاش دوباره'),
            ),
          ],
        ),
      );
    }
    return const ColoredBox(
      color: Colors.black,
      child: Center(child: CircularProgressIndicator()),
    );
  }

  String _fmtDist(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} km';
    final rounded = m >= 100 ? (m / 10).round() * 10 : m.round();
    return '$rounded m';
  }

  String _tripText(ActiveNavigation nav) {
    final totalKm = nav.route.distanceKm;
    final remKm = nav.remainingDistanceKm;
    final remMin = totalKm > 0
        ? (nav.route.durationMin * (remKm / totalKm)).clamp(0, 100000)
        : nav.route.durationMin;
    final eta = DateTime.now().add(Duration(minutes: remMin.round()));
    final h = remMin.round() ~/ 60;
    final m = remMin.round() % 60;
    final dur = h > 0 ? '${h}h ${m}min' : '${m}min';
    final clock =
        '${eta.hour.toString().padLeft(2, '0')}:${eta.minute.toString().padLeft(2, '0')}';
    return '$dur|${remKm.toStringAsFixed(remKm < 10 ? 1 : 0)} km · $clock';
  }

  String _alertLabel(RouteAlertType t) {
    switch (t) {
      case RouteAlertType.speedCamera:
        return AppStrings.literal('دوربین سرعت');
      case RouteAlertType.speedBump:
        return AppStrings.literal('سرعت‌گیر');
      case RouteAlertType.policeCheckpoint:
        return AppStrings.literal('ایست بازرسی');
      case RouteAlertType.trafficLight:
        return AppStrings.literal('چراغ راهنما');
    }
  }
}

double _distanceM(double lat1, double lng1, double lat2, double lng2) {
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

const _shadow = [Shadow(color: Colors.black87, blurRadius: 6)];

class _EdgeShade extends StatelessWidget {
  const _EdgeShade();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(.45),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withOpacity(.5),
            ],
            stops: const [0, .25, .7, 1],
          ),
        ),
      ),
    );
  }
}

class _ManeuverBanner extends StatelessWidget {
  const _ManeuverBanner(
      {required this.icon, required this.distance, required this.street});

  final IconData icon;
  final String distance;
  final String street;

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width * .55;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, color: Colors.white, size: 52, shadows: _shadow),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(distance,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        shadows: _shadow)),
                Text(street,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        shadows: _shadow)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedCluster extends StatelessWidget {
  const _SpeedCluster(
      {required this.limit, required this.speed, required this.over});

  final int? limit;
  final int speed;
  final bool over;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (limit != null)
          Container(
            width: 62,
            height: 62,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE53935), width: 6),
            ),
            child: Text('$limit',
                style: const TextStyle(
                    color: Colors.black,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: 8),
        Container(
          width: 62,
          height: 62,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: over ? const Color(0xFFE53935) : const Color(0xFF3A4350),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$speed',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      height: 1,
                      fontWeight: FontWeight.w800)),
              const Text('km/h',
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

class _TripInfo extends StatelessWidget {
  const _TripInfo({required this.text});

  final String text; // "<duration>|<distance · eta>"

  @override
  Widget build(BuildContext context) {
    final parts = text.split('|');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(parts.first,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                shadows: _shadow)),
        Text(parts.length > 1 ? parts[1] : '',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                shadows: _shadow)),
      ],
    );
  }
}

class _AlertChip extends StatelessWidget {
  const _AlertChip({required this.asset, required this.label, this.distance});

  final String asset;
  final String label;
  final String? distance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB300),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(asset, width: 32, height: 32, fit: BoxFit.contain),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          if (distance != null) ...[
            const SizedBox(width: 8),
            Text(distance!,
                style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 16)),
    );
  }
}
