import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abtin_maps/core/geo/geo_types.dart';
import '../../../core/localization/app_localizations.dart';

import '../../../shared/providers/abtinmap_providers.dart';
import '../../../shared/providers/app_settings_providers.dart';
import 'abtinmap_routing_provider.dart';
import 'online_routing_provider.dart';
import 'routing_provider.dart';

class RouteInfo {
  const RouteInfo({
    required this.geometry,
    required this.distanceKm,
    required this.durationMin,
    required this.instructions,
    this.alerts = const [],
  });

  final List<LatLng> geometry;
  final double distanceKm;
  final double durationMin;
  final List<RouteInstruction> instructions;
  final List<RouteAlert> alerts;
}

enum RouteAlertType { speedCamera, speedBump, policeCheckpoint, trafficLight }

class RouteAlert {
  const RouteAlert({required this.type, required this.location, this.name});
  final RouteAlertType type;
  final LatLng location;
  final String? name;
}

class RouteInstruction {
  const RouteInstruction({
    required this.text,
    required this.distanceMeters,
    required this.location,
    required this.type,
    this.modifier,
    this.exit,
    this.roundaboutAngleDegrees,
    this.roundaboutExitCount,
    this.roundaboutBranchAngles = const [],
    this.roundaboutEntranceAngles = const [],
    this.roundaboutExitAngles = const [],
    this.roundaboutActiveExitAngle,
    this.drivingSide = 'right',
    this.speedLimit,
    this.maneuverEndLocation,
    this.maneuverAngleDegrees,
  });

  final String text;
  final double distanceMeters;
  final LatLng location;
  final String type;
  final String? modifier;
  final int? exit;
  final double? roundaboutAngleDegrees;

  final int? roundaboutExitCount;

  final List<double> roundaboutBranchAngles;
  final List<double> roundaboutEntranceAngles;
  final List<double> roundaboutExitAngles;
  final double? roundaboutActiveExitAngle;

  final String drivingSide;
  final int? speedLimit;

  final LatLng? maneuverEndLocation;

  final double? maneuverAngleDegrees;
}

class RoutingService {
  RoutingService(this._ref);

  final Ref _ref;
  OnlineRoutingProvider? _onlineProvider;
  String? lastError;

  RoutingEngine get engine => _ref.read(routingEngineProvider);

  final Map<String, AbtinmapRoutingProvider> _abmProviders =
      <String, AbtinmapRoutingProvider>{};

  AbtinmapRoutingProvider _abmProviderFor(String mapName) =>
      _abmProviders.putIfAbsent(
        mapName,
        () => AbtinmapRoutingProvider(
          mapService: _ref.read(abmMapServiceProvider),
          vectorMapService: _ref.read(vectorMapServiceProvider),
          mapName: mapName,
          languageCode: () => _ref.read(languageProvider),
        ),
      );

  Future<List<AbtinmapRoutingProvider>> _offlineProvidersFor(
    LatLng origin,
    LatLng destination,
  ) async {
    final sources = await _ref.read(installedOfflineMapSourcesProvider.future);
    if (sources.isEmpty) {
      final activeMap = _ref.read(abmActiveMapNameProvider).trim();
      return <AbtinmapRoutingProvider>[_abmProviderFor(activeMap)];
    }
    final vector = _ref.read(vectorMapServiceProvider);
    final scored = <MapEntry<int, OfflineMapSource>>[];
    for (final source in sources) {
      final box = await offlineMapBbox(vector, source);
      final hasO = bboxContains(box, origin.latitude, origin.longitude);
      final hasD = bboxContains(box, destination.latitude, destination.longitude);
      final score = (hasO && hasD) ? 0 : hasO ? 1 : hasD ? 2 : 3;
      scored.add(MapEntry(score, source));
    }
    scored.sort((x, y) => x.key.compareTo(y.key));
    // A route can only exist inside one offline map. When some installed map covers both
    // endpoints, trying the others only wastes time (each failed attempt can run for a long
    // time), so keep just the maps that contain both points.
    if (scored.isNotEmpty && scored.first.key == 0) {
      scored.removeWhere((e) => e.key != 0);
    }
    return <AbtinmapRoutingProvider>[
      for (final e in scored) _abmProviderFor(e.value.fileName),
    ];
  }

