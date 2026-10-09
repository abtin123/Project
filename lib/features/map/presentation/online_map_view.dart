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

/// زاویهٔ مکان‌نما نسبت به صفحه، بر پایهٔ heading جغرافیایی GPS و جهت فعلی
/// دوربین. خروجی در بازهٔ استاندارد ۰ تا کمتر از ۳۶۰ درجه است.
double mapRelativeHeading(double headingDeg, double mapBearingDeg) {
  final heading = headingDeg.isFinite ? headingDeg : 0.0;
  final bearing = mapBearingDeg.isFinite ? mapBearingDeg : 0.0;
  return (heading - bearing) % 360.0;
}

/// MapLibre Android موقعیت را با pixel فیزیکی View برمی‌گرداند، در حالی که
/// Positioned در Flutter با logical pixel کار می‌کند. بدون این تبدیل، marker
/// روی نمایشگرهای با تراکم بالاتر از ۱ به سمت لبهٔ پایین/راست جابه‌جا می‌شد.
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
  // دوربین و سرعت‌گیر دیگر با لایهٔ POI عمومی رسم نمی‌شوند؛ لایه‌های
  // `abm-hz-*` (RoadHazards) آن‌ها را با اولویت/collision نشان می‌دهند. کلید
  // اینجا می‌ماند تا تیک تنظیمات کار کند (visibility در _applyRoadHazardVisibility).
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
  // null = every category is on; categories without a dedicated icon fall
  // back to `abm-poi` in the style, so no class list is needed.
  if (visibleKlasses == null) return base;
  final classes = <String>{
    for (final klass in visibleKlasses) ...?_offlinePoiClassesByKlass[klass],
  }.toList(growable: false);
  if (classes.isEmpty) return hidden;
  // `in` takes exactly (needle, haystack) in expression syntax; a
  // multi-value `['in', expr, a, b, ...]` is rejected by MapLibre and the
  // filter is silently ignored. `match` is the valid form.
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

/// رنگِ بخشِ طی‌شدهٔ مسیر (پشتِ خودرو).
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

