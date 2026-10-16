import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abtin_maps/core/geo/geo_types.dart';
import '../../../core/localization/app_localizations.dart';

import '../../../shared/providers/abtinmap_providers.dart';
import '../../../shared/providers/app_settings_providers.dart';
import '../../gps/data/road_snapper.dart';
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

  /// Set by [_offlineProvidersFor] when no installed map can serve the trip.
  String? _coverageError;

  AbtinmapRoutingProvider _abmProviderFor(
    String mapName, [
    List<String> extraMapNames = const <String>[],
  ]) =>
      _abmProviders.putIfAbsent(
        extraMapNames.isEmpty ? mapName : '$mapName|${extraMapNames.join(',')}',
        () => AbtinmapRoutingProvider(
          mapService: _ref.read(abmMapServiceProvider),
          vectorMapService: _ref.read(vectorMapServiceProvider),
          mapName: mapName,
          extraMapNames: extraMapNames,
          languageCode: () => _ref.read(languageProvider),
          leftHandTraffic: () => RoadSnapper.instance.leftHandTraffic,
        ),
      );

  /// Chooses the offline map(s) for a trip.
  ///
  /// Province maps are built from the same OSM data (shared node/way ids) and each
  /// graph reaches `routing_overlap_degrees` beyond its province, so neighbouring
  /// maps are searched together as ONE graph. A short trip fully covered by a single
  /// map keeps the fast single-map path.
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
    _coverageError = null;
    const tol = 0.02;
    bool inBox(List<double> b, LatLng p) =>
        p.longitude >= b[0] - tol &&
        p.longitude <= b[2] + tol &&
        p.latitude >= b[1] - tol &&
        p.latitude <= b[3] + tol;
    final boxes = <_MapBox>[];
    final unknown = <OfflineMapSource>[];
    for (final source in sources) {
      final box = await offlineMapBbox(vector, source);
      if (box == null) {
        unknown.add(source);
        continue;
      }
      final rbox = await offlineMapRoutingBbox(vector, source) ?? box;
      boxes.add(_MapBox(source, box, rbox));
    }
    // Maps without bbox metadata cannot be reasoned about: keep the old behaviour.
    if (boxes.isEmpty) {
      return <AbtinmapRoutingProvider>[
        for (final source in unknown) _abmProviderFor(source.fileName),
      ];
    }
    final coverO = <_MapBox>[
      for (final b in boxes)
        if (inBox(b.routeBox, origin)) b,
    ];
    final coverD = <_MapBox>[
      for (final b in boxes)
        if (inBox(b.routeBox, destination)) b,
    ];
    if (coverO.isEmpty || coverD.isEmpty) {
      _coverageError = coverO.isEmpty && coverD.isEmpty
          ? 'مبدأ و مقصد هیچ‌کدام داخل نقشه‌های آفلاین نصب‌شده نیستند.'
          : coverD.isEmpty
              ? 'مقصد داخل نقشه‌های آفلاین نصب‌شده نیست. نقشه‌ی منطقه‌ی مقصد را دانلود کنید.'
              : 'مبدأ داخل نقشه‌های آفلاین نصب‌شده نیست. نقشه‌ی منطقه‌ی مبدأ را دانلود کنید.';
      return const <AbtinmapRoutingProvider>[];
    }
    final spanDeg = math.max(
      (origin.latitude - destination.latitude).abs(),
      (origin.longitude - destination.longitude).abs(),
    );
    // Prefer the map whose province really contains the origin.
    _MapBox pickPrimary(List<_MapBox> from) => from.firstWhere(
          (b) => inBox(b.box, origin),
          orElse: () => from.first,
        );
    final single = <_MapBox>[
      for (final b in coverO)
        if (inBox(b.routeBox, destination)) b,
    ];
    if (single.isNotEmpty && spanDeg < 1.0) {
      return <AbtinmapRoutingProvider>[
        _abmProviderFor(pickPrimary(single).source.fileName),
      ];
    }

    // Joint search: every installed map whose graph touches a window around the trip.
    final margin = math.min(1.5, math.max(0.35, spanDeg * 0.2));
    final wMinLon = math.min(origin.longitude, destination.longitude) - margin;
    final wMaxLon = math.max(origin.longitude, destination.longitude) + margin;
    final wMinLat = math.min(origin.latitude, destination.latitude) - margin;
    final wMaxLat = math.max(origin.latitude, destination.latitude) + margin;
    final window = <_MapBox>[
      for (final b in boxes)
        if (!(b.routeBox[2] < wMinLon ||
            b.routeBox[0] > wMaxLon ||
            b.routeBox[3] < wMinLat ||
            b.routeBox[1] > wMaxLat))
          b,
    ];
    // Distance (degrees) from a map's centre to the straight line origin->destination.
    double chordDistance(_MapBox b) {
      final ax = origin.longitude, ay = origin.latitude;
      final bx = destination.longitude, by = destination.latitude;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0
          ? 0.0
          : ((b.centerLon - ax) * dx + (b.centerLat - ay) * dy) / len2;
      t = t.clamp(0.0, 1.0).toDouble();
      final px = ax + dx * t, py = ay + dy * t;
      final ex = b.centerLon - px, ey = b.centerLat - py;
      return math.sqrt(ex * ex + ey * ey);
    }

    window.sort((a, b) => chordDistance(a).compareTo(chordDistance(b)));
    final chosen = window.take(14).toList();
    for (final b in <_MapBox>[...coverO, ...coverD]) {
      if (!chosen.contains(b)) chosen.add(b);
    }
    // Fail fast when the chosen maps are not connected (a province map in between
    // is missing): searching would only run until the time budget expires.
    bool overlaps(_MapBox a, _MapBox b) =>
        !(a.routeBox[2] < b.routeBox[0] ||
            b.routeBox[2] < a.routeBox[0] ||
            a.routeBox[3] < b.routeBox[1] ||
            b.routeBox[3] < a.routeBox[1]);
    final reached = <_MapBox>{...coverO};
    final queue = <_MapBox>[...coverO];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final b in chosen) {
        if (reached.contains(b) || !overlaps(cur, b)) continue;
        reached.add(b);
        queue.add(b);
      }
    }
    if (!coverD.any(reached.contains)) {
      _coverageError =
          'بین مبدأ و مقصد نقشه‌ی یکی از استان‌های مسیر نصب نشده است. '
          'نقشه‌ی استان‌های میان‌راه را هم دانلود کنید.';
      return const <AbtinmapRoutingProvider>[];
    }
    final primary = pickPrimary(coverO);
    final extras = <String>[
      for (final b in chosen)
        if (b != primary && reached.contains(b)) b.source.fileName,
    ];
    return <AbtinmapRoutingProvider>[_abmProviderFor(primary.source.fileName, extras)];
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
    final providers = await _offlineProvidersFor(origin, destination);
    for (final provider in providers) {
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
        _coverageError ??
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
    final providers = await _offlineProvidersFor(origin, destination);
    for (final provider in providers) {
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
        offlineError ??
        _coverageError ??
        'برای مسیریابی، ابتدا یک نقشهٔ آفلاین ABM نصب کنید.';
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
    final providers = await _offlineProvidersFor(origin, destination);
    for (final provider in providers) {
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
        offlineError ??
        _coverageError ??
        'برای مسیریابی، ابتدا یک نقشهٔ آفلاین ABM نصب کنید.';
    yield const <RouteInfo>[];
  }

  void dispose() {
    _onlineProvider?.dispose();
  }
}

class _MapBox {
  const _MapBox(this.source, this.box, this.routeBox);
  final OfflineMapSource source;

  /// Published province bbox: minLon, minLat, maxLon, maxLat
  final List<double> box;

  /// Routing graph extent (province polygon + overlap buffer), same order.
  final List<double> routeBox;
  double get centerLat => (box[1] + box[3]) / 2;
  double get centerLon => (box[0] + box[2]) / 2;
}
