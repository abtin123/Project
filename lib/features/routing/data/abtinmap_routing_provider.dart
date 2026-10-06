import 'dart:math' as math;

import '../../../core/geo/geo_types.dart';
import '../../../abtinmap/abm_map_service.dart';
import '../../../routing/routing_engine.dart' as routing_engine_lib;
import '../../offline_maps/data/vector_map_service.dart';
import 'road_safety_service.dart';
import 'routing_provider.dart';
import 'routing_service.dart';
import 'routing_instruction_localizer.dart';

/// Offline routing reader for the canonical ABM province-specific SQLite graph.
class AbtinmapRoutingProvider implements RoutingProvider {
  AbtinmapRoutingProvider({
    required AbmMapService mapService,
    required VectorMapService vectorMapService,
    required this.mapName,
    this.languageCode = _defaultLanguageCode,
  })  : _mapService = mapService,
        _vectorMaps = vectorMapService;

  final AbmMapService _mapService;
  final String mapName;
  final String Function() languageCode;
  static String _defaultLanguageCode() => 'fa';
  final routing_engine_lib.AbmRoutingEngine _engine = routing_engine_lib.AbmRoutingEngine();
  final VectorMapService _vectorMaps;
  String? _lastError;

  @override
  RoutingEngine get engine => RoutingEngine.abtinmap;
  @override
  String get displayName => 'آبتین‌مپ (آفلاین)';
  @override
  bool get isOffline => true;
  @override
  String? get lastError => _lastError;

  @override
  Future<bool> isReady() async {
    try {
      final file = await _mapService.localFile(mapName);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      if (!exists || size == 0) {
        _lastError = 'نقشهٔ آفلاین نصب نشده است.';
        return false;
      }
      // Read/validate the canonical SQLite payload before declaring routing
      // ready. This also repairs legacy caches that were marked valid before
      // integrity/graph validation completed.
      final id = mapName.toLowerCase().endsWith('.abm')
          ? mapName.substring(0, mapName.length - 4)
          : mapName;
      final artifacts = await _vectorMaps.prepare(containerFile: file, id: id);
      _lastError = null;
      return true;
    } catch (error, stack) {
      _lastError = 'نقشهٔ آفلاین قابل استفاده نیست.';
      return false;
    }
  }

  @override
  Future<RouteInfo?> calculateRoute({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    int routeMode = 0,
  }) async =>
      (await _routeWithEdges(
        origin: origin,
        destination: destination,
        offlineOnly: offlineOnly,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
      ))
          ?.info;

  Future<({RouteInfo info, List<routing_engine_lib.RouteEdgeInfo> edges})?>
      _routeWithEdges({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    int routeMode = 0,
    Map<int, double>? wayPenalty,
  }) async {
    _lastError = null;
    try {
      final container = await _mapService.localFile(mapName);
      final exists = await container.exists();
      final size = exists ? await container.length() : 0;
      if (!exists || size == 0) {
        _lastError = 'نقشهٔ آفلاین نصب نشده است.';
        return null;
      }
      final id = mapName.toLowerCase().endsWith('.abm')
          ? mapName.substring(0, mapName.length - 4)
          : mapName;
      final artifacts = await _vectorMaps.prepare(containerFile: container, id: id);
      final result = await _engine.routeDetailed(
        artifacts.sqliteFile,
        routing_engine_lib.RoutePoint(origin.latitude, origin.longitude),
        routing_engine_lib.RoutePoint(destination.latitude, destination.longitude),
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
        wayPenalty: wayPenalty,
      );
      if (result == null) {
        _lastError = 'برای این مبدأ و مقصد مسیر قابل دسترسی پیدا نشد.';
        return null;
      }
      for (final line in result.diagnostics) {
      }
      // Only the first edges are logged: a long route has thousands of edges
      // and they would push every other diagnostic line out of the log.
      for (var i = 0; i < result.edges.length && i < 40; i++) {
        final e = result.edges[i];
      }
      if (result.points.length < 2) {
        _lastError = 'برای این مبدأ و مقصد مسیر قابل دسترسی پیدا نشد.';
        return null;
      }
      final geometry = result.points
          .map((p) => LatLng(p.lat, p.lon))
          .toList(growable: false);
      final distanceKm = _distanceKm(result.points);
      final durationMin = _estimateDurationMinutes(result);
      final instructions = _buildInstructions(result, geometry);
      final alerts = await RoadSafetyService.routeAlertsOffline(
        artifacts.sqliteFile.path,
        geometry,
      );
      return (
        info: RouteInfo(
          geometry: geometry,
          distanceKm: distanceKm,
          durationMin: durationMin,
          instructions: instructions,
          alerts: alerts,
        ),
        edges: result.edges,
      );
    } catch (error, stack) {
      _lastError = 'مسیریابی آفلاین با دادهٔ این نقشه ممکن نیست.';
      return null;
    }
  }