/// MapLibre Native نمایش نقشهٔ آنلاین را با همان renderer GPU نقشهٔ آفلاین
/// renderer برداری داخلی هم‌راستا نگه می‌دارد. دادهٔ route و خودرو از سرویس‌های محلی آبتین
/// می‌آید و به provider نقشه وابسته نیست.
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

  /// null یعنی هنوز فیکس زنده و قابل اعتماد دریافت نشده است. در این حالت
  /// نقشه باز می‌ماند، اما marker و follow-camera عمداً فعال نمی‌شوند.
  final VehiclePosition? vehiclePosition;

  /// true یعنی مکان‌نمای سه‌بعدیِ خودرو نمایش داده شود؛ false یعنی فلشِ
  /// استانداردِ ناوبری (معادلِ AppearanceTab.car / AppearanceTab.pin).
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

  /// زاویهٔ اختصاصیِ دوربینِ مدلِ سه‌بعدیِ خودرو (۰=از بالا، ۹۰=از پشتِ
  /// خودرو) — مستقل از [cameraTiltDegrees] که کجیِ خودِ نقشه است.
  final double carCameraAngleDegrees;
  final int locationFocusRequest;
  final OfflineMapPalette palette;

  /// null یعنی همهٔ دسته‌های POI، و set خالی یعنی همه پنهان هستند.
  final Set<int>? visiblePoiKlasses;

  /// آفلاین‌خوانی از اپ حذف شده است؛ این مقدار دیگر داده‌ای تولید نمی‌کند و
  /// null یعنی style آنلاینِ بدون API key استفاده شود.
  final String? localStylePath;

  /// فایل .abm نصب‌شده. آفلاین‌خوانی حذف شده است — این مقدار دیگر باز/پردازش
  /// نمی‌شود؛ فقط برای سازگاریِ امضای ویجت با فراخوان‌کننده نگه داشته شده.
  final File? abmFile;

  /// شناسهٔ کشور/منطقه، فقط برای نام‌گذاریِ پوشهٔ کش داخلی.
  final String? abmCountry;

  /// همهٔ نقشه‌های آفلاین نصب‌شده؛ هم‌زمان فعال‌اند (POI/نام خیابان از همه).
  final List<OfflineMapSource>? abmSources;
  final List<LatLng>? routeGeometry;
  final List<OnlineRouteOverlay>? routeOverlays;

  /// موقعیت چراغ‌های راهنمایی؛ داخل خودِ نقشه (لایهٔ استایل) رسم می‌شوند.
  final List<LatLng> trafficLights;

  /// هشدارهای زنده (دوربین/سرعت‌گیر) اطراف خودرو و روی مسیر. با داده‌های SQLite
  /// ادغام و dedupe می‌شوند؛ لیست باید بین build ها identical بماند.
  final List<RouteAlert> roadAlerts;

  /// مکان‌های ذخیره‌شدهٔ کاربر؛ با یک GeoJSON source و Symbol Layer رسم می‌شوند.
  final List<AbmSavedPlace> savedPlaces;
  /// Progress of the active navigation route in meters. When supplied, the
  /// renderer keeps the traveled and remaining portions visually distinct.
  final double? routeProgressMeters;
  final Color routeColor;
  final double routeWidth;

  /// solid | dotted | dashed | dotDash (نام enum ِ RouteLineStyle).
  final String routeLineStyle;

  /// ۰..۱؛ درخششِ نئونیِ خودِ رنگ مسیر (۰ = بدون درخشش).
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
  // Camera follow must never queue long animations. A 220ms animation
  // triggered every 100ms made the camera permanently lag behind the car.
  // تیک دوربین تطبیقی: ایستاده ۵۰۰ms، در حرکت ~۱۵ فریم/ثانیه (قبلاً ۲۰ ثابت).
  Duration _cameraUpdateInterval = const Duration(milliseconds: 66);
  // No country/city is hardcoded. Until GPS or the active-map bbox is known,
  // MapLibre starts from a neutral world view; the active ABM bbox is applied
  // only as a map-data fallback, never as the user's location.
  static const _fallbackInitialTarget = ml.LatLng(0.0, 0.0);

  // --- Road matching feed (free-drive snap-to-road) --------------------
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

  /// اگر animateCamera بومی هرگز resolve نشود (لغو شده با moveCamera/gesture)،
  /// قفلِ صف دوربین برای همیشه true می‌ماند و دوربین دیگر دنبال نمی‌کند.
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

  // کشِ پیشرفتِ خودرو روی route.geometry برای هدفِ دوربینِ ناوبری (نگاه کنید
  // به _pointAheadOnRoute). جدا از کشِ مشابه در home_screen است چون این
  // ویجت مستقلاً به geometry دسترسی دارد.
  List<LatLng>? _navRouteGeometry;
  List<double>? _navRouteCumulativeM;
  int? _navRouteLastSegment;

  // --- Offline ABM rendering -----------------------------------------
  // The renderer consumes the Builder v3 MBTiles basemap through MapLibre Native.
  // SQLite is reserved for bounded POI/place/road-label overlays.
  //   // chunks intersecting the current viewport are extracted/parsed.
  Timer? _abmRefreshTimer;
  bool _worldLayerLoaded = false;
  bool _abmRefreshRunning = false;
  bool _abmRefreshQueued = false;
  int _abmRefreshGeneration = 0;
  final VectorMapService _vectorMapService = VectorMapService();

  // --- عوارض جاده‌ای (RoadHazards): دادهٔ viewport (SQLite) + هشدارهای زنده ---
  List<RoadHazard> _viewportHazards = const <RoadHazard>[];
  List<RoadHazard> _liveHazards = const <RoadHazard>[];
  Object? _liveHazardsSrc;
  bool _hazardPushRunning = false;
  bool _hazardPushQueued = false;
  String? _hazardDataSignature;
  Object? _savedPlacesSrc;
  bool _savedPlacesPushRunning = false;
  // The un-padded camera bounds used for the last successful ABM viewport
  // load. `_refreshAbmViewport` always fetches this box expanded by 20% on
  // every side (see `sideFraction` below), so as long as the GPS fix stays
  // inside `_loadedAbmCoreBounds` the already-loaded data still fully
  // covers the padded viewport and a reload would be wasted work (a new
  // isolate + sqlite query on every single GPS tick). Only once the fix
  // crosses out of this box -- i.e. it has reached the 20% padding band --
  // is a fresh, bbox-scoped reload actually needed.
  AbmBBox? _loadedAbmCoreBounds;
  double _loadedAbmZoom = 0;

  /// True when the camera centre is still inside the last loaded box at about
  /// the same zoom, so a camera-move/idle driven reload would fetch the same
  /// data again.
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

  // MapLibre location puck is intentionally disabled. The app uses its own
  // navigation vehicle marker and must not show the default blue location dot.

  static const double _minMapZoom = 2.0;
  // 18 per user request: allow closer street-level inspection. The offline
  // ABM files use overview zooms so 17–18 fall back to lower-resolution
  // overview tiles rather than showing blank voids.
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
    // Warm the on-disk ABM runtime cache even while the visible map is in
    // online mode. This is intentionally fire-and-forget and is coalesced by
    // VectorMapService, so it never blocks MapLibre's online first frame.
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
      // A different .abm file covers different ground entirely, so any
      // previously-loaded box is meaningless for it.
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
    // Follow-camera is a map behavior, not a navigation-only behavior.
    // When the user has not manually taken control, the camera must stay
    // behind the vehicle both with and without an active route.
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
        // NOTE: this used to also call `_focusGpsCamera()` here on every
        // single GPS tick. `_focusGpsCamera` does an instant, unanimated
        // `moveCamera` -- meant only for one-off re-anchors like the GPS
        // button (see `locationFocusRequest` above) or first load. Calling
        // it on every tick raced with the smooth `_syncCamera` animation
        // started a few lines above for the very same tick: the animation
        // would begin, then immediately get hard-cut to (almost) the same
        // target, which is exactly the jarring "snap" visible in the
        // recording. `_syncCamera` already re-centers the camera smoothly
        // whenever `followVehicle` is on, for both online and offline, so
        // this block only needs to decide whether the ABM data still
        // covers the new position.
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
    // Initialize the camera before the first ABM viewport query. MapLibre can
    // report its constructor camera (often 0,0) for a short window while the
    // real GPS camera is being applied. Starting the ABM query during that
    // window produces a perfectly valid but completely empty viewport.
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
    // Do not wait for a user gesture. The first data request is explicitly
    // tied to the camera we just established. onStyleLoaded will also trigger
    // this path, but the generation guard prevents stale results.
    if (_styleReady && widget.abmFile != null) {
      _scheduleAbmRefresh(immediate: true);
    }
    _focusGpsCamera();
  }

  Future<void> _centerOnOfflineMapBounds(ml.MapLibreMapController controller) async {
    try {
      final file = widget.abmFile;
      if (file == null || !await file.exists()) return;
      // If GPS arrived between onMapCreated and this async metadata read, GPS
      // is authoritative (e.g. the user is in Arak while AM.abm is also
      // installed). Never replace a valid GPS position with the file center.
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

  /// تیک‌های «دوربین سرعت» / «سرعت‌گیر» در تنظیمات روی لایه‌های hazard اعمال
  /// می‌شود (فقط visibility؛ بدون ساخت دوبارهٔ داده).
  Future<void> _applyRoadHazardVisibility() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final visible = RoadHazards.visibleKinds(widget.visiblePoiKlasses);
    for (final spec in RoadHazards.specs) {
      try {
        await c.setLayerVisibility(
            '${RoadHazards.layerPrefix}${spec.id}', visible.contains(spec.id));
      } catch (_) {
        // لایه هنوز در style نیست؛ callback بارگذاری style دوباره اعمال می‌کند.
      }
    }
  }

  /// داده‌های viewport + هشدارهای زنده را ادغام (dedupe + thinning بر اساس تراکم)
  /// و فقط محتوای source `abm-hazards` را جایگزین می‌کند. برای لیست‌های بزرگ
  /// محاسبه در Isolate است تا UI thread لگ نکند.
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
      // source هنوز آماده نیست؛ callback بارگذاری style دوباره می‌نشاند.
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
      // source may not be ready during a style swap; onStyleLoaded retries it.
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
        // Online OpenMapTiles POIs are split by rank in the real style. Keep
        // each layer's original rank/geometry semantics while adding the
        // user's category filter; no synthetic POIs or provider-side query
        // results are created here.
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

  /// World map is drawn only below this zoom (style layers use maxzoom 4).
  /// Data is loaded lazily below [_worldLoadZoom] (small margin so it is ready
  /// before it becomes visible) and never touched while zoomed in.
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

  /// True when `position` has left the box that was actually loaded (the
  /// last visible camera bounds, before the 20% padding was added) -- i.e.
  /// it has reached the padding band and the padded data around it can no
  /// longer be assumed to still cover the viewport. False means the fix is
  /// still comfortably inside already-loaded data and no reload is needed.
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
        // ستون‌ها در SQL با COALESCE(...,'') می‌آیند، یعنی هیچ‌وقت null نیستند؛
        // پس `a ?? b` هرگز به b نمی‌رسید و شهرِ بدون name_fa بی‌نام (و حذف‌شده
        // توسط فیلتر استایل) می‌شد. اولین مقدار «غیرخالی» انتخاب می‌شود.
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

      // view های `poi`/`places` ستون lat/lon را محاسبه می‌کنند، پس SQLite
      // نمی‌تواند از ایندکس R-tree استفاده کند و در هر بار refresh کل جدول
      // features (میلیون‌ها ردیف) را اسکن می‌کرد — مصرف CPU/باتری بالا. اینجا
      // مستقیم از `spatial` (R-tree) شروع می‌کنیم.
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
        // نقشهٔ قدیمی بدون جدول spatial/features: همان view قبلی.
        poiRows = db.select(
          'SELECT id,source_id,name,name_fa,name_en,category,opening_hours,lat,lon '
          'FROM poi p WHERE p.lon>=? AND p.lon<=? AND p.lat>=? AND p.lat<=? LIMIT 12000',
          box,
        );
      }
      // فقط «مکان‌های جغرافیایی» (kind=1). view `places` همهٔ features را شامل
      // می‌شود (خیابان‌ها و POI هم)، و تا ۶۰۰۰ نام خیابان/POI به‌عنوان برچسب
      // شهر وارد MapLibre می‌شد. کلاس‌ها هم بر اساس زوم محدود می‌شوند.
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
      // دوربین/سرعت‌گیر/... فقط با لایه‌های RoadHazards رسم می‌شوند؛ از POI عمومی
      // (آیکن abm-poi و allow-overlap) خارج می‌شوند.
      final poi = poiRows
          .where((r) => !RoadHazards.isHazardCategory(r['category']))
          .map((r) => pointFeature(Map<String,dynamic>.from(r), 'poi'))
          .toList(growable: false);
      final places = placeRows.map((r) => pointFeature(Map<String,dynamic>.from(r), 'places')).toList(growable: false);
      // نام خیابان‌ها: خطِ پیوستهٔ هر way (نه نقطهٔ مرکزِ bbox) تا برچسب روی خودِ خیابان بنشیند.
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
        // فقط نقشه‌هایی که با پنجرهٔ دید تلاقی دارند خوانده می‌شوند.
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
      // عوارض جاده‌ای: یک source ثابت؛ فقط داده جایگزین می‌شود، لایه‌ها دست‌نخورده.
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
    // A reloaded style starts with empty abm-* GeoJSON sources again, so any
    // previously-loaded box no longer describes what's actually on screen.
    _loadedAbmCoreBounds = null;
    _savedPlacesSrc = null;
    _hazardDataSignature = null;
    // The online provider style is the single source of visual truth. Do not
    // rewrite its paint values here: doing so used to make offline landuse
    // green while online stayed on the OpenFreeMap palette.
    // Online POI, street labels and one-way arrows are part of the bundled
    // unified style. Their data remains OpenMapTiles/network data; the icon
    // atlas and glyphs are local project assets. Do not mutate the style here.
    if (widget.localStylePath != null) {
      unawaited(_applyPoiVisibility());
      unawaited(_loadWorldCountriesLayer());
      _scheduleAbmRefresh(immediate: true);
    }
    widget.onStyleLoaded?.call();
    unawaited(_refreshRouteAnnotations());
    unawaited(_refreshTrafficLights());
    // style جدید = sourceهای خالی؛ عوارض را دوباره می‌نشانیم و تیک‌های دسته را اعمال می‌کنیم.
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

  // ترتیبِ رسم: طی‌شده ← جایگزین‌ها ← مسیر انتخاب‌شده (همیشه روی همه).
  static int _routeDrawRank(OnlineRouteKind k) => switch (k) {
        OnlineRouteKind.traveled => 0,
        OnlineRouteKind.alternative => 1,
        OnlineRouteKind.route => 2,
      };

  String? _lastFitSig;

  /// لیست overlay در هر build دوباره ساخته می‌شود؛ مقایسهٔ مقداری جلوی
  /// setGeoJsonSource بی‌دلیل (و لگ هنگام زوم/جابه‌جایی) را می‌گیرد.
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

  /// وقتی چند مسیرِ پیشنهادی (قبل از شروع ناوبری) آماده شد، دوربین طوری قاب
  /// می‌گیرد که همهٔ مسیرها از مبدأ تا مقصد کامل دیده شوند.
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

  /// مسیر با GeoJSON source (`abm-route`) و لایه‌های داخل استایل رسم می‌شود:
  /// درخششِ بیرونی/درونی، هستهٔ رنگی، هایلایتِ مرکزی و بخشِ طی‌شدهٔ خاکستری.
  /// برخلاف annotation lineها، نوعِ خط (نقطه/خط‌چین) و blur پشتیبانی می‌شود و
  /// تغییرِ رنگ/ضخامت فقط با جایگزینیِ داده اعمال می‌شود.
  Future<void> _refreshRouteAnnotations() async {
    final controller = _controller;
    if (!_styleReady || controller == null) return;
    final generation = ++_routeRefreshGeneration;
    final glow = widget.routeGlowIntensity.clamp(0.0, 1.0).toDouble();
    final features = <Map<String, dynamic>>[];
    // مسیر طی‌شده اول (زیر مسیر اصلی)، بعد بقیه.
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
      // در لحظهٔ جایگزینی style، source هنوز آماده نیست؛ callback بارگذاری
      // style دوباره مسیر را ثبت می‌کند.
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

  /// چراغ‌های راهنمایی با source `abm-traffic-lights` و لایه‌های
  /// `abm-traffic-light-*` در استایل، مستقیم روی نقشه (چهارراه‌ها) رسم می‌شوند.
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
      // style هنوز آماده نیست؛ callback بارگذاری style دوباره ثبت می‌کند.
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
    // GPS button is a re-anchor, not a queued animation. First put the map
    // exactly on the current vehicle frame; the next follow tick takes over.
    // Outside navigation the GPS button is exactly 18. In navigation it uses
    // the same speed curve (18 -> 14) as the follow tick, so there is no zoom
    // jump right after pressing it at speed.
    final zoom = widget.drivingMode
        ? _navigationZoom(position.speedKmh)
        : _followZoom;
    // In navigation the vehicle is intentionally rendered around 64% down
    // the viewport. Re-anchoring the GPS button must use the same camera
    // target, otherwise the marker briefly jumps to the center and then back
    // to the lower-third follow position.
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

  /// در ناوبری، خودرو نباید وسط صفحه قفل شود؛ باید در نیمهٔ پایین بماند
  /// و بخش بیشتری از مسیرِ جلوی راننده دیده شود، شبیه Google Maps/Waze.
  /// بنابراین مرکز دوربین چند ده متر در امتداد heading جلوتر از خودرو قرار
  /// می‌گیرد. این کار با tilt نیز پایدارتر از دستکاریِ مختصاتِ screen است.
  /// هرچه بزرگ‌تر، خودرو پایین‌تر و مسیر جلوی آن بیشتر دیده می‌شود.
  static const double _navLookAheadDp = 150.0;

  ml.LatLng _navigationCameraTarget(
    VehiclePosition position,
    double zoom,
    double bearingDeg,
  ) {
    final metersPerDp = 78271.517 *
        math.cos(position.lat * math.pi / 180.0).abs().clamp(0.15, 1.0) /
        math.pow(2.0, zoom);
    // خارج از مسیریابی دوربین باید تقریباً روی خودِ خیابان/خودرو بماند؛
    // look-ahead بلند فقط برای ناوبری است و در حالت آزاد دوربین را از خیابان
    // دور می‌کرد.
    final freeDrive = widget.routeGeometry == null;
    final forwardMeters = freeDrive
        ? (metersPerDp * 60.0).clamp(0.0, 90.0).toDouble()
        : (metersPerDp * _navLookAheadDp).clamp(35.0, 260.0).toDouble();

    // هدف دوربین باید روی امتدادِ «همان bearingی که به دوربین داده می‌شود»
    // باشد، نه روی کمانِ مسیر. اگر هدف روی کمان مسیر برود، لحظهٔ ورود پیچ به
    // پنجرهٔ look-ahead مرکز دوربین ناگهان به کنار می‌پرد در حالی که bearing هنوز
    // نچرخیده؛ نتیجه: خودرو از خط مسیر جدا می‌شود و دوربین عقب می‌ماند. با این
    // روش خودرو همیشه در یک نقطهٔ ثابتِ صفحه می‌ماند و فقط نقشه دور آن می‌چرخد.
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

  /// bearing هدف دوربین: در ناوبری، جهتِ نقطه‌ای کمی جلوتر روی خودِ مسیر
  /// (بسته به سرعت) تا دوربین قبل از رسیدن خودرو به پیچ شروع به چرخش کند و
  /// عقب نماند. بدون مسیر، heading خودرو.
  double _navigationBearingTarget(VehiclePosition position, double speedKmh) {
    final fallback = _effectiveVehicleHeading(position) +
        vehicleModelYawCorrectionDegrees(widget.modelIndex);
    final route = widget.routeGeometry;
    if (route == null || route.length < 2 || speedKmh < 3.0) return fallback;
    final leadM = (speedKmh / 3.6 * 0.8).clamp(6.0, 30.0).toDouble();
    final here = LatLng(position.lat, position.lng);
    // میدان کوچک / پیچ بسته: مسیر در ~۶۰ متر جلو بیش از ۱۰۰° می‌چرخد. اگر
    // دوربین bearing مسیر را دنبال کند، دور میدان می‌چرخد و خودرو گم می‌شود؛
    // پس تا خروج از میدان جهت دوربین ثابت می‌ماند.
    _inTightCurve = _routeTurnsSharply(here, route);
    if (_inTightCurve && _smoothedCameraBearing != null) {
      return _smoothedCameraBearing!;
    }
    final ahead = _pointAheadOnRoute(here, route, leadM);
    if (ahead == null || _distanceBetweenM(here, ahead) < 2.0) return fallback;
    return _bearingBetween(here, ahead);
  }

  bool _inTightCurve = false;

  /// مجموع چرخش مطلق مسیر در ۶۰ متر جلوی [here] (نمونه‌برداری هر ۹ متر).
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

  /// نقطه‌ای [forwardMeters] جلوتر از [position] روی خودِ [geometry] (نه خط‌راستِ
  /// heading). ابتدا [position] روی نزدیک‌ترین قطعه projection می‌شود تا
  /// پیشرفتِ فعلی (متر از ابتدای مسیر) به دست آید، سپس همان مقدار جلوتر روی
  /// geometry پیمایش می‌شود. جست‌وجو حول آخرین قطعهٔ منطبق‌شده پنجره‌ای است
  /// (مثل _matchPositionToRoute در home_screen) تا برای مسیرهای طولانی هر
  /// فریم O(کل مسیر) نشود؛ اگر نتیجهٔ پنجره خیلی دور بود، یک‌بار کل مسیر را
  /// جست‌وجو می‌کند.
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
      // خودرو خیلی از این geometry دور است (مثلاً هنوز به مسیر نرسیده)؛
      // امتدادِ خط‌راستِ heading قابل‌اعتمادتر از چسباندنِ زوری به مسیر است.
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

    // Coalesce native camera commands. Never let several moveCamera calls
    // execute out of order; the newest GPS frame always wins.
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
          // moveCamera is a hard cut with no interpolation; at a 50ms tick
          // cadence that produced a visible stutter/jump on every frame
          // instead of a smooth pan+rotate, most noticeable on turns and
          // right after a reroute snaps the marker onto a new road. The
          // vehicle position feeding this call is already a continuously
          // smoothed 60fps stream (see VehiclePositionAnimator), so the
          // camera only needs to glide from its current pose to the next
          // sample over the same interval, not snap to it.
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
        // A GPS frame may have arrived between the final read and releasing the
        // lock. Consume it once, rather than starting another native queue.
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

    // At very low speed GNSS heading is often noise. Hold the last stable
    // camera direction instead of allowing a stopped vehicle to spin the map.
    if (speedKmh < 3.0) return previous;

    var delta = ((normalized - previous + 540.0) % 360.0) - 180.0;
    if (delta.abs() < 0.6) return previous;

    // Limit camera angular velocity. The marker/vehicle heading is already
    // smoothed by VehiclePositionAnimator; the camera must not rotate faster
    // than that visual motion on a single GPS sample, especially through
    // 90-degree turns and roundabouts.
    final maxStep = ((_inTightCurve ? 90.0 : 200.0) * safeDt).clamp(0.5, 24.0);
    delta = delta.clamp(-maxStep, maxStep).toDouble();
    final next = (previous + delta) % 360.0;
    _smoothedCameraBearing = next < 0 ? next + 360.0 : next;
    return _smoothedCameraBearing!;
  }

  double _navigationZoom(double speedKmh) {
    // زوم دنبال‌کردن (دکمهٔ GPS، حالت عادی و مسیریابی) با سرعت نرم بین
    // ۱۸ (ایستاده/کم‌سرعت) و ۱۴ (سرعت بالا) عوض می‌شود.
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

  /// خیابان‌های رندرشدهٔ اطراف خودرو را (آنلاین یا آفلاین) می‌خواند و به
  /// [RoadSnapper] می‌دهد تا خودرو/پیکان به نزدیک‌ترین خیابان بچسبد.
  /// در پس‌زمینه سطح رندر نقشه متوقف است؛ queryRenderedFeatures و projection
  /// در آن حالت صف می‌شوند و هنگام برگشت یک‌جا اجرا می‌شوند (هنگ).
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
    // در مسیریابی مسیر خودش مرجع است.
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

      // `_vehicleScreen` منطقی (dp) است ولی queryRenderedFeaturesInRect در
      // اندروید مختصات فیزیکی (px) می‌خواهد (همان فضای toScreenLocation و
      // onMapClick). بدون ضرب در pixelRatio، مستطیل جستجو جای دیگری از صفحه
      // می‌افتاد و هیچ خیابانی نزدیک خودرو پیدا نمی‌شد => snap هرگز کار نمی‌کرد.
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
        // میدان‌ها همیشه یک‌طرفه‌اند، حتی اگر برچسب oneway نداشته باشند.
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
      // نقشه مشغول است؛ دور بعدی دوباره تلاش می‌شود.
    } catch (_) {
      // در تعویض style ممکن است query موقتاً در دسترس نباشد.
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

    // The vehicle marker must remain geographically attached to the same
    // coordinate that the route renderer draws. A fixed screen coordinate
    // (previously 50% x / 66% y) was only an approximation: camera bearing,
    // tilt and the route-ahead target mean that the fixed point is not
    // necessarily the vehicle's road coordinate. On bends this made the car
    // visibly leave the turquoise route even though its LatLng was correct.
    // Always project the actual animated vehicle coordinate through MapLibre;
    // the camera may move, but the marker stays on the road.

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

      // A projection belongs to the camera frame that requested it. Discard
      // it if a newer camera/GPS frame has already been requested.
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
        // در حالت follow دوربین خودرو را در یک نقطهٔ ثابتِ صفحه نگه می‌دارد؛
        // تأخیرِ projection ناهمگام باعث لرزش/جدا شدن از خط مسیر می‌شد. نتیجهٔ
        // projection نرم می‌شود (پرش‌های بزرگ، مثل gesture یا تغییر دوربین، مستقیم
        // اعمال می‌شوند).
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
      // During style replacement projection may temporarily be unavailable.
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
    // شعاع لمس با زوم تغییر می‌کند: در نمای کل مسیرها ~۲۸ پیکسل، حداقل ۳۰ متر.
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
    // Keep the map anchor box independent from the car-size preference.
    // The 3D model itself is scaled inside this fixed box.
    if (widget.showCarModel) return 96.0;
    return (40.0 * (widget.pinSizePercent / 100)).clamp(30.0, 82.0).toDouble();
  }

  // Cache for the low-speed route-heading lookup. build() and _syncCamera()
  // call _effectiveVehicleHeading on every map frame; a full O(route) scan each
  // time froze the UI right after navigation started (vehicle still stationary).
  List<LatLng>? _hdgRoute;
  int _hdgIndex = 0;
  double _hdgValue = 0.0;
  double _hdgLat = double.nan;
  double _hdgLng = double.nan;

  double _effectiveVehicleHeading(VehiclePosition position) {
    final route = widget.routeGeometry;
    // در سرعت کم، GPS معمولاً heading صفر/نویزدار می‌دهد. در حالت ناوبری
    // جهت نزدیک‌ترین قطعهٔ مسیر پایدارتر است و خودرو روی خط عمودی نمی‌ماند.
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
    // tilt واقعیِ MapLibre مرجع اصلی مدل است؛ نه فقط مقدار تنظیمات اولیه.
    // به این ترتیب اگر کاربر نقشه را با gesture از 2D به هر زاویه‌ای ببرد،
    // نمای خودرو در همان فریم به پرسپکتیؤ نقشه نزدیک می‌شود.
    final actualMapTilt =
        (_camera?.tilt ?? widget.cameraTiltDegrees).clamp(0.0, 60.0).toDouble();
    // زاویهٔ خودرو دقیقاً همان tilt نقشه است (بدون ضریب و بدون اسلایدر).
    final effectiveCarCameraAngle = actualMapTilt;
    // asset پیکان در حالت پایه رو به بالای صفحه (شمال) است؛ بنابراین تنها
    // چرخش لازم، اختلاف heading جغرافیایی با bearing فعلی نقشه است. offset
    // قبلیِ -90 باعث می‌شد مکان‌نما یک ربع‌گردش از مسیر واقعی منحرف باشد.
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
            // Do not eagerly initialize MapLibre's AnnotationManager while
            // the Android activity/view is still attaching. Older maplibre_gl
            // builds call addLineLayer from the controller constructor and can
            // throw MAP_NOT_READY during activity recreation. Route lines are
            // added lazily after onStyleLoaded instead.
            foregroundLoadColor: widget.palette.background,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _onMapClick,
            onMapLongClick: _onMapLongClick,
            onCameraMove: _onCameraMove,
            onCameraIdle: () {
              unawaited(_refreshScreenPositions());
              // In follow mode the camera re-centers on every GPS tick, so
              // this idle event fires right after the position-change
              // handler already decided (via `_needsAbmReload`) whether a
              // reload was warranted. Re-checking here instead of always
              // reloading avoids a second, redundant viewport query for the
              // same GPS fix. A manual pan/zoom (not following) always
              // reloads, since it can reveal an area GPS-based gating knows
              // nothing about.
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
          // Keep the ModelViewer mounted even while GPS/map projection is
          // temporarily unavailable. model_viewer_plus initializes its
          // controller asynchronously; removing it during that gap can
          // trigger setState-after-dispose inside the plugin.
          //
          // NOTE: there used to be an extra outer `Transform(...rotateX...)`
          // "tilt skew" wrapped around CarMarker3D here, meant to lean the
          // marker back as the map tilted. It was redundant AND wrong: the
          // ModelViewer inside CarMarker3D already renders a real 3D chase
          // -cam view of the GLB model (camera-orbit elevation driven by
          // `effectiveCarCameraAngle`, itself tied to `actualMapTilt`), so
          // the "lean back with the map" look is already baked into the
          // rendered pixels, heading-independent, because model-viewer's
          // camera orbits the car in the car's OWN local frame, not the
          // screen frame. CarMarker3D then only rotates that flat, already
          // -correct render around the screen Z axis to match on-screen
          // heading. The extra outer rotateX was applied in a *fixed screen
          // axis* on top of that already Z-rotated sprite — correct only
          // when the car happened to be pointing "up" the screen. At other
          // headings (car pointing back/sideways) the same fixed-axis skew
          // squashed the sprite along the wrong axis relative to the car's
          // own facing direction, which is exactly the "car stands
          // perpendicular to the map" artifact. Removing it lets the single,
          // real-3D, heading-independent tilt from ModelViewer's own camera
          // be the only source of "car leans with the map", so it can never
          // point the wrong way regardless of heading.
          if (widget.showCarModel)
            Positioned(
              left: (vehiclePosition?.dx ?? -markerSize) - markerSize / 2,
              top: (vehiclePosition?.dy ?? -markerSize) - markerSize * 0.50,
              width: markerSize,
              height: markerSize,
              // Keep the GLB instance mounted across short GPS gaps and route
              // transitions. Hiding it instead of replacing it with SizedBox
              // prevents the WebView/GLB controller from being destroyed and
              // reloaded after navigation ends.
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
