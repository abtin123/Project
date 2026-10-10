import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;


import '../../../abtinmap/abm_models.dart';
import '../../../abtinmap/abm_road_hazards.dart';
import '../../../abtinmap/abm_saved_places.dart';
import '../../routing/data/routing_service.dart' show RouteAlert;
import '../../../core/geo/geo_types.dart';
import '../../../shared/providers/abtinmap_providers.dart'
    show OfflineMapSource, offlineMapBbox, bboxIntersects;
import '../../../shared/providers/map_style_providers.dart';
import '../../../world/world_countries.dart';
import '../../offline_maps/data/vector_map_service.dart';
import '../../gps/data/location_service.dart';
import '../../gps/data/road_snapper.dart';
import '../../vehicle/presentation/nav_arrow_painter.dart';
import '../../vehicle/presentation/car_marker.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

double mapRelativeHeading(double headingDeg, double mapBearingDeg) {
  final heading = headingDeg.isFinite ? headingDeg : 0.0;
  final bearing = mapBearingDeg.isFinite ? mapBearingDeg : 0.0;
  return (heading - bearing) % 360.0;
}

const Map<int, List<String>> _offlinePoiClassesByKlass = {
  AbmKlass.poiFuel: [
    'fuel',
    'gas_station',
    'petrol_station',
    'fuel_station',
    'cng',
    'charging_station',
  ],
  AbmKlass.poiParking: ['parking', 'bicycle_parking', 'parking_space'],
  AbmKlass.poiHospital: ['hospital', 'clinic', 'doctors', 'dentist'],
  AbmKlass.poiPharmacy: ['pharmacy', 'chemist'],
  AbmKlass.poiPolice: ['police', 'police_station'],
  AbmKlass.poiSchool: ['school', 'college', 'university', 'kindergarten'],
  AbmKlass.poiRestaurant: ['restaurant', 'fast_food', 'food_court'],
  AbmKlass.poiCafe: ['cafe', 'ice_cream'],
  AbmKlass.poiBank: ['bank', 'atm', 'bureau_de_change', 'money_transfer'],
  AbmKlass.poiHotel: ['hotel', 'motel', 'hostel', 'guest_house', 'apartment'],
  AbmKlass.poiSupermarket: [
    'supermarket',
    'convenience',
    'department_store',
    'mall',
    'greengrocer',
    'marketplace',
    'shop_fuel',
    'car_repair',
    'car_wash',
  ],
  AbmKlass.poiMosque: [
    'place_of_worship',
    'mosque',
    'shrine',
    'temple',
    'church',
    'synagogue',
  ],
  AbmKlass.poiToilets: ['toilets'],
  AbmKlass.poiBusStation: ['bus_station', 'bus_stop'],
  AbmKlass.poiAirport: ['aerodrome', 'airport'],
  AbmKlass.poiAttraction: [
    'attraction',
    'museum',
    'viewpoint',
    'zoo',
    'theme_park',
    'monument',
    'memorial',
    'castle',
    'archaeological_site',
  ],
  AbmKlass.poiPark: ['park', 'garden', 'nature_reserve'],
  AbmKlass.poiPitch: ['pitch', 'sports_centre', 'stadium'],
  AbmKlass.poiPlace: [
    'city',
    'town',
    'village',
    'suburb',
    'neighbourhood',
    'quarter',
    'hamlet',
    'locality',
  ],
  AbmKlass.poiSpeedCamera: <String>[],
  AbmKlass.poiSpeedBump: <String>[],
  AbmKlass.poiTrafficLight: ['traffic_signals'],
};

List<dynamic> offlinePoiLayerFilter(Set<int>? visibleKlasses, {bool requireName = true}) {
  const hidden = <dynamic>['==', ['get', 'class'], '__abtin-hidden-poi__'];
  if (visibleKlasses != null && visibleKlasses.isEmpty) return hidden;
  final base = <dynamic>[
    'all',
    ['==', ['geometry-type'], 'Point'],
    if (requireName) ['has', 'name'],
  ];
  if (visibleKlasses == null) return base;
  final classes = <String>{
    for (final klass in visibleKlasses) ...?_offlinePoiClassesByKlass[klass],
  }.toList(growable: false);
  if (classes.isEmpty) return hidden;
  return <dynamic>[
    ...base,
    ['match', ['get', 'class'], classes, true, false],
  ];
}

bool sameOfflinePoiVisibility(Set<int>? a, Set<int>? b) {
  if (a == null || b == null) return a == null && b == null;
  return a.length == b.length && a.containsAll(b);
}


List<dynamic> onlinePoiLayerFilter(
  Set<int>? visibleKlasses, {
  required String layerId,
}) {
  final enabled = visibleKlasses ?? _offlinePoiClassesByKlass.keys.toSet();
  final classes = <String>{
    for (final klass in enabled) ...?_offlinePoiClassesByKlass[klass],
  }.toList(growable: false);

  if (layerId == 'poi_transit') {
    final transitClasses = classes.where((value) =>
        value == 'airport' || value == 'bus' || value == 'rail').toList(growable: false);
    if (transitClasses.isEmpty) {
      return const <dynamic>['==', ['get', 'class'], '__abtin-hidden-poi__'];
    }
    return <dynamic>['all',
      ['match', ['geometry-type'], ['MultiPoint', 'Point'], true, false],
      ['match', ['get', 'class'], transitClasses, true, false],
    ];
  }

  final rankFilter = switch (layerId) {
    'poi_r1' => <dynamic>['all',
      ['>=', ['get', 'rank'], 1],
      ['<', ['get', 'rank'], 7],
    ],
    'poi_r7' => <dynamic>['all',
      ['>=', ['get', 'rank'], 7],
      ['<', ['get', 'rank'], 20],
    ],
    _ => <dynamic>['>=', ['get', 'rank'], 20],
  };

  return <dynamic>[
    'all',
    ['match', ['geometry-type'], ['MultiPoint', 'Point'], true, false],
    rankFilter,
    if (classes.isEmpty)
      const <dynamic>['==', ['get', 'class'], '__abtin-hidden-poi__']
    else
      <dynamic>['match', ['get', 'class'], classes, true, false],
  ];
}

Offset mapScreenPointToFlutterOffset(
  math.Point<dynamic> screenPoint,
  double devicePixelRatio,
) {
  final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  return Offset(
    screenPoint.x.toDouble() / ratio,
    screenPoint.y.toDouble() / ratio,
  );
}

enum OnlineRouteKind { route, alternative, traveled }

const Color kRouteTraveledColor = Color(0xFF9AA3AF);

class OnlineRouteOverlay {
  const OnlineRouteOverlay({
    required this.geometry,
    required this.color,
    required this.width,
    this.kind = OnlineRouteKind.route,
  });

  final List<LatLng> geometry;
  final Color color;
  final double width;
  final OnlineRouteKind kind;
}

class OnlineMapView extends StatefulWidget {
  const OnlineMapView({
    super.key,
    required this.vehiclePosition,
    required this.showCarModel,
    required this.modelIndex,
    required this.isDark,
    required this.followVehicle,
    required this.drivingMode,
    required this.markerColor,
    required this.pinSizePercent,
    required this.carSizePercent,
    required this.pinShadowEnabled,
    required this.cameraTiltDegrees,
    required this.carCameraAngleDegrees,
    required this.locationFocusRequest,
    required this.palette,
    required this.visiblePoiKlasses,
    this.localStylePath,
    this.abmFile,
    this.abmCountry,
    this.abmSources,
    this.routeGeometry,
    this.routeOverlays,
    this.trafficLights = const <LatLng>[],
    this.roadAlerts = const <RouteAlert>[],
    this.savedPlaces = const <AbmSavedPlace>[],
    this.routeProgressMeters,
    this.routeColor = const Color(0xFF2FE6C4),
    this.routeWidth = 7.0,
    this.routeLineStyle = 'solid',
    this.routeGlowIntensity = 0.8,
    this.destination,
    this.onLongPress,
    this.onMapTap,
    this.onPoiTap,
    this.onRouteTap,
    this.onUserGestureStart,
    this.onCameraIdle,
    this.onCameraPositionChanged,
    this.onStyleLoaded,
  });

  final VehiclePosition? vehiclePosition;

  final bool showCarModel;
  final int modelIndex;
  final bool isDark;
  final bool followVehicle;
  final bool drivingMode;
  final Color markerColor;
  final double pinSizePercent;
  final double carSizePercent;
  final bool pinShadowEnabled;
  final double cameraTiltDegrees;

  final double carCameraAngleDegrees;
  final int locationFocusRequest;
  final OfflineMapPalette palette;

  final Set<int>? visiblePoiKlasses;

  final String? localStylePath;

  final File? abmFile;

  final String? abmCountry;

  final List<OfflineMapSource>? abmSources;
  final List<LatLng>? routeGeometry;
  final List<OnlineRouteOverlay>? routeOverlays;

  final List<LatLng> trafficLights;

  final List<RouteAlert> roadAlerts;

  final List<AbmSavedPlace> savedPlaces;
  final double? routeProgressMeters;
  final Color routeColor;
  final double routeWidth;

  final String routeLineStyle;