  /// مسیر اصلی + حداکثر دو مسیر جایگزین واقعی (آفلاین).
  /// هر جایگزین با همان A* ولی با هزینهٔ بالاتر برای خیابان‌های مسیرهای قبلی
  /// محاسبه می‌شود؛ ابتدا/انتهای مسیر (حدود ۱٫۵ کیلومتر) جریمه نمی‌شود تا
  /// همه از مبدأ شروع و به مقصد ختم شوند. مسیرهای شبیه یا خیلی دور حذف می‌شوند.
  Future<List<RouteInfo>> calculateRoutes({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    int routeMode = 0,
  }) async {
    var last = const <RouteInfo>[];
    await for (final routes in calculateRoutesStream(
      origin: origin,
      destination: destination,
      offlineOnly: offlineOnly,
      avoidUnpavedRoads: avoidUnpavedRoads,
      avoidTolls: avoidTolls,
      avoidTrafficZones: avoidTrafficZones,
      avoidHighways: avoidHighways,
      routeMode: routeMode,
    )) {
      last = routes;
    }
    return last;
  }

  Stream<List<RouteInfo>> calculateRoutesStream({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    int routeMode = 0,
  }) async* {
    final clock = Stopwatch()..start();
    final first = await _routeWithEdges(
      origin: origin,
      destination: destination,
      offlineOnly: offlineOnly,
      avoidUnpavedRoads: avoidUnpavedRoads,
      avoidTolls: avoidTolls,
      avoidTrafficZones: avoidTrafficZones,
      avoidHighways: avoidHighways,
        routeMode: routeMode,
    );
    if (first == null) return;
    final routes = <RouteInfo>[first.info];
    // مسیر اصلی فوراً نشان داده می‌شود؛ جایگزین‌ها بعداً و در پس‌زمینه می‌رسند.
    yield List<RouteInfo>.of(routes);
    // Alternatives are a bonus: never make the user wait for several more full
    // searches. If the main route was slow, skip them; otherwise cap both the
    // number of attempts and the total time.
    final firstMs = clock.elapsedMilliseconds;
    if (firstMs > 6000) {
      return;
    }
    final usedWays = <int>{for (final e in first.edges) e.wayId};
    final penalty = <int, double>{};
    void addPenalty(List<routing_engine_lib.RouteEdgeInfo> edges) {
      var total = 0.0;
      final lens = <double>[];
      for (final e in edges) {
        final m = _distanceKm([e.from, e.to]) * 1000;
        lens.add(m);
        total += m;
      }
      if (total < 600) return;
      final margin = math.min(1500.0, total * 0.2);
      var at = 0.0;
      for (var i = 0; i < edges.length; i++) {
        final mid = at + lens[i] / 2;
        at += lens[i];
        if (mid < margin || mid > total - margin) continue;
        final w = edges[i].wayId;
        penalty[w] = math.min(8.0, (penalty[w] ?? 1.0) * 2.0);
      }
    }

    addPenalty(first.edges);
    if (penalty.isEmpty) return;
    for (var attempt = 0; attempt < 3 && routes.length < 3; attempt++) {
      if (clock.elapsedMilliseconds > 15000) break;
      final alt = await _routeWithEdges(
        origin: origin,
        destination: destination,
        offlineOnly: offlineOnly,
        avoidUnpavedRoads: avoidUnpavedRoads,
        avoidTolls: avoidTolls,
        avoidTrafficZones: avoidTrafficZones,
        avoidHighways: avoidHighways,
        routeMode: routeMode,
        wayPenalty: penalty,
      );
      if (alt == null || alt.info.geometry.length < 2) break;
      var shared = 0.0, total = 0.0;
      for (final e in alt.edges) {
        final m = _distanceKm([e.from, e.to]) * 1000;
        total += m;
        if (usedWays.contains(e.wayId)) shared += m;
      }
      final similar = total <= 0 || shared / total > 0.85;
      final tooLong = alt.info.distanceKm > first.info.distanceKm * 1.6 + 3 ||
          alt.info.durationMin > first.info.durationMin * 1.7 + 5;
      addPenalty(alt.edges);
      if (similar || tooLong) continue;
      usedWays.addAll(alt.edges.map((e) => e.wayId));
      routes.add(alt.info);
      yield List<RouteInfo>.of(routes);
    }
  }

