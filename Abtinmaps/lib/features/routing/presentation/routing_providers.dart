import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:abtin_maps/core/geo/geo_types.dart';
import '../../../routing/routing_engine.dart' show RouteCancelToken;
import '../data/routing_service.dart';
import '../domain/road_block.dart';
import '../../../core/debug/abtin_debug.dart';

import '../../map/presentation/destination_provider.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../../settings/presentation/appearance_settings_providers.dart';

final routingServiceProvider = Provider<RoutingService>((ref) {
  final service = RoutingService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Roads the driver reported closed during the current trip. Every (re)route
/// of the trip avoids them; cleared when navigation ends.
final roadBlocksProvider = StateProvider<List<RoadBlock>>((ref) => const []);

enum NavigationState {
  idle,
  calculating,
  navigating,
  error,
}

class ActiveNavigation {
  final RouteInfo route;
  final NavigationState state;
  final int currentInstructionIndex;
  final double remainingDistanceKm;
  final double distanceToNextManeuverM;
  final String? errorMessage;

  const ActiveNavigation({
    required this.route,
    this.state = NavigationState.navigating,
    this.currentInstructionIndex = 0,
    required this.remainingDistanceKm,
    this.distanceToNextManeuverM = 0,
    this.errorMessage,
  });

  ActiveNavigation copyWith({
    RouteInfo? route,
    NavigationState? state,
    int? currentInstructionIndex,
    double? remainingDistanceKm,
    double? distanceToNextManeuverM,
    String? errorMessage,
  }) {
    return ActiveNavigation(
      route: route ?? this.route,
      state: state ?? this.state,
      currentInstructionIndex:
          currentInstructionIndex ?? this.currentInstructionIndex,
      remainingDistanceKm: remainingDistanceKm ?? this.remainingDistanceKm,
      distanceToNextManeuverM:
          distanceToNextManeuverM ?? this.distanceToNextManeuverM,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  static const _arrivedFallback = RouteInstruction(
    text: 'به مقصد رسیدید',
    distanceMeters: 0,
    location: LatLng(0, 0),
    type: 'arrive',
  );

  RouteInstruction get currentInstruction {
    if (route.instructions.isEmpty) return _arrivedFallback;
    if (currentInstructionIndex < route.instructions.length) {
      return route.instructions[currentInstructionIndex];
    }
    return route.instructions.last;
  }
}

class ActiveNavigationNotifier extends StateNotifier<ActiveNavigation?> {
  ActiveNavigationNotifier() : super(null);

  void setNavigation(ActiveNavigation nav) {
    state = nav;
  }

  void updateProgress(int instructionIndex, double remainingDistance,
      {double? distanceToNextManeuverM}) {
    if (state != null) {
      state = state!.copyWith(
        currentInstructionIndex: instructionIndex,
        remainingDistanceKm: remainingDistance,
        distanceToNextManeuverM: distanceToNextManeuverM,
      );
    }
  }

  void clear() {
    state = null;
  }
}

final activeNavigationProvider =
    StateNotifierProvider<ActiveNavigationNotifier, ActiveNavigation?>((ref) {
  return ActiveNavigationNotifier();
});

final drivingModeProvider = StateProvider<bool>((ref) => false);

/// Only the settings that change the route itself. Watching the whole
/// appearance state restarted the search on every cosmetic change.
typedef RoutePrefs = ({
  bool avoidUnpavedRoads,
  bool avoidTolls,
  bool avoidTraffic,
  bool avoidHighways,
  bool avoidFerries,
  RoutePlanningMode routePlanningMode,
});

final _routePrefsProvider = Provider<RoutePrefs>((ref) {
  return ref.watch(appearanceSettingsProvider.select((s) => (
        avoidUnpavedRoads: s.avoidUnpavedRoads,
        avoidTolls: s.avoidTolls,
        avoidTraffic: s.avoidTraffic,
        avoidHighways: s.avoidHighways,
        avoidFerries: s.avoidFerries,
        routePlanningMode: s.routePlanningMode,
      )));
});

final calculateRouteProvider =
    FutureProvider.autoDispose<RouteInfo?>((ref) async {
  ref.watch(routingEngineProvider);
  final preferences = ref.watch(_routePrefsProvider);
  final destination = ref.watch(selectedDestinationProvider);
  final stops = ref.watch(intermediateDestinationsProvider);
  final vehiclePosition = ref.read(vehiclePositionProvider).value;

  if (destination == null || vehiclePosition == null) {
    return null;
  }

  final routingService = ref.read(routingServiceProvider);

  final origin = LatLng(vehiclePosition.lat, vehiclePosition.lng);
  if (stops.isNotEmpty) {
    return routingService.calculateMultiStopRoute(
      origin: origin,
      stops: stops.map((s) => s.point).toList(),
      destination: destination.point,
    avoidUnpavedRoads: preferences.avoidUnpavedRoads,
    avoidTolls: preferences.avoidTolls,
        avoidTrafficZones: preferences.avoidTraffic,
        avoidHighways: preferences.avoidHighways,
        avoidFerries: preferences.avoidFerries,
        routeMode: routeModeIndex(preferences.routePlanningMode),
    );
  }
  return routingService.calculateRoute(
    origin: origin,
    destination: destination.point,
    avoidUnpavedRoads: preferences.avoidUnpavedRoads,
    avoidTolls: preferences.avoidTolls,
    avoidTrafficZones: preferences.avoidTraffic,
    avoidHighways: preferences.avoidHighways,
    avoidFerries: preferences.avoidFerries,
    routeMode: routeModeIndex(preferences.routePlanningMode),
  );
});

final selectedRouteCandidateIndexProvider = StateProvider<int>((ref) => 0);

final calculateRoutesProvider =
    StreamProvider.autoDispose<List<RouteInfo>>((ref) async* {
  ref.watch(routingEngineProvider);
  final preferences = ref.watch(_routePrefsProvider);
  final destination = ref.watch(selectedDestinationProvider);
  final stops = ref.watch(intermediateDestinationsProvider);
  ref.watch(vehiclePositionProvider.select((v) => v.hasValue));
  final vehiclePosition = ref.read(vehiclePositionProvider).value ??
      ref.read(navigationPositionProvider).value;
  AbtinDebug.log('ROUTES',
      'provider start dest=${destination?.point} origin=${vehiclePosition == null ? "null" : "${vehiclePosition.lat},${vehiclePosition.lng}"} stops=${stops.length}');
  ref.onDispose(() => AbtinDebug.log('ROUTES', 'provider disposed'));
  if (destination == null || vehiclePosition == null) {
    AbtinDebug.log('ROUTES', 'yield empty (dest or origin null)');
    yield const <RouteInfo>[];
    return;
  }
  if (stops.isNotEmpty) {
    final service = ref.read(routingServiceProvider);
    final route = await service.calculateMultiStopRoute(
      origin: LatLng(vehiclePosition.lat, vehiclePosition.lng),
      stops: stops.map((s) => s.point).toList(),
      destination: destination.point,
      avoidUnpavedRoads: preferences.avoidUnpavedRoads,
      avoidTolls: preferences.avoidTolls,
      avoidTrafficZones: preferences.avoidTraffic,
      avoidHighways: preferences.avoidHighways,
      avoidFerries: preferences.avoidFerries,
      routeMode: routeModeIndex(preferences.routePlanningMode),
    );
    AbtinDebug.log('ROUTES', 'multi-stop result=${route != null}');
    yield route == null ? const <RouteInfo>[] : <RouteInfo>[route];
    return;
  }
  // Kills the search isolate when this provider is rebuilt or disposed.
  final cancel = RouteCancelToken();
  ref.onDispose(cancel.cancel);
  RouteInfo? primary;
  await for (final routes in ref.read(routingServiceProvider).calculateRoutesStream(
        origin: LatLng(vehiclePosition.lat, vehiclePosition.lng),
        destination: destination.point,
        avoidUnpavedRoads: preferences.avoidUnpavedRoads,
        avoidTolls: preferences.avoidTolls,
        avoidTrafficZones: preferences.avoidTraffic,
        avoidHighways: preferences.avoidHighways,
        avoidFerries: preferences.avoidFerries,
        routeMode: routeModeIndex(preferences.routePlanningMode),
        cancel: cancel,
      )) {
    AbtinDebug.log('ROUTES',
        'stream emit count=${routes.length} cancelled=${cancel.isCancelled}');
    if (routes.isEmpty) {
      AbtinDebug.log('ROUTES',
          'empty result lastError=${ref.read(routingServiceProvider).lastError}');
      yield routes;
      continue;
    }
    primary ??= routes.first;
    final rest = routes.where((r) => !identical(r, primary)).toList();
    yield [primary, ...rankRouteCandidates(rest, preferences.routePlanningMode)];
  }
});

List<RouteInfo> rankRouteCandidates(
  List<RouteInfo> routes,
  RoutePlanningMode mode,
) {
  final ranked = List<RouteInfo>.from(routes);
  if (ranked.length < 2) return ranked;
  switch (mode) {
    case RoutePlanningMode.fastest:
      ranked.sort((a, b) => a.durationMin.compareTo(b.durationMin));
    case RoutePlanningMode.shortest:
      ranked.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    case RoutePlanningMode.economic:
      final minDistance = ranked
          .map((route) => route.distanceKm)
          .reduce((a, b) => a < b ? a : b);
      final minDuration = ranked
          .map(_economicEffectiveMinutes)
          .reduce((a, b) => a < b ? a : b);
      ranked.sort((a, b) {
        final scoreA = a.distanceKm / minDistance +
            _economicEffectiveMinutes(a) / minDuration;
        final scoreB = b.distanceKm / minDistance +
            _economicEffectiveMinutes(b) / minDuration;
        return scoreA.compareTo(scoreB);
      });
  }
  return ranked;
}

/// زمانِ مؤثر برای مسیر اقتصادی: چراغ قرمز و احتمال ترافیک «نمرهٔ منفی» می‌گیرند.
/// هر چراغ ≈ ۰٫۴ دقیقه (انتظار + توقف/شتاب‌گیری)؛ تراکم بالای چراغ (بیش از ۱٫۵ تا در
/// هر کیلومتر) نشانهٔ مسیر شهریِ پرتراکم است و جریمهٔ اضافه دارد.
double _economicEffectiveMinutes(RouteInfo r) {
  final lights =
      r.alerts.where((a) => a.type == RouteAlertType.trafficLight).length;
  final km = r.distanceKm < 0.1 ? 0.1 : r.distanceKm;
  final perKm = lights / km;
  final congestion = perKm > 1.5 ? (perKm - 1.5) * 0.3 * km : 0.0;
  return r.durationMin + lights * 0.4 + congestion;
}

int routeModeIndex(RoutePlanningMode mode) {
  switch (mode) {
    case RoutePlanningMode.fastest:
      return 0;
    case RoutePlanningMode.shortest:
      return 1;
    case RoutePlanningMode.economic:
      return 2;
  }
}
