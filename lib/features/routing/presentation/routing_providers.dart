import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:abtin_maps/core/geo/geo_types.dart';
import '../data/routing_service.dart';

import '../../map/presentation/destination_provider.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../../settings/presentation/appearance_settings_providers.dart';

final routingServiceProvider = Provider<RoutingService>((ref) {
  final service = RoutingService(ref);
  ref.onDispose(service.dispose);
  return service;
});

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

final calculateRouteProvider =
    FutureProvider.autoDispose<RouteInfo?>((ref) async {
  ref.watch(routingEngineProvider);
  final preferences = ref.watch(appearanceSettingsProvider);
  final destination = ref.watch(selectedDestinationProvider);
  final vehiclePosition = ref.read(vehiclePositionProvider).value;

  if (destination == null || vehiclePosition == null) {
    return null;
  }

  final routingService = ref.read(routingServiceProvider);

  return await routingService.calculateRoute(
    origin: LatLng(vehiclePosition.lat, vehiclePosition.lng),
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
  final preferences = ref.watch(appearanceSettingsProvider);
  final destination = ref.watch(selectedDestinationProvider);
  final vehiclePosition = ref.read(vehiclePositionProvider).value;
  if (destination == null || vehiclePosition == null) {
    yield const <RouteInfo>[];
    return;
  }
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
      )) {
    if (routes.isEmpty) {
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
          .map((route) => route.durationMin)
          .reduce((a, b) => a < b ? a : b);
      ranked.sort((a, b) {
        final scoreA = a.distanceKm / minDistance + a.durationMin / minDuration;
        final scoreB = b.distanceKm / minDistance + b.durationMin / minDuration;
        return scoreA.compareTo(scoreB);
      });
  }
  return ranked;
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