  final double routeGlowIntensity;
  final LatLng? destination;
  final ValueChanged<LatLng>? onLongPress;
  final void Function(LatLng, Map<String, dynamic>)? onMapTap;
  final ValueChanged<Map<String, dynamic>>? onPoiTap;
  final ValueChanged<int>? onRouteTap;
  final VoidCallback? onUserGestureStart;
  final VoidCallback? onCameraIdle;
  final ValueChanged<ml.CameraPosition>? onCameraPositionChanged;
  final VoidCallback? onStyleLoaded;

  @override
  State<OnlineMapView> createState() => _OnlineMapViewState();
}

class _OnlineMapViewState extends State<OnlineMapView> {
  Duration _cameraUpdateInterval = const Duration(milliseconds: 66);
  static const _fallbackInitialTarget = ml.LatLng(0.0, 0.0);

  Timer? _roadSnapTimer;
  bool _roadQueryRunning = false;
  LatLng? _lastRoadQueryPos;
  DateTime _lastRoadQueryAt = DateTime.fromMillisecondsSinceEpoch(0);
  List<String>? _roadQueryLayerIds;
  static const List<String> _roadLayerCandidates = [
    'abm-road-line',
    'abm-road-line-t1',
    'abm-road-line-t2',
    'abm-road-line-t3',
    'abm-road-line-t4',
    'abm-bridge-line',
    'abm-bridge-line-t1',
    'abm-bridge-line-t2',
    'abm-bridge-line-t3',
    'abm-bridge-line-t4',
    'abm-tunnel-line',
    'abm-tunnel-line-t1',
    'abm-tunnel-line-t2',
    'abm-tunnel-line-t3',
    'abm-tunnel-line-t4',
    'road_motorway',
    'road_motorway_link',
    'road_trunk_primary',
    'road_secondary_tertiary',
    'road_minor',
    'road_link',
    'road_service_track',
    'bridge_motorway',
    'bridge_motorway_link',
    'bridge_trunk_primary',
    'bridge_secondary_tertiary',
    'bridge_street',
    'bridge_link',
    'bridge_service_track',
  ];

  ml.MapLibreMapController? _controller;
  ml.CameraPosition? _camera;
  Offset? _vehicleScreen;
  Offset? _destinationScreen;
  bool _styleReady = false;
  bool _screenUpdateRunning = false;
  bool _screenUpdateQueued = false;
  int _screenUpdateGeneration = 0;
  bool _cameraMoveRunning = false;
  int _cameraDrainGen = 0;
  DateTime _cameraDrainStartedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _resetCameraDrain([String reason = '']) {
    _cameraDrainGen++;
    _cameraMoveRunning = false;
    _pendingCameraPosition = null;
    _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  }
  ml.CameraPosition? _pendingCameraPosition;
  DateTime _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastCameraBearingAt;
  double? _smoothedCameraBearing;
  int _routeRefreshGeneration = 0;
  int _pendingLocationFocusRequest = 0;

  List<LatLng>? _navRouteGeometry;
  List<double>? _navRouteCumulativeM;
  int? _navRouteLastSegment;

  Timer? _abmRefreshTimer;
  bool _worldLayerLoaded = false;
  bool _abmRefreshRunning = false;
  bool _abmRefreshQueued = false;
  int _abmRefreshGeneration = 0;
  final VectorMapService _vectorMapService = VectorMapService();

  List<RoadHazard> _viewportHazards = const <RoadHazard>[];
  List<RoadHazard> _liveHazards = const <RoadHazard>[];
  Object? _liveHazardsSrc;
  bool _hazardPushRunning = false;
  bool _hazardPushQueued = false;
  String? _hazardDataSignature;
  Object? _savedPlacesSrc;
  bool _savedPlacesPushRunning = false;
  AbmBBox? _loadedAbmCoreBounds;
  double _loadedAbmZoom = 0;

  bool _cameraStillCovered() {
    final core = _loadedAbmCoreBounds;
    final cam = _camera;
    if (core == null || cam == null) return false;
    if ((cam.zoom - _loadedAbmZoom).abs() >= 0.5) return false;
    final t = cam.target;
    return t.longitude >= core.minLon &&
        t.longitude <= core.maxLon &&
        t.latitude >= core.minLat &&
        t.latitude <= core.maxLat;
  }


  static const double _minMapZoom = 2.0;
  static const double _maxMapZoom = 18.0;

  ml.LatLng _toMapLibrePoint(LatLng point) =>
      ml.LatLng(point.latitude, point.longitude);

  ml.LatLng _toMapLibreVehiclePoint(VehiclePosition point) =>
      ml.LatLng(point.lat, point.lng);

  List<OnlineRouteOverlay> get _routeOverlays =>
      widget.routeOverlays ?? _buildActiveRouteOverlays();

  List<OnlineRouteOverlay> _buildActiveRouteOverlays() {
    final geometry = widget.routeGeometry;
    if (geometry == null || geometry.length < 2) {
      return const <OnlineRouteOverlay>[];
    }
    final progress = widget.routeProgressMeters;
    if (progress == null || !progress.isFinite || progress <= 0) {
      return <OnlineRouteOverlay>[
        OnlineRouteOverlay(
          geometry: geometry,
          color: widget.routeColor,
          width: widget.routeWidth,
        ),
      ];
    }
    if (progress >= _polylineLengthMeters(geometry)) {
      return <OnlineRouteOverlay>[
        OnlineRouteOverlay(
          geometry: geometry,
          color: kRouteTraveledColor,
          width: widget.routeWidth,
          kind: OnlineRouteKind.traveled,
        ),
      ];
    }

    final traveled = <LatLng>[];
    final remaining = <LatLng>[];
    var accumulated = 0.0;
    var splitDone = false;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final segment = _polylineSegmentMeters(a, b);
      if (!splitDone && accumulated + segment >= progress && segment > 0.01) {
        final t = ((progress - accumulated) / segment).clamp(0.0, 1.0);
        final split = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        if (traveled.isEmpty) traveled.add(a);
        traveled.add(split);
        remaining.add(split);
        remaining.add(b);
        splitDone = true;
      } else if (!splitDone) {
        if (traveled.isEmpty) traveled.add(a);
        traveled.add(b);
      } else {
        remaining.add(b);
      }
      accumulated += segment;
    }