  OnlineRoutingProvider get onlineProvider =>
      _onlineProvider ??= OnlineRoutingProvider(
        languageCode: () => _ref.read(languageProvider),
      );

  static List<String> _osrmExclude(bool tolls, bool highways, bool ferries) =>
      [if (tolls) 'toll', if (highways) 'motorway', if (ferries) 'ferry'];

  Future<RouteInfo?> calculateRoute({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    bool avoidFerries = false,
    int routeMode = 0,
  }) async {
    lastError = null;
    if (!offlineOnly && engine == RoutingEngine.online) {
      final route = await onlineProvider.calculateRoute(
        origin: origin,
        destination: destination,
        exclude: _osrmExclude(avoidTolls, avoidHighways, avoidFerries),
      );
      if (route != null) return route;
      lastError = onlineProvider.lastError ??
          AppStrings.getForLanguage(
              _ref.read(languageProvider), 'route_error_online_failed_generic');
      return null;
    }

    String? offlineError;
    for (final provider in await _offlineProvidersFor(origin, destination)) {
      final route = await provider.calculateRoute(
        origin: origin,
        destination: destination,
        offlineOnly: true,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
      );
      if (route != null) return route;
      offlineError ??= provider.lastError;
    }
    lastError = offlineError ??
        AppStrings.getForLanguage(
            _ref.read(languageProvider), 'route_error_offline_map_missing');
    return null;
  }

  Future<List<RouteInfo>> calculateRoutes({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    bool avoidFerries = false,
    int routeMode = 0,
  }) async {
    lastError = null;
    if (!offlineOnly && engine == RoutingEngine.online) {
      final routes = await onlineProvider.calculateRoutes(
        origin: origin,
        destination: destination,
        exclude: _osrmExclude(avoidTolls, avoidHighways, avoidFerries),
      );
      if (routes.isEmpty) {
        lastError = onlineProvider.lastError ??
            AppStrings.getForLanguage(_ref.read(languageProvider),
                'route_error_online_failed_generic');
      }
      return routes;
    }

    String? offlineError;
    for (final provider in await _offlineProvidersFor(origin, destination)) {
      final routes = await provider.calculateRoutes(
        origin: origin,
        destination: destination,
        offlineOnly: true,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
      );
      if (routes.isNotEmpty) return routes;
      offlineError ??= provider.lastError;
    }
    lastError =
        offlineError ?? 'برای مسیریابی، ابتدا یک نقشهٔ آفلاین ABM نصب کنید.';
    return const <RouteInfo>[];
  }

  Stream<List<RouteInfo>> calculateRoutesStream({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    bool avoidFerries = false,
    int routeMode = 0,
  }) async* {
    if (!offlineOnly && engine == RoutingEngine.online) {
      final routes = await calculateRoutes(
        origin: origin,
        destination: destination,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        avoidFerries: avoidFerries,
        routeMode: routeMode,
      );
      yield routes;
      return;
    }
    lastError = null;
    String? offlineError;
    for (final provider in await _offlineProvidersFor(origin, destination)) {
      var any = false;
      await for (final routes in provider.calculateRoutesStream(
        origin: origin,
        destination: destination,
        offlineOnly: true,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
      )) {
        if (routes.isEmpty) continue;
        any = true;
        yield routes;
      }
      if (any) return;
      offlineError ??= provider.lastError;
    }
    lastError =
        offlineError ?? 'برای مسیریابی، ابتدا یک نقشهٔ آفلاین ABM نصب کنید.';
    yield const <RouteInfo>[];
  }

  void dispose() {
    _onlineProvider?.dispose();
  }
}