  List<RouteInstruction> _buildInstructions(
      routing_engine_lib.AbmRouteResult result, List<LatLng> geometry) {
    if (geometry.length < 2 || result.edges.isEmpty) {
      return [RouteInstruction(
        text: RoutingInstructionLocalizer.text(
            languageCode: languageCode(), type: 'depart', modifier: null,
            roadName: null, exit: null),
        distanceMeters: 0,
        location: geometry.first,
        type: 'depart',
      )];
    }

    final out = <RouteInstruction>[];
    final language = languageCode();
    double travelled = 0;
    out.add(RouteInstruction(
      text: RoutingInstructionLocalizer.text(
          languageCode: language, type: 'depart', modifier: null,
          roadName: result.edges.first.name.isEmpty ? null : result.edges.first.name,
          exit: null),
      distanceMeters: 0,
      location: geometry.first,
      type: 'depart',
    ));

    // زاویهٔ پیچ از «هندسهٔ واقعی مسیر» (~۲۲ متر قبل و بعد از تقاطع) محاسبه
    // می‌شود، نه از خط مستقیم ابتدا→انتهای یال‌های گراف. یال‌ها می‌توانند
    // بلند یا خمیده باشند و زاویهٔ پیچ ۹۰° یا دوربرگردان را «پیچ مایل» نشان
    // می‌دادند.
    var geoCursor = 0;
    double? geometryDelta(routing_engine_lib.RoutePoint at) {
      final end = math.min(geometry.length, geoCursor + 600);
      var best = -1;
      var bestD = double.infinity;
      for (var k = geoCursor; k < end; k++) {
        final d = _distance(
            at, routing_engine_lib.RoutePoint(geometry[k].latitude, geometry[k].longitude));
        if (d < bestD) {
          bestD = d;
          best = k;
          if (d < 0.5) break;
        }
      }
      if (best <= 0 || best >= geometry.length - 1 || bestD > 25) return null;
      geoCursor = best;
      routing_engine_lib.RoutePoint pt(int k) =>
          routing_engine_lib.RoutePoint(geometry[k].latitude, geometry[k].longitude);
      final center = pt(best);
      var back = best;
      var acc = 0.0;
      while (back > 0 && acc < 22) {
        acc += _distance(pt(back - 1), pt(back));
        back--;
      }
      var fwd = best;
      var accF = 0.0;
      while (fwd < geometry.length - 1 && accF < 22) {
        accF += _distance(pt(fwd), pt(fwd + 1));
        fwd++;
      }
      if (acc < 3 || accF < 3) return null;
      return _signedAngle(_bearing(center, pt(fwd)) - _bearing(pt(back), center));
    }

    var i = 1;
    var previousDistanceAlreadyAdded = false;
    while (i < result.edges.length) {
      final prev = result.edges[i - 1];
      final cur = result.edges[i];

      // A roundabout is one maneuver, not a sequence of ordinary turns.
      // Consume the whole roundabout at once so the card can use the exact
      // branch geometry/exit metadata calculated from province-specific SQLite.
      if (cur.junction.trim().toLowerCase() == 'roundabout') {
        if (!previousDistanceAlreadyAdded) {
          travelled += _distance(prev.from, prev.to);
        }
        final begin = i;
        var end = i;
        while (end < result.edges.length &&
            result.edges[end].junction.trim().toLowerCase() == 'roundabout') {
          end++;
        }
        final rb = result.edges[begin];
        final exitNode = result.edges[end - 1].to;
        final roadName = end < result.edges.length && result.edges[end].name.isNotEmpty
            ? result.edges[end].name
            : null;
        out.add(RouteInstruction(
          text: RoutingInstructionLocalizer.text(
            languageCode: language,
            type: 'roundabout',
            modifier: null,
            roadName: roadName,
            exit: rb.roundaboutExitNumber,
          ),
          distanceMeters: travelled,
          location: LatLng(rb.from.lat, rb.from.lon),
          type: 'roundabout',
          exit: rb.roundaboutExitNumber,
          roundaboutExitCount: rb.roundaboutExitCount,
          roundaboutBranchAngles: [
            for (final branch in rb.roundaboutBranches) branch.angleDegrees,
          ],
          roundaboutEntranceAngles: rb.roundaboutEntranceAngles,
          roundaboutExitAngles: rb.roundaboutExitAngles,
          roundaboutActiveExitAngle: rb.roundaboutActiveExitAngle,
          roundaboutAngleDegrees: rb.roundaboutActiveEntranceAngle,
          maneuverEndLocation: LatLng(exitNode.lat, exitNode.lon),
        ));

        // Consume the distance of every roundabout edge exactly once.
        for (var k = begin; k < end; k++) {
          travelled += _distance(result.edges[k].from, result.edges[k].to);
        }
        i = end;
        previousDistanceAlreadyAdded = true;
        continue;
      }

      if (!previousDistanceAlreadyAdded) {
        travelled += _distance(prev.from, prev.to);
      }
      previousDistanceAlreadyAdded = false;
      final delta = geometryDelta(cur.from) ??
          _signedAngle(
            _bearing(cur.from, cur.to) - _bearing(prev.from, prev.to),
          );
      final junctionChanged = prev.wayId != cur.wayId ||
          prev.name != cur.name ||
          prev.roadClass != cur.roadClass;
      var modifier = _modifierForDelta(delta, junctionChanged: junctionChanged);
      // ورود/خروج بزرگراه: تغییر کلاس جاده از/به motorway/trunk (یا _link).
      bool hw(String c) => c.startsWith('motorway') || c.startsWith('trunk');
      bool isLink(String c) => c.endsWith('_link');
      final pc = prev.roadClass.toLowerCase();
      final cc = cur.roadClass.toLowerCase();
      String? ramp;
      if (!hw(pc) && hw(cc)) {
        ramp = 'on ramp';
      } else if (hw(pc) && !isLink(pc) && (isLink(cc) || !hw(cc))) {
        ramp = 'off ramp';
      }
      if (ramp != null && modifier == 'straight') {
        // شیب خیلی کم: جهت را از علامت زاویه بگیر؛ در ترافیک راست‌گرد (ایران)
        // پیش‌فرض خروجی/ورودی سمت راست است.
        modifier = delta < -3 ? 'slight left' : 'slight right';
      }
      if (ramp != null || junctionChanged || modifier != 'straight') {
        out.add(RouteInstruction(
          text: RoutingInstructionLocalizer.text(
            languageCode: language,
            type: ramp ?? 'turn',
            modifier: modifier,
            roadName: cur.name.isEmpty ? null : cur.name,
            exit: null,
          ),
          distanceMeters: travelled,
          location: LatLng(cur.from.lat, cur.from.lon),
          type: ramp ?? (modifier == 'uturn' ? 'uturn' : 'turn'),
          modifier: modifier,
          maneuverAngleDegrees: delta,
        ));
      }
      i++;
    }

    // Add the final edge to the total route distance. The last roundabout edge
    // is already included by the roundabout block above; this loop deliberately
    // sums every edge once so the destination ETA remains consistent.
    var total = 0.0;
    for (final edge in result.edges) {
      total += _distance(edge.from, edge.to);
    }
    out.add(RouteInstruction(
      text: RoutingInstructionLocalizer.text(
          languageCode: language, type: 'arrive', modifier: null,
          roadName: null, exit: null),
      distanceMeters: total,
      location: geometry.last,
      type: 'arrive',
    ));
    return out;
  }