    final overlays = <OnlineRouteOverlay>[];
    if (traveled.length >= 2) {
      overlays.add(OnlineRouteOverlay(
        geometry: traveled,
        color: kRouteTraveledColor,
        width: widget.routeWidth,
        kind: OnlineRouteKind.traveled,
      ));
    }
    if (remaining.length >= 2) {
      overlays.add(OnlineRouteOverlay(
        geometry: remaining,
        color: widget.routeColor,
        width: widget.routeWidth,
      ));
    }
    return overlays;
  }

  double _polylineSegmentMeters(LatLng a, LatLng b) {
    final latRad = ((a.latitude + b.latitude) / 2) * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final dx = (b.longitude - a.longitude) * mx;
    final dy = (b.latitude - a.latitude) * my;
    return math.sqrt(dx * dx + dy * dy);
  }

  double _polylineLengthMeters(List<LatLng> geometry) {
    var total = 0.0;
    for (var i = 1; i < geometry.length; i++) {
      total += _polylineSegmentMeters(geometry[i - 1], geometry[i]);
    }
    return total;
  }

  @override
  void initState() {
    super.initState();
    _pendingLocationFocusRequest = widget.locationFocusRequest;
    if (widget.abmFile != null) {
      unawaited(_prewarmAbmCache(widget.abmFile!, widget.abmCountry));
    }
  }

  Future<void> _prewarmAbmCache(File file, String? country) async {
    try {
      if (!await file.exists()) return;
      final id = country?.isNotEmpty == true
          ? country!
          : p.basenameWithoutExtension(file.path);
      final sw = Stopwatch()..start();
      await _vectorMapService.prepare(containerFile: file, id: id);
      sw.stop();
    } catch (e, st) {
    }
  }

  @override
  void dispose() {
    _roadSnapTimer?.cancel();
    _abmRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OnlineMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousPosition = oldWidget.vehiclePosition;
    final nextPosition = widget.vehiclePosition;
    final oldSig = (oldWidget.abmSources ?? const <OfflineMapSource>[])
        .map((e) => e.file.path)
        .join('|');
    final newSig = (widget.abmSources ?? const <OfflineMapSource>[])
        .map((e) => e.file.path)
        .join('|');
    if (oldWidget.abmFile?.path != widget.abmFile?.path || oldSig != newSig) {
      _loadedAbmCoreBounds = null;
      _scheduleAbmRefresh(immediate: true);
    }
    final positionChanged = previousPosition?.lat != nextPosition?.lat ||
        previousPosition?.lng != nextPosition?.lng ||
        previousPosition?.headingDeg != nextPosition?.headingDeg ||
        previousPosition?.speedKmh != nextPosition?.speedKmh;
    final tiltChanged = oldWidget.cameraTiltDegrees != widget.cameraTiltDegrees;
    final poiVisibilityChanged = !sameOfflinePoiVisibility(
      oldWidget.visiblePoiKlasses,
      widget.visiblePoiKlasses,
    );
    final routeProgressChanged =
        (oldWidget.routeProgressMeters == null) != (widget.routeProgressMeters == null) ||
        (oldWidget.routeProgressMeters != null &&
            widget.routeProgressMeters != null &&
            (oldWidget.routeProgressMeters! - widget.routeProgressMeters!).abs() >= 4.0);
    final routesChanged =
        !_sameRouteOverlays(oldWidget.routeOverlays, widget.routeOverlays) ||
        oldWidget.routeGeometry != widget.routeGeometry ||
        oldWidget.routeColor != widget.routeColor ||
        oldWidget.routeWidth != widget.routeWidth ||
        oldWidget.routeLineStyle != widget.routeLineStyle ||
        oldWidget.routeGlowIntensity != widget.routeGlowIntensity ||
        routeProgressChanged;

    if (oldWidget.locationFocusRequest != widget.locationFocusRequest) {
      _pendingLocationFocusRequest = widget.locationFocusRequest;
      _focusGpsCamera();
    }
    if (oldWidget.followVehicle != widget.followVehicle ||
        oldWidget.drivingMode != widget.drivingMode ||
        (oldWidget.routeGeometry != null && widget.routeGeometry == null)) {
      _resetCameraDrain('follow/driving/route-cleared');
    }
    if (oldWidget.destination != widget.destination &&
        widget.destination != null) {
      _focusDestination(widget.destination!);
    }
    if (widget.followVehicle &&
        nextPosition != null &&
        (positionChanged ||
            tiltChanged ||
            oldWidget.followVehicle != widget.followVehicle ||
            oldWidget.drivingMode != widget.drivingMode)) {
      _syncCamera(force: tiltChanged);
    } else if (tiltChanged && !widget.followVehicle) {
      final controller = _controller;
      if (controller != null) {
        unawaited(
          controller.animateCamera(
            ml.CameraUpdate.tiltTo(widget.cameraTiltDegrees.clamp(0, 60)),
            duration: const Duration(milliseconds: 220),
          ),
        );
      }
    }
    if (_styleReady && poiVisibilityChanged) {
      unawaited(_applyPoiVisibility());
      unawaited(_applyRoadHazardVisibility());
    }
    if (_styleReady && !identical(oldWidget.roadAlerts, widget.roadAlerts)) {
      unawaited(_pushRoadHazards());
    }
    if (_styleReady && !identical(oldWidget.savedPlaces, widget.savedPlaces)) {
      unawaited(_pushSavedPlaces());
    }
    if (_styleReady && routesChanged) {
      unawaited(_refreshRouteAnnotations());
    }
    if (_styleReady &&
        !_sameLatLngList(oldWidget.trafficLights, widget.trafficLights)) {
      unawaited(_refreshTrafficLights());
    }
    if (_styleReady) _fitCandidateRoutes();
    if (positionChanged || oldWidget.destination != widget.destination) {
      if (positionChanged && widget.abmFile != null && nextPosition != null) {
        if (_needsAbmReload(nextPosition.lat, nextPosition.lng)) {
          _scheduleAbmRefresh(immediate: true);
        }
      }
      unawaited(_refreshScreenPositions());
    }
  }

  ml.CameraPosition _computeInitialCameraPosition() {
    return ml.CameraPosition(
      target: widget.vehiclePosition == null
          ? _fallbackInitialTarget
          : _toMapLibreVehiclePoint(widget.vehiclePosition!),
      zoom: widget.vehiclePosition == null
          ? 1.0
          : _followZoom,
      bearing: widget.vehiclePosition?.headingDeg ?? 0,
      tilt: widget.drivingMode
          ? widget.cameraTiltDegrees.clamp(0.0, 60.0).toDouble()
          : widget.cameraTiltDegrees.clamp(0.0, 60.0).toDouble(),
    );
  }

  void _onMapCreated(ml.MapLibreMapController controller) {
    _controller = controller;
    unawaited(_initializeMapCamera(controller));
  }

  Future<void> _initializeMapCamera(ml.MapLibreMapController controller) async {
    if (!mounted || controller != _controller) return;
    final gps = widget.vehiclePosition;
    _camera = _computeInitialCameraPosition();
    try {
      if (gps != null) {
        final zoom = _navigationZoom(gps.speedKmh);
        final target = widget.drivingMode
            ? _navigationCameraTarget(gps, zoom, gps.headingDeg)
            : _toMapLibreVehiclePoint(gps);
        final position = ml.CameraPosition(
          target: target,
          zoom: zoom,
          bearing: widget.drivingMode ? gps.headingDeg : 0,
          tilt: widget.drivingMode
              ? widget.cameraTiltDegrees.clamp(0.0, 60.0).toDouble()
              : 0,
        );
        _camera = position;
        await controller.moveCamera(ml.CameraUpdate.newCameraPosition(position));
      } else if (widget.abmFile != null) {
        await _centerOnOfflineMapBounds(controller);
      }
    } catch (e, st) {
      
    }
    if (!mounted || controller != _controller) return;
    if (_styleReady && widget.abmFile != null) {
      _scheduleAbmRefresh(immediate: true);
    }
    _focusGpsCamera();
  }

  Future<void> _centerOnOfflineMapBounds(ml.MapLibreMapController controller) async {
    try {
      final file = widget.abmFile;
      if (file == null || !await file.exists()) return;
      if (widget.vehiclePosition != null) {
        _focusGpsCamera();
        return;
      }
      final id = widget.abmCountry?.isNotEmpty == true
          ? widget.abmCountry!
          : p.basenameWithoutExtension(file.path);
      final artifacts = await _vectorMapService.prepare(
        containerFile: file,
        id: id,
      );
      final raw = artifacts.metadata['bbox'];
      if (raw is List && raw.length >= 4) {
        final minLon = (raw[0] as num).toDouble();
        final minLat = (raw[1] as num).toDouble();
        final maxLon = (raw[2] as num).toDouble();
        final maxLat = (raw[3] as num).toDouble();
        await controller.moveCamera(ml.CameraUpdate.newLatLngBounds(
          ml.LatLngBounds(
            southwest: ml.LatLng(minLat, minLon),
            northeast: ml.LatLng(maxLat, maxLon),
          ),
          left: 32, right: 32, top: 32, bottom: 32,
        ));
        _camera = ml.CameraPosition(
          target: ml.LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2),
          zoom: 6, bearing: 0, tilt: 0,
        );
      }
    } catch (e, st) {
    }
  }

  Future<void> _applyRoadHazardVisibility() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final visible = RoadHazards.visibleKinds(widget.visiblePoiKlasses);
    for (final spec in RoadHazards.specs) {
      try {
        await c.setLayerVisibility(
            '${RoadHazards.layerPrefix}${spec.id}', visible.contains(spec.id));
      } catch (_) {
      }
    }
  }

  Future<void> _pushRoadHazards() async {
    if (_hazardPushRunning) {
      _hazardPushQueued = true;
      return;
    }
    _hazardPushRunning = true;
    try {
      do {
        _hazardPushQueued = false;
        final controller = _controller;
        if (controller == null || !_styleReady || !mounted) return;
        if (!identical(_liveHazardsSrc, widget.roadAlerts)) {
          _liveHazardsSrc = widget.roadAlerts;
          _liveHazards = <RoadHazard>[
            for (final alert in widget.roadAlerts)
              ...?_asList(RoadHazard.fromAlert(alert)),
          ];
        }
        final all = <RoadHazard>[..._viewportHazards, ..._liveHazards];
        final signature = _roadHazardSignature(all);
        if (signature == _hazardDataSignature) continue;
        final collection = all.length > 1500
            ? await Isolate.run(() => RoadHazards.compose(all))
            : RoadHazards.compose(all);
        if (!mounted || controller != _controller) return;
        await controller.setGeoJsonSource(RoadHazards.sourceId, collection);
        _hazardDataSignature = signature;
      } while (_hazardPushQueued);
    } catch (_) {
    } finally {
      _hazardPushRunning = false;
    }
  }

  static List<RoadHazard>? _asList(RoadHazard? h) =>
      h == null ? null : <RoadHazard>[h];

  static String _roadHazardSignature(List<RoadHazard> values) {
    var hash = 0x811C9DC5;
    for (final h in values) {
      hash = 0x1fffffff & (hash ^ h.kind.hashCode);
      hash = 0x1fffffff & (hash * 16777619);
      hash = 0x1fffffff & (hash ^ (h.lat * 100000).round());
      hash = 0x1fffffff & (hash * 16777619);
      hash = 0x1fffffff & (hash ^ (h.lon * 100000).round());
      hash = 0x1fffffff & (hash * 16777619);
      hash = 0x1fffffff & (hash ^ (h.limit ?? -1));
    }
    return '${values.length}:$hash';
  }

  Future<void> _pushSavedPlaces() async {
    if (_savedPlacesPushRunning) return;
    final controller = _controller;
    if (controller == null || !_styleReady || !mounted) return;
    if (identical(_savedPlacesSrc, widget.savedPlaces)) return;
    _savedPlacesPushRunning = true;
    try {
      final collection = AbmSavedPlaces.compose(widget.savedPlaces);
      if (!mounted || controller != _controller) return;
      await controller.setGeoJsonSource(AbmSavedPlaces.sourceId, collection);
      _savedPlacesSrc = widget.savedPlaces;
    } catch (_) {
    } finally {
      _savedPlacesPushRunning = false;
    }
  }

  Future<void> _applyPoiVisibility() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    try {
      if (widget.localStylePath != null) {
        await c.setFilter('poi-points', offlinePoiLayerFilter(widget.visiblePoiKlasses, requireName: false));
        await c.setFilter('poi-labels', offlinePoiLayerFilter(widget.visiblePoiKlasses));
      } else {
        for (final layer in const ['poi_r1', 'poi_r7', 'poi_r20', 'poi_transit']) {
          await c.setFilter(
            layer,
            onlinePoiLayerFilter(
              widget.visiblePoiKlasses,
              layerId: layer,
            ),
          );
        }
      }
    } catch (e) {
      
    }
  }

  static const double _worldLoadZoom = 5.0;
  bool _worldLayerLoading = false;

  void _maybeLoadWorldLayer() {
    if (_worldLayerLoaded || _worldLayerLoading) return;
    final z = _camera?.zoom;
    if (z == null || z >= _worldLoadZoom) return;
    unawaited(_loadWorldCountriesLayer());
  }

  Future<void> _loadWorldCountriesLayer() async {
    if (_worldLayerLoaded || _worldLayerLoading) return;
    final controller = _controller;
    if (controller == null) return;
    final z = _camera?.zoom ?? controller.cameraPosition?.zoom;
    if (z != null && z >= _worldLoadZoom) return;
    _worldLayerLoading = true;
    try {
      final world = await WorldCountries.load();
      if (!mounted || controller != _controller) return;
      await controller.setGeoJsonSource('world-countries', world);
      _worldLayerLoaded = true;
    } catch (error) {
      
    } finally {
      _worldLayerLoading = false;
    }
  }

  bool _needsAbmReload(double lat, double lng) {
    final core = _loadedAbmCoreBounds;
    if (core == null) return true;
    return lng < core.minLon || lng > core.maxLon ||
        lat < core.minLat || lat > core.maxLat;
  }

  void _scheduleAbmRefresh({bool immediate = false}) {
    if (widget.localStylePath == null || widget.abmFile == null || !_styleReady) return;
    if (!_appIsResumed) return;
    _abmRefreshTimer?.cancel();
    if (immediate) {
      unawaited(_refreshAbmViewport('immediate'));
      return;
    }
    if (_cameraStillCovered()) return;
    _abmRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (_cameraStillCovered()) return;
      unawaited(_refreshAbmViewport('camera'));
    });
  }

  static ({Map<String, List<AbmVectorFeature>> layers, List<RoadHazard> hazards})
      _loadAbmSqliteOverlays(
    String sqlitePath,
    AbmBBox bbox,
    double zoom,
  ) {
    final db = sqlite.sqlite3.open(sqlitePath, mode: sqlite.OpenMode.readOnly);
    try {
      AbmVectorFeature pointFeature(Map<String, dynamic> r, String layer) {
        final lat = (r['lat'] as num).toDouble();
        final lon = (r['lon'] as num).toDouble();
        var name = '';
        for (final v in [r['name_fa'], r['name'], r['name_en']]) {
          final t = '${v ?? ''}'.trim();
          if (t.isNotEmpty) {
            name = t;
            break;
          }
        }
        return AbmVectorFeature(
          id: (r['id'] as num).toInt(),
          layer: layer,
          geometry: [[lon, lat]],
          bbox: AbmBBox(lon, lat, lon, lat),
          properties: <String, dynamic>{
            'name': name,
            'name_fa': '${r['name_fa'] ?? ''}',
            'name_en': '${r['name_en'] ?? ''}',
            'category': '${r['category'] ?? ''}',
            'class': '${r['category'] ?? ''}',
            'opening_hours': '${r['opening_hours'] ?? ''}',
          },
        );
      }

      final box = <Object>[bbox.minLon, bbox.maxLon, bbox.minLat, bbox.maxLat];
      var poiRows = db.select('SELECT 1 WHERE 0');
      try {
        poiRows = db.select(
          "SELECT f.id AS id, (f.id >> 2) AS source_id, COALESCE(n.name,'') AS name, "
          "COALESCE(n.name_fa,'') AS name_fa, COALESCE(n.name_en,'') AS name_en, "
          "c.name AS category, f.opening_hours AS opening_hours, "
          "(s.min_lat+s.max_lat)/2 AS lat, (s.min_lon+s.max_lon)/2 AS lon "
          "FROM spatial s JOIN features f ON f.id=s.id AND f.kind=0 "
          "JOIN categories c ON c.id=f.category_id LEFT JOIN names n ON n.id=f.name_id "
          "WHERE s.max_lon>=? AND s.min_lon<=? AND s.max_lat>=? AND s.min_lat<=? LIMIT 12000",
          box,
        );
      } catch (_) {
        poiRows = db.select(
          'SELECT id,source_id,name,name_fa,name_en,category,opening_hours,lat,lon '
          'FROM poi p WHERE p.lon>=? AND p.lon<=? AND p.lat>=? AND p.lat<=? LIMIT 12000',
          box,
        );
      }
      final zl = zoom + 0.5; // اختلافِ کمتر از ۰٫۵ زوم باعث reload نمی‌شود
      final kindFilter = zl < 8.5
          ? "AND c.name IN ('city','town') "
          : zl < 10.5
              ? "AND c.name IN ('city','town','village') "
              : zl < 12.5
                  ? "AND c.name IN ('city','town','village','hamlet','suburb') "
                  : '';
      var placeRows = db.select('SELECT 1 WHERE 0');
      try {
        placeRows = db.select(
          "SELECT f.id AS id, COALESCE(n.name,'') AS name, COALESCE(n.name_fa,'') AS name_fa, "
          "COALESCE(n.name_en,'') AS name_en, c.name AS category, f.opening_hours AS opening_hours, "
          "(s.min_lat+s.max_lat)/2 AS lat, (s.min_lon+s.max_lon)/2 AS lon "
          "FROM spatial s JOIN features f ON f.id=s.id AND f.kind=1 "
          "JOIN categories c ON c.id=f.category_id JOIN names n ON n.id=f.name_id "
          "WHERE s.max_lon>=? AND s.min_lon<=? AND s.max_lat>=? AND s.min_lat<=? "
          "$kindFilter"
          "ORDER BY CASE c.name WHEN 'city' THEN 0 WHEN 'town' THEN 1 WHEN 'village' THEN 2 ELSE 3 END "
          "LIMIT 6000",
          box,
        );
      } catch (_) {
        placeRows = db.select(
          'SELECT id,name,name_fa,name_en,category,opening_hours,lat,lon '
          'FROM places p WHERE p.lon>=? AND p.lon<=? AND p.lat>=? AND p.lat<=? '
          "AND p.category IN ('city','town','village','hamlet','suburb','neighbourhood') "
          "ORDER BY CASE p.category WHEN 'city' THEN 0 WHEN 'town' THEN 1 WHEN 'village' THEN 2 ELSE 3 END "
          'LIMIT 6000',
          box,
        );
      }
      final poi = poiRows
          .where((r) => !RoadHazards.isHazardCategory(r['category']))
          .map((r) => pointFeature(Map<String,dynamic>.from(r), 'poi'))
          .toList(growable: false);
      final places = placeRows.map((r) => pointFeature(Map<String,dynamic>.from(r), 'places')).toList(growable: false);
      final roads = VectorMapService.roadLabelLines(db, bbox);
      final hazards = RoadHazards.loadFromSqlite(
        db,
        minLon: bbox.minLon,
        minLat: bbox.minLat,
        maxLon: bbox.maxLon,
        maxLat: bbox.maxLat,
        zoom: zoom,
      );
      return (
        layers: <String, List<AbmVectorFeature>>{
          'poi': poi,
          'places': places,
          'roads': roads,
        },
        hazards: hazards,
      );
    } finally {
      db.dispose();
    }
  }

  Future<void> _refreshAbmViewport([String reason = 'queued']) async {
    final controller = _controller;
    final file = widget.abmFile;
    if (controller == null || file == null || !_styleReady || !mounted) return;
    if (_abmRefreshRunning) {
      _abmRefreshQueued = true;
      return;
    }
    _abmRefreshRunning = true;
    final generation = ++_abmRefreshGeneration;
    try {
      final bounds = await controller
          .getVisibleRegion()
          .timeout(const Duration(seconds: 5));
      const preloadFraction = 0.40;
      const sideFraction = preloadFraction / 2.0;
      final minLon = bounds.southwest.longitude;
      final maxLon = bounds.northeast.longitude;
      final minLat = bounds.southwest.latitude;
      final maxLat = bounds.northeast.latitude;
      final lonSpan = (maxLon - minLon).abs();
      final latSpan = (maxLat - minLat).abs();
      final bbox = AbmBBox(
        minLon - lonSpan * sideFraction,
        (minLat - latSpan * sideFraction).clamp(-85.05112878, 85.05112878).toDouble(),
        maxLon + lonSpan * sideFraction,
        (maxLat + latSpan * sideFraction).clamp(-85.05112878, 85.05112878).toDouble(),
      );
      final sources = (widget.abmSources != null && widget.abmSources!.isNotEmpty)
          ? widget.abmSources!
          : <OfflineMapSource>[
              OfflineMapSource(
                file: file,
                id: widget.abmCountry?.isNotEmpty == true
                    ? widget.abmCountry!
                    : p.basenameWithoutExtension(file.path),
              ),
            ];
      final merged = <String, List<AbmVectorFeature>>{
        'poi': <AbmVectorFeature>[],
        'places': <AbmVectorFeature>[],
        'roads': <AbmVectorFeature>[],
      };
      final hazardParts = <RoadHazard>[];
      final loadZoom = _camera?.zoom ?? 0.0;
      for (final source in sources) {
        final box = await offlineMapBbox(_vectorMapService, source);
        if (!bboxIntersects(box, bbox.minLon, bbox.minLat, bbox.maxLon, bbox.maxLat)) {
          continue;
        }
        try {
          final artifacts = await _vectorMapService.prepare(
            containerFile: source.file,
            id: source.id,
          );
          final part = await Isolate.run(
                  () => _loadAbmSqliteOverlays(
                      artifacts.sqliteFile.path, bbox, loadZoom))
              .timeout(const Duration(seconds: 20));
          for (final entry in part.layers.entries) {
            merged[entry.key]?.addAll(entry.value);
          }
          hazardParts.addAll(part.hazards);
        } catch (error) {
        }
      }
      final overlays = merged;
      if (!mounted || generation != _abmRefreshGeneration || controller != _controller) return;

      for (final entry in overlays.entries) {
        await controller.setGeoJsonSource(
          'abm-${entry.key}',
          <String, dynamic>{
            'type': 'FeatureCollection',
            'features': entry.value.map((f) => f.toGeoJson()).toList(growable: false),
          },
        ).timeout(const Duration(seconds: 8));
      }
      _viewportHazards = hazardParts;
      await _pushRoadHazards();
      _loadedAbmCoreBounds = AbmBBox(minLon, minLat, maxLon, maxLat);
      _loadedAbmZoom = _camera?.zoom ?? 0;
      int named(String k) => (overlays[k] ?? const <AbmVectorFeature>[])
          .where((f) => '${f.properties['name']}'.trim().isNotEmpty)
          .length;
      final zoom = _camera?.zoom;
      final sample = (overlays['roads'] ?? const <AbmVectorFeature>[])
          .map((f) => '${f.properties['name']}'.trim())
          .where((n) => n.isNotEmpty)
          .take(3)
          .join(' | ');
    } catch (error, stack) {
    } finally {
      _abmRefreshRunning = false;
      if (_abmRefreshQueued && mounted) {
        _abmRefreshQueued = false;
        _scheduleAbmRefresh();
      }
    }
  }

  void _onStyleLoaded() {
    _styleReady = true;
    _roadQueryLayerIds = null;
    RoadSnapper.instance.reset();
    _roadSnapTimer ??= Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) {
        if (!_appIsResumed) return;
        unawaited(_refreshRoadsForSnapping());
      },
    );
    _worldLayerLoaded = false;
    _loadedAbmCoreBounds = null;
    _savedPlacesSrc = null;
    _hazardDataSignature = null;
    if (widget.localStylePath != null) {
      unawaited(_applyPoiVisibility());
      unawaited(_loadWorldCountriesLayer());
      _scheduleAbmRefresh(immediate: true);
    }
    widget.onStyleLoaded?.call();
    unawaited(_refreshRouteAnnotations());
    unawaited(_refreshTrafficLights());
    unawaited(_applyRoadHazardVisibility());
    unawaited(_pushRoadHazards());
    unawaited(_pushSavedPlaces());
    if (_pendingLocationFocusRequest != 0) {
      _focusGpsCamera();
    } else if (widget.drivingMode && widget.vehiclePosition != null) {
      _syncCamera(force: true);
    } else {
      unawaited(_refreshScreenPositions());
    }
  }

  static int _routeDrawRank(OnlineRouteKind k) => switch (k) {
        OnlineRouteKind.traveled => 0,
        OnlineRouteKind.alternative => 1,
        OnlineRouteKind.route => 2,
      };

  String? _lastFitSig;

  static bool _sameRouteOverlays(
    List<OnlineRouteOverlay>? a,
    List<OnlineRouteOverlay>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i].geometry, b[i].geometry) ||
          a[i].color != b[i].color ||
          a[i].width != b[i].width ||
          a[i].kind != b[i].kind) {
        return false;
      }
    }
    return true;
  }

  void _fitCandidateRoutes() {
    final controller = _controller;
    final overlays = widget.routeOverlays;
    if (controller == null || overlays == null || overlays.isEmpty) {
      _lastFitSig = null;
      return;
    }
    final sig = '${overlays.length}|'
        '${[for (final o in overlays) '${o.geometry.length}:${o.geometry.first.latitude.toStringAsFixed(5)},${o.geometry.last.longitude.toStringAsFixed(5)}'].join(';')}';
    if (sig == _lastFitSig) return;
    _lastFitSig = sig;
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final o in overlays) {
      for (final p in o.geometry) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
    }
    if (minLat > maxLat || minLon > maxLon) return;
    final h = MediaQuery.of(context).size.height;
    final w = MediaQuery.of(context).size.width;
    unawaited(controller
        .animateCamera(
          ml.CameraUpdate.newLatLngBounds(
            ml.LatLngBounds(
              southwest: ml.LatLng(minLat, minLon),
              northeast: ml.LatLng(maxLat, maxLon),
            ),
            left: w * 0.08,
            right: w * 0.08,
            top: h * 0.36,
            bottom: h * 0.22,
          ),
          duration: const Duration(milliseconds: 600),
        )
        .catchError((_) => false));
  }

  Future<void> _refreshRouteAnnotations() async {
    final controller = _controller;
    if (!_styleReady || controller == null) return;
    final generation = ++_routeRefreshGeneration;
    final glow = widget.routeGlowIntensity.clamp(0.0, 1.0).toDouble();
    final features = <Map<String, dynamic>>[];
    final ordered = _routeOverlays
        .where((r) => r.geometry.length >= 2)
        .toList(growable: false)
      ..sort((a, b) => _routeDrawRank(a.kind).compareTo(_routeDrawRank(b.kind)));
    for (final route in ordered) {
      final isTraveled = route.kind == OnlineRouteKind.traveled;
      final isAlt = route.kind == OnlineRouteKind.alternative;
      features.add(<String, dynamic>{
        'type': 'Feature',
        'properties': <String, dynamic>{
          'kind': isTraveled ? 'traveled' : (isAlt ? 'alt' : 'route'),
          'color': _hexColor(route.color),
          'hl': _hexColor(Color.lerp(route.color, Colors.white, 0.62)!),
          'width': route.width,
          'glow': (isTraveled || isAlt) ? 0.0 : glow,
          'opacity': isTraveled ? 0.32 : route.color.a,
          'style': widget.routeLineStyle,
        },
        'geometry': <String, dynamic>{
          'type': 'LineString',
          'coordinates': [
            for (final p in route.geometry) [p.longitude, p.latitude],
          ],
        },
      });
    }
    try {
      if (generation != _routeRefreshGeneration) return;
      await controller.setGeoJsonSource('abm-route', <String, dynamic>{
        'type': 'FeatureCollection',
        'features': features,
      });
    } catch (_) {
    }
  }

  bool _sameLatLngList(List<LatLng> a, List<LatLng> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _refreshTrafficLights() async {
    final controller = _controller;
    if (!_styleReady || controller == null) return;
    try {
      await controller.setGeoJsonSource('abm-traffic-lights', <String, dynamic>{
        'type': 'FeatureCollection',
        'features': [
          for (final p in widget.trafficLights)
            <String, dynamic>{
              'type': 'Feature',
              'properties': const <String, dynamic>{},
              'geometry': <String, dynamic>{
                'type': 'Point',
                'coordinates': [p.longitude, p.latitude],
              },
            },
        ],
      });
    } catch (_) {
    }
  }

  String _hexColor(Color color) {
    final argb = color.toARGB32();
    return '#${((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0')}${((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0')}${(argb & 0xFF).toRadixString(16).padLeft(2, '0')}';
  }

  void _focusGpsCamera() {
    final controller = _controller;
    final position = widget.vehiclePosition;
    if (controller == null || position == null) return;
    _pendingLocationFocusRequest = 0;
    _resetCameraDrain('gps-button');
    final zoom = widget.drivingMode
        ? _navigationZoom(position.speedKmh)
        : _followZoom;
    final target = widget.drivingMode
        ? _navigationCameraTarget(position, zoom, position.headingDeg)
        : _toMapLibreVehiclePoint(position);
    unawaited(controller.moveCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: target,
          zoom: zoom,
          bearing: widget.drivingMode ? position.headingDeg : 0,
          tilt: widget.drivingMode
              ? widget.cameraTiltDegrees.clamp(0.0, 60.0).toDouble()
              : 0,
        ),
      ),
    ));
  }

  void _focusDestination(LatLng destination) {
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: _toMapLibrePoint(destination),
            zoom: (_maxMapZoom - 1).clamp(14.0, _maxMapZoom),
            bearing: 0,
            tilt: 0,
          ),
        ),
        duration: const Duration(milliseconds: 320),
      ),
    );
  }

  static const double _navLookAheadDp = 150.0;

  ml.LatLng _navigationCameraTarget(
    VehiclePosition position,
    double zoom,
    double bearingDeg,
  ) {
    final metersPerDp = 78271.517 *
        math.cos(position.lat * math.pi / 180.0).abs().clamp(0.15, 1.0) /
        math.pow(2.0, zoom);
    final freeDrive = widget.routeGeometry == null;
    final forwardMeters = freeDrive
        ? (metersPerDp * 60.0).clamp(0.0, 90.0).toDouble()
        : (metersPerDp * _navLookAheadDp).clamp(35.0, 260.0).toDouble();

    final heading = (bearingDeg.isFinite ? bearingDeg : 0.0) * math.pi / 180.0;
    const metersPerLatitude = 110540.0;
    final lat =
        position.lat + (math.cos(heading) * forwardMeters) / metersPerLatitude;
    final cosLat =
        math.cos(position.lat * math.pi / 180.0).abs().clamp(0.15, 1.0);
    final metersPerLongitude = 111320.0 * cosLat;
    final lng =
        position.lng + (math.sin(heading) * forwardMeters) / metersPerLongitude;
    return ml.LatLng(lat, lng);
  }

  double _navigationBearingTarget(VehiclePosition position, double speedKmh) {
    final fallback = _effectiveVehicleHeading(position) +
        vehicleModelYawCorrectionDegrees(widget.modelIndex);
    final route = widget.routeGeometry;
    if (route == null || route.length < 2 || speedKmh < 3.0) return fallback;
    final leadM = (speedKmh / 3.6 * 0.8).clamp(6.0, 30.0).toDouble();
    final here = LatLng(position.lat, position.lng);
    _inTightCurve = _routeTurnsSharply(here, route);
    if (_inTightCurve && _smoothedCameraBearing != null) {
      return _smoothedCameraBearing!;
    }
    final ahead = _pointAheadOnRoute(here, route, leadM);
    if (ahead == null || _distanceBetweenM(here, ahead) < 2.0) return fallback;
    return _bearingBetween(here, ahead);
  }

  bool _inTightCurve = false;

  bool _routeTurnsSharply(LatLng here, List<LatLng> route) {
    final first = _pointAheadOnRoute(here, route, 1.0);
    if (first == null) return false;
    var prev = first;
    var prevBearing = _bearingBetween(here, prev);
    var total = 0.0;
    for (var d = 10.0; d <= 60.0; d += 9.0) {
      final next = _pointAheadOnRoute(here, route, d);
      if (next == null || _distanceBetweenM(prev, next) < 1.0) break;
      final b = _bearingBetween(prev, next);
      total += (((b - prevBearing + 540.0) % 360.0) - 180.0).abs();
      prevBearing = b;
      prev = next;
    }
    return total > 100.0;
  }

  LatLng? _pointAheadOnRoute(
    LatLng position,
    List<LatLng> geometry,
    double forwardMeters,
  ) {
    if (geometry.length < 2) return null;
    if (!identical(_navRouteGeometry, geometry)) {
      _navRouteGeometry = geometry;
      _navRouteCumulativeM = _buildCumulativeDistancesM(geometry);
      _navRouteLastSegment = null;
    }
    final cumulative = _navRouteCumulativeM!;
    final lastSegmentCount = geometry.length - 2;

    const backWindowM = 60.0;
    const aheadWindowM = 300.0;
    var startIdx = 0;
    var endIdx = lastSegmentCount;
    final lastIdx = _navRouteLastSegment;
    if (lastIdx != null && lastIdx >= 0 && lastIdx <= lastSegmentCount) {
      final lastProgress = cumulative[lastIdx];
      final lo = lastProgress - backWindowM;
      final hi = lastProgress + aheadWindowM;
      var s = lastIdx;
      while (s > 0 && cumulative[s] > lo) s--;
      var e = lastIdx;
      while (e < lastSegmentCount && cumulative[e] < hi) e++;
      startIdx = s;
      endIdx = e;
    }

    var match = _bestRouteSegment(position, geometry, startIdx, endIdx);
    if (match.distanceMeters > 45 &&
        (startIdx > 0 || endIdx < lastSegmentCount)) {
      match = _bestRouteSegment(position, geometry, 0, lastSegmentCount);
    }
    if (match.distanceMeters > 80) {
      return null;
    }

    _navRouteLastSegment = match.segmentIndex;
    final segLen =
        cumulative[match.segmentIndex + 1] - cumulative[match.segmentIndex];
    final progressM = cumulative[match.segmentIndex] + segLen * match.t;
    return _pointAtRouteDistanceM(
        geometry, cumulative, progressM + forwardMeters);
  }

  ({int segmentIndex, double t, double distanceMeters}) _bestRouteSegment(
    LatLng position,
    List<LatLng> geometry,
    int startIdx,
    int endIdx,
  ) {
    var bestDistance = double.infinity;
    var bestIndex = startIdx;
    var bestT = 0.0;
    for (var i = startIdx; i <= endIdx; i++) {
      final projection =
          _projectOnRouteSegment(position, geometry[i], geometry[i + 1]);
      if (projection.distanceMeters < bestDistance) {
        bestDistance = projection.distanceMeters;
        bestIndex = i;
        bestT = projection.t;
      }
    }
    return (segmentIndex: bestIndex, t: bestT, distanceMeters: bestDistance);
  }

  ({double distanceMeters, double t}) _projectOnRouteSegment(
    LatLng point,
    LatLng a,
    LatLng b,
  ) {
    final latRad = point.latitude * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final abX = (b.longitude - a.longitude) * mx;
    final abY = (b.latitude - a.latitude) * my;
    final apX = (point.longitude - a.longitude) * mx;
    final apY = (point.latitude - a.latitude) * my;
    final lengthSquared = abX * abX + abY * abY;
    if (lengthSquared <= 1e-6) {
      return (distanceMeters: math.sqrt(apX * apX + apY * apY), t: 0.0);
    }
    final t = ((apX * abX + apY * abY) / lengthSquared).clamp(0.0, 1.0);
    final nearestX = abX * t;
    final nearestY = abY * t;
    final dx = apX - nearestX;
    final dy = apY - nearestY;
    return (distanceMeters: math.sqrt(dx * dx + dy * dy), t: t);
  }

  List<double> _buildCumulativeDistancesM(List<LatLng> geometry) {
    final cumulative = List<double>.filled(geometry.length, 0);
    for (var i = 1; i < geometry.length; i++) {
      cumulative[i] =
          cumulative[i - 1] + _distanceBetweenM(geometry[i - 1], geometry[i]);
    }
    return cumulative;
  }

  LatLng _pointAtRouteDistanceM(
    List<LatLng> geometry,
    List<double> cumulative,
    double meters,
  ) {
    final total = cumulative.last;
    final target = meters.clamp(0.0, total);
    var lo = 0;
    var hi = cumulative.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (cumulative[mid] <= target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = geometry[lo];
    final b = geometry[hi];
    final segLen = cumulative[hi] - cumulative[lo];
    final t = segLen <= 0.0001
        ? 0.0
        : ((target - cumulative[lo]) / segLen).clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  double _distanceBetweenM(LatLng a, LatLng b) {
    final latRad = ((a.latitude + b.latitude) / 2) * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final dx = (b.longitude - a.longitude) * mx;
    final dy = (b.latitude - a.latitude) * my;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _syncCamera({bool force = false}) {
    final controller = _controller;
    final position = widget.vehiclePosition;
    if (controller == null || position == null || !widget.followVehicle) {
      return;
    }
    final now = DateTime.now();
    if (_cameraMoveRunning &&
        now.difference(_cameraDrainStartedAt) > const Duration(seconds: 2)) {
      _resetCameraDrain('watchdog>2s');
    }
    if (!force && now.difference(_lastCameraUpdate) < _cameraUpdateInterval) {
      return;
    }
    _lastCameraUpdate = now;

    final speed = position.speedKmh.clamp(0.0, 160.0).toDouble();
    _cameraUpdateInterval =
        Duration(milliseconds: speed < 3.0 ? 500 : 66);
    final zoom = _navigationZoom(speed);
    final bearing = _smoothNavigationBearing(
      _navigationBearingTarget(position, speed),
      speedKmh: speed,
      now: now,
    );
    final camera = ml.CameraPosition(
      target: _navigationCameraTarget(position, zoom, bearing),
      zoom: zoom,
      bearing: bearing,
      tilt: widget.cameraTiltDegrees.clamp(0.0, 60.0).toDouble(),
    );

    _pendingCameraPosition = camera;
    if (_cameraMoveRunning) return;
    _cameraMoveRunning = true;
    _cameraDrainStartedAt = now;
    unawaited(_drainCameraMoves(controller, _cameraDrainGen));
  }

  Future<void> _drainCameraMoves(
      ml.MapLibreMapController controller, int gen) async {
    try {
      while (mounted &&
          gen == _cameraDrainGen &&
          controller == _controller &&
          widget.followVehicle) {
        final camera = _pendingCameraPosition;
        _pendingCameraPosition = null;
        if (camera == null) break;
        try {
          await controller
              .animateCamera(
                ml.CameraUpdate.newCameraPosition(camera),
                duration: _cameraUpdateInterval,
              )
              .timeout(_cameraUpdateInterval + const Duration(milliseconds: 600));
          _cameraDrainStartedAt = DateTime.now();
        } on TimeoutException {
          continue;
        } catch (_) {
          break;
        }
      }
    } finally {
      if (gen == _cameraDrainGen) {
        _cameraMoveRunning = false;
        if (_pendingCameraPosition != null &&
            mounted &&
            controller == _controller &&
            widget.followVehicle) {
          _cameraMoveRunning = true;
          _cameraDrainStartedAt = DateTime.now();
          unawaited(_drainCameraMoves(controller, _cameraDrainGen));
        }
      }
    }
  }

  double _smoothNavigationBearing(
    double target,
    {required double speedKmh, required DateTime now}) {
    if (!target.isFinite) {
      return _smoothedCameraBearing ?? 0.0;
    }
    final normalized = (target % 360.0 + 360.0) % 360.0;
    final previous = _smoothedCameraBearing;
    if (previous == null || _lastCameraBearingAt == null) {
      _smoothedCameraBearing = normalized;
      _lastCameraBearingAt = now;
      return normalized;
    }

    final dt = now.difference(_lastCameraBearingAt!).inMicroseconds / 1e6;
    _lastCameraBearingAt = now;
    final safeDt = dt.clamp(0.016, 0.12);

    if (speedKmh < 3.0) return previous;

    var delta = ((normalized - previous + 540.0) % 360.0) - 180.0;
    if (delta.abs() < 0.6) return previous;

    final maxStep = ((_inTightCurve ? 90.0 : 200.0) * safeDt).clamp(0.5, 24.0);
    delta = delta.clamp(-maxStep, maxStep).toDouble();
    final next = (previous + delta) % 360.0;
    _smoothedCameraBearing = next < 0 ? next + 360.0 : next;
    return _smoothedCameraBearing!;
  }

  double _navigationZoom(double speedKmh) {
    final v = speedKmh.clamp(0.0, 120.0).toDouble();
    if (v <= 10) return _followZoom;
    return _followZoom - 4.0 * ((v - 10) / 110.0);
  }

  static const double _followZoom = 18.0;

  DateTime _lastCamLog = DateTime.fromMillisecondsSinceEpoch(0);

  void _onCameraMove(ml.CameraPosition camera) {
    final t = DateTime.now();
    if (t.difference(_lastCamLog) > const Duration(seconds: 2)) {
      _lastCamLog = t;
    }
    _camera = camera;
    _maybeLoadWorldLayer();
    widget.onCameraPositionChanged?.call(camera);
    unawaited(_refreshScreenPositions());
    _scheduleAbmRefresh();
  }

  bool get _appIsResumed {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  Future<void> _refreshRoadsForSnapping() async {
    if (_roadQueryRunning || !mounted || !_appIsResumed) return;
    final controller = _controller;
    final position = widget.vehiclePosition;
    final screen = _vehicleScreen;
    if (controller == null || !_styleReady || position == null || screen == null) {
      return;
    }
    if (widget.routeGeometry != null && widget.routeGeometry!.length >= 2) return;
    final zoom = _camera?.zoom ?? 0;
    if (zoom < 12.5) return;

    final now = DateTime.now();
    final movedM = _lastRoadQueryPos == null
        ? 1e9
        : _roughDistanceM(_lastRoadQueryPos!, LatLng(position.lat, position.lng));
    final stale = now.difference(_lastRoadQueryAt).inMilliseconds > 4000;
    if (!stale && movedM < 5.0 && RoadSnapper.instance.hasRoads) return;

    _roadQueryRunning = true;
    try {
      var layers = _roadQueryLayerIds;
      if (layers == null) {
        final all = (await controller.getLayerIds()).map((e) => e.toString()).toSet();
        layers = _roadLayerCandidates.where(all.contains).toList();
        _roadQueryLayerIds = layers;
      }
      if (layers.isEmpty) return;

      final ratio = MediaQuery.devicePixelRatioOf(context);
      final rect = Rect.fromCenter(
        center: screen * ratio,
        width: 240.0 * ratio,
        height: 240.0 * ratio,
      );
      final raw = await controller
          .queryRenderedFeaturesInRect(rect, layers, null)
          .timeout(const Duration(milliseconds: 900));
      if (!mounted) return;

      final roads = <SnapRoad>[];
      final seen = <String>{};
      for (final f in raw) {
        if (roads.length >= 400) break;
        if (f is! Map) continue;
        final geom = f['geometry'];
        if (geom is! Map) continue;
        final props = f['properties'] is Map ? Map<String, dynamic>.from(f['properties'] as Map) : const <String, dynamic>{};
        final cls = (props['class'] ?? props['highway'] ?? 'road').toString();
        if (cls == 'rail' || cls == 'transit' || cls == 'path' || cls == 'pedestrian' || cls == 'footway') {
          continue;
        }
        final ow = props['oneway'];
        final owText = '${ow ?? ''}'.trim().toLowerCase();
        var oneway = (ow == 1 || ow == true || const ['1', 'true', 'yes', 'forward'].contains(owText))
            ? 1
            : (ow == -1 || const ['-1', 'reverse', 'backward'].contains(owText))
                ? -1
                : 0;
        final junction = '${props['junction'] ?? ''}'.trim().toLowerCase();
        if (oneway == 0 && (junction == 'roundabout' || junction == 'circular')) {
          oneway = 1;
        }
        final id = f['id'];
        final type = geom['type'];
        final coords = geom['coordinates'];
        final lines = <List>[];
        if (type == 'LineString' && coords is List) {
          lines.add(coords);
        } else if (type == 'MultiLineString' && coords is List) {
          for (final l in coords) {
            if (l is List) lines.add(l);
          }
        }
        for (final line in lines) {
          if (line.length < 2) continue;
          final lats = <double>[];
          final lngs = <double>[];
          for (final c in line) {
            if (c is List && c.length >= 2) {
              lngs.add((c[0] as num).toDouble());
              lats.add((c[1] as num).toDouble());
            }
          }
          if (lats.length < 2) continue;
          final sig = '${lats.first.toStringAsFixed(6)},${lngs.first.toStringAsFixed(6)},'
              '${lats.last.toStringAsFixed(6)},${lngs.last.toStringAsFixed(6)},${lats.length}';
          if (!seen.add(sig)) continue;
          final key = id is num ? id.toInt() : sig.hashCode;
          roads.add(SnapRoad(
            key: key,
            roadClass: cls,
            oneway: oneway,
            lats: lats,
            lngs: lngs,
          ));
        }
      }
      if (roads.isNotEmpty) RoadSnapper.instance.updateRoads(roads);
      _lastRoadQueryAt = now;
      _lastRoadQueryPos = LatLng(position.lat, position.lng);
    } on TimeoutException {
    } catch (_) {
    } finally {
      _roadQueryRunning = false;
    }
  }

  double _roughDistanceM(LatLng a, LatLng b) {
    final dy = (a.latitude - b.latitude) * 110540.0;
    final dx = (a.longitude - b.longitude) *
        111320.0 *
        math.cos(a.latitude * math.pi / 180.0).abs();
    return math.sqrt(dx * dx + dy * dy);
  }

  Future<void> _refreshScreenPositions() async {
    if (!_appIsResumed) return;
    final requestGeneration = ++_screenUpdateGeneration;


    if (_screenUpdateRunning) {
      _screenUpdateQueued = true;
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    _screenUpdateRunning = true;
    try {
      final position = widget.vehiclePosition;
      final vehiclePoint = position == null
          ? null
          : await controller
              .toScreenLocation(_toMapLibreVehiclePoint(position))
              .timeout(const Duration(seconds: 2));
      final destination = widget.destination;
      final destinationPoint = destination == null
          ? null
          : await controller
              .toScreenLocation(_toMapLibrePoint(destination))
              .timeout(const Duration(seconds: 2));

      if (requestGeneration != _screenUpdateGeneration ||
          !mounted ||
          controller != _controller) {
        return;
      }

      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      setState(() {
        final rawVehicle = vehiclePoint == null
            ? null
            : mapScreenPointToFlutterOffset(vehiclePoint, pixelRatio);
        final prevVehicle = _vehicleScreen;
        if (rawVehicle != null &&
            prevVehicle != null &&
            widget.followVehicle &&
            widget.drivingMode &&
            (rawVehicle - prevVehicle).distance < 60.0) {
          _vehicleScreen = Offset.lerp(prevVehicle, rawVehicle, 0.22);
        } else {
          _vehicleScreen = rawVehicle;
        }
        _destinationScreen = destinationPoint == null
            ? null
            : mapScreenPointToFlutterOffset(destinationPoint, pixelRatio);
      });
    } on TimeoutException {
    } catch (_) {
    } finally {
      _screenUpdateRunning = false;
      if (_screenUpdateQueued) {
        _screenUpdateQueued = false;
        unawaited(_refreshScreenPositions());
      }
    }
  }

  Future<void> _onMapClick(math.Point<double> screenPoint, ml.LatLng point) async {
    final tap = LatLng(point.latitude, point.longitude);
    final routeIndex = _hitTestRoute(tap, _routeOverlays);
    if (routeIndex != null) {
      widget.onRouteTap?.call(routeIndex);
      return;
    }
    if (widget.localStylePath != null && _controller != null) {
      try {
        final featureLayers = widget.localStylePath != null
            ? const ['poi-points', 'poi-labels', 'abm-road-major-labels', 'abm-road-local-labels', 'abm-road-line', 'abm-road-line-t1', 'abm-road-line-t2', 'abm-road-line-t3', 'abm-road-line-t4', 'label_city']
            : const ['poi-points', 'poi-labels', 'highway-name-major', 'highway-name-minor', 'label_city', 'road_minor'];
        final features = await _controller!.queryRenderedFeatures(
          screenPoint,
          featureLayers,
          null,
        );
        if (features.isNotEmpty) {
          final first = features.first;
          final props = first is Map && first['properties'] is Map
              ? Map<String, dynamic>.from(first['properties'] as Map)
              : <String, dynamic>{};
          if (props.isNotEmpty) {
            widget.onMapTap?.call(tap, props);
            widget.onPoiTap?.call(props);
            return;
          }
        }
      } catch (error) {
        
      }
    }
    widget.onMapTap?.call(tap, const <String, dynamic>{});
  }

  void _onMapLongClick(math.Point<double> _, ml.LatLng point) {
    widget.onLongPress?.call(LatLng(point.latitude, point.longitude));
  }

  int? _hitTestRoute(LatLng tap, List<OnlineRouteOverlay> overlays) {
    var hitRadiusMeters = 30.0;
    final zoom = _controller?.cameraPosition?.zoom;
    if (zoom != null) {
      final mpp = 78271.517 *
          math.cos(tap.latitude * math.pi / 180.0).abs() /
          math.pow(2, zoom);
      hitRadiusMeters = (28 * mpp).clamp(30.0, 4000.0).toDouble();
    }
    var bestDistance = hitRadiusMeters;
    int? bestIndex;
    for (var routeIndex = 0; routeIndex < overlays.length; routeIndex++) {
      final geometry = overlays[routeIndex].geometry;
      for (var pointIndex = 1; pointIndex < geometry.length; pointIndex++) {
        final distance = _distanceToSegmentMeters(
          tap,
          geometry[pointIndex - 1],
          geometry[pointIndex],
        );
        if (distance <= bestDistance) {
          bestDistance = distance;
          bestIndex = routeIndex;
        }
      }
    }
    return bestIndex;
  }

  double _distanceToSegmentMeters(LatLng point, LatLng start, LatLng end) {
    final latitudeRadians = point.latitude * math.pi / 180.0;
    final metersPerLongitude = 111320.0 * math.cos(latitudeRadians);
    final abX = (end.longitude - start.longitude) * metersPerLongitude;
    final abY = (end.latitude - start.latitude) * 110540.0;
    final apX = (point.longitude - start.longitude) * metersPerLongitude;
    final apY = (point.latitude - start.latitude) * 110540.0;
    final lengthSquared = abX * abX + abY * abY;
    if (lengthSquared <= 1e-6) return math.sqrt(apX * apX + apY * apY);
    final projection =
        ((apX * abX + apY * abY) / lengthSquared).clamp(0.0, 1.0);
    final nearestX = abX * projection;
    final nearestY = abY * projection;
    final dx = apX - nearestX;
    final dy = apY - nearestY;
    return math.sqrt(dx * dx + dy * dy);
  }

  double get _markerVisualSize {
    if (widget.showCarModel) return 96.0;
    return (40.0 * (widget.pinSizePercent / 100)).clamp(30.0, 82.0).toDouble();
  }

  List<LatLng>? _hdgRoute;
  int _hdgIndex = 0;
  double _hdgValue = 0.0;
  double _hdgLat = double.nan;
  double _hdgLng = double.nan;

  double _effectiveVehicleHeading(VehiclePosition position) {
    final route = widget.routeGeometry;
    if (route == null || route.length < 2 || position.speedKmh >= 3) {
      return position.headingDeg;
    }
    if (identical(route, _hdgRoute) &&
        (position.lat - _hdgLat).abs() < 1e-5 &&
        (position.lng - _hdgLng).abs() < 1e-5) {
      return _hdgValue;
    }
    final point = LatLng(position.lat, position.lng);
    final last = route.length - 2;

    int scan(int from, int to, void Function(int i, double d) visit) {
      var bestI = from;
      var bestD = double.infinity;
      for (var i = from; i <= to; i++) {
        final d = _distanceToSegmentMeters(point, route[i], route[i + 1]);
        if (d < bestD) {
          bestD = d;
          bestI = i;
        }
      }
      visit(bestI, bestD);
      return bestI;
    }

    var bestIndex = 0;
    var bestDistance = double.infinity;
    if (identical(route, _hdgRoute)) {
      final from = (_hdgIndex - 150).clamp(0, last).toInt();
      final to = (_hdgIndex + 150).clamp(0, last).toInt();
      scan(from, to, (i, d) {
        bestIndex = i;
        bestDistance = d;
      });
    }
    if (bestDistance > 40.0) {
      scan(0, last, (i, d) {
        bestIndex = i;
        bestDistance = d;
      });
    }
    _hdgRoute = route;
    _hdgIndex = bestIndex;
    _hdgLat = position.lat;
    _hdgLng = position.lng;
    _hdgValue = _bearingBetween(route[bestIndex], route[bestIndex + 1]);
    return _hdgValue;
  }

  double _bearingBetween(LatLng a, LatLng b) {
    final y = (b.longitude - a.longitude) *
        math.cos((a.latitude + b.latitude) * math.pi / 360.0);
    final x = b.latitude - a.latitude;
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  @override
  Widget build(BuildContext context) {
    final vehiclePosition = _vehicleScreen;
    final destinationPosition = _destinationScreen;
    final markerSize = _markerVisualSize;
    final mapBearing = _camera?.bearing ?? 0;
    final actualMapTilt =
        (_camera?.tilt ?? widget.cameraTiltDegrees).clamp(0.0, 60.0).toDouble();
    final effectiveCarCameraAngle = actualMapTilt;
    final geographicHeading = widget.vehiclePosition == null
        ? 0.0
        : _effectiveVehicleHeading(widget.vehiclePosition!) +
            vehicleModelYawCorrectionDegrees(widget.modelIndex);
    final screenHeading = mapRelativeHeading(geographicHeading, mapBearing);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.onUserGestureStart?.call(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ml.MapLibreMap(
            styleString: widget.localStylePath ??
                (throw StateError('Unified local MapLibre style was not resolved')),
            initialCameraPosition: _computeInitialCameraPosition(),
            minMaxZoomPreference:
                ml.MinMaxZoomPreference(_minMapZoom, _maxMapZoom),
            compassEnabled: false,
            myLocationEnabled: false,
            myLocationTrackingMode: ml.MyLocationTrackingMode.none,
            logoEnabled: false,
            scaleControlEnabled: false,
            rotateGesturesEnabled: true,
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            tiltGesturesEnabled: true,
            trackCameraPosition: true,
            foregroundLoadColor: widget.palette.background,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _onMapClick,
            onMapLongClick: _onMapLongClick,
            onCameraMove: _onCameraMove,
            onCameraIdle: () {
              unawaited(_refreshScreenPositions());
              final gps = widget.vehiclePosition;
              final skipRedundantReload = widget.followVehicle &&
                  gps != null &&
                  !_needsAbmReload(gps.lat, gps.lng);
              if (!skipRedundantReload) {
                _scheduleAbmRefresh();
              }
              widget.onCameraIdle?.call();
            },
          ),
          if (destinationPosition != null)
            Positioned(
              left: destinationPosition.dx - 21,
              top: destinationPosition.dy - 42,
              child: const IgnorePointer(
                child: AppIcon(
                  Icons.location_on_rounded,
                  color: Color(0xFFE84A5F),
                  size: 42,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 5)],
                ),
              ),
            ),
          if (widget.showCarModel)
            Positioned(
              left: (vehiclePosition?.dx ?? -markerSize) - markerSize / 2,
              top: (vehiclePosition?.dy ?? -markerSize) - markerSize * 0.50,
              width: markerSize,
              height: markerSize,
              child: IgnorePointer(
                child: Opacity(
                  opacity: vehiclePosition == null ? 0.0 : 1.0,
                  child: CarMarker3D(
                    size: markerSize,
                    modelIndex: widget.modelIndex,
                    headingDeg: screenHeading,
                    cameraAngleDegrees: effectiveCarCameraAngle,
                    sizePercent: widget.carSizePercent,
                    interactive: false,
                  ),
                ),
              ),
            ),
          if (!widget.showCarModel && vehiclePosition != null)
            Positioned(
              left: vehiclePosition.dx - markerSize / 2,
              top: vehiclePosition.dy - markerSize * 0.50,
              width: markerSize,
              height: markerSize,
              child: IgnorePointer(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: screenHeading * math.pi / 180,
                      child: NavArrow(
                        size: markerSize,
                        color: widget.markerColor,
                        glow: widget.pinShadowEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