  String _modifierForDelta(double delta, {bool junctionChanged = false}) {
    final a = delta.abs();
    // A U-turn is a maneuver class of its own. Do not force it into
    // left/right: near 180° the sign is numerically unstable and was the
    // reason genuine U-turns were sometimes rendered as ordinary turns.
    // Reserve U-turn for a genuinely reversed heading. A 135° bend can be a
    // sharp ramp/underpass exit and must remain a turn rather than a U-turn.
    if (a >= 150) return 'uturn';
    if (!junctionChanged && a < 55) {
      // همین خیابان (همان way در گراف مسیریابی) ادامه دارد. هر انحنای طبیعیِ
      // خودِ خیابان (پیچ ملایم یک بلوار، مسیر یک جادهٔ کوهستانی و مانند آن)
      // اینجا نادیده گرفته می‌شود؛ این صرفاً هندسهٔ جاده است، نه یک تصمیم
      // ناوبری. اگر واقعاً باید مسیر عوض شود (تغییر مسیر، خروجی، دوربرگردان
      // در تقاطع)، way/نام/کلاس جاده هم در گراف عوض می‌شود و junctionChanged
      // به‌صورت جداگانه true می‌شود؛ فقط آنجا فلش رسم می‌شود.
      return 'straight';
    }
    if (a >= 120) return delta > 0 ? 'sharp right' : 'sharp left';
    if (a >= 55) return delta > 0 ? 'right' : 'left';
    // A junction that changes way/road but bends only a few degrees is still
    // an actual slight turn. The old 20° threshold made bridge ramps and
    // shallow main-street exits look like a straight-through maneuver.
    if (a >= 10) {
      return delta > 0 ? 'slight right' : 'slight left';
    }
    return 'straight';
  }
  double _bearing(routing_engine_lib.RoutePoint a, routing_engine_lib.RoutePoint b) {
    final lat1 = a.lat * math.pi / 180, lat2 = b.lat * math.pi / 180, dl = (b.lon - a.lon) * math.pi / 180;
    final y = math.sin(dl) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
  double _signedAngle(double angle) { var a = angle % 360; if (a > 180) a -= 360; if (a < -180) a += 360; return a; }
  double _estimateDurationMinutes(routing_engine_lib.AbmRouteResult result) {
    double seconds = 0;
    for (final e in result.edges) {
      final meters = _distance(e.from, e.to);
      final speed = (e.speedKmh ?? switch (e.roadClass) {
        'motorway' => 110.0, 'trunk' => 90.0, 'primary' => 70.0,
        'secondary' => 60.0, 'tertiary' => 50.0, 'residential' => 30.0, _ => 35.0,
      }).clamp(5.0, 160.0);
      seconds += meters / (speed / 3.6);
    }
    return seconds / 60;
  }
  double _distance(routing_engine_lib.RoutePoint a, routing_engine_lib.RoutePoint b) {
    const r = 6371008.8;
    final p1 = a.lat * math.pi / 180, p2 = b.lat * math.pi / 180;
    final dp = (b.lat - a.lat) * math.pi / 180, dl = (b.lon - a.lon) * math.pi / 180;
    final h = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }
  double _distanceKm(List<routing_engine_lib.RoutePoint> points) {
    double m = 0;
    for (var i = 1; i < points.length; i++) m += _distance(points[i - 1], points[i]);
    return m / 1000;
  }
}
