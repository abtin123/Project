import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../core/geo/geo_types.dart';
import '../../offline_maps/data/vector_map_service.dart';
import 'routing_service.dart';

/// هشدارهای جاده‌ای مستقل از «مسیر انتخاب‌شده».
/// این لایه عمداً جدا از RouteInfo است تا دوربین/سرعت‌گیر/چراغ و محدودیت
/// سرعت هم در حالت بدون مقصد و هم در حالت ناوبری قابل استفاده باشند.
class RoadSafetySnapshot {
  const RoadSafetySnapshot({
    this.alerts = const [],
    this.speedLimitKmh,
    this.roadHeadingDeg,
    this.roadMatchedPosition,
  });

  final List<RouteAlert> alerts;
  final int? speedLimitKmh;
  final double? roadHeadingDeg;
  final LatLng? roadMatchedPosition;
}

class RoadSafetyService {
  RoadSafetyService({http.Client? client, VectorMapService? vectorMapService})
      : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _vectorMaps = vectorMapService ?? VectorMapService();

  final VectorMapService _vectorMaps;

  static const String _overpassEndpoint =
      'https://overpass-api.de/api/interpreter';
  static const Duration _requestTimeout = Duration(seconds: 10);

  final http.Client _client;
  final bool _ownsClient;

  DateTime? _lastOnlineRequest;
  LatLng? _lastOnlineCenter;
  RoadSafetySnapshot _onlineCache = const RoadSafetySnapshot();

  Future<RoadSafetySnapshot> online(LatLng center,
      {double radiusM = 450, double? preferredHeadingDeg}) async {
    final lastCenter = _lastOnlineCenter;
    if (_lastOnlineRequest != null &&
        DateTime.now().difference(_lastOnlineRequest!) <
            const Duration(seconds: 20) &&
        lastCenter != null &&
        _distanceM(center, lastCenter) < 120) {
      return _onlineCache;
    }

    final lat = center.latitude.toStringAsFixed(6);
    final lon = center.longitude.toStringAsFixed(6);
    final radius = radiusM.round();
    final query = '''[out:json][timeout:8];
(
  node(around:$radius,$lat,$lon)["highway"="speed_camera"];
  node(around:$radius,$lat,$lon)["enforcement"="maxspeed"];
  node(around:$radius,$lat,$lon)["traffic_calming"];
  node(around:$radius,$lat,$lon)["highway"="traffic_signals"];
  node(around:$radius,$lat,$lon)["amenity"="police"];
  way(around:$radius,$lat,$lon)["highway"];
);
out geom;''';

    try {
      final response = await _client.post(
        Uri.parse(_overpassEndpoint),
        headers: const {
          'User-Agent': 'AbtinMaps/0.1 (road-safety)',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'Accept': 'application/json',
        },
        body: {'data': query},
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) return _onlineCache;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return _onlineCache;
      final elements = decoded['elements'];
      if (elements is! List) return _onlineCache;

      final alerts = <RouteAlert>[];
      final speedCandidates = <({int speed, double distance})>[];
      final headingCandidates = <({double heading, double distance})>[];
      ({LatLng point, double distance, double heading})? nearestRoad;
      for (final raw in elements) {
        if (raw is! Map) continue;
        final e = Map<String, dynamic>.from(raw);
        final tags = e['tags'] is Map
            ? Map<String, dynamic>.from(e['tags'] as Map)
            : const <String, dynamic>{};
        final point = _elementPoint(e);
        if (point == null) continue;
        final distance = _distanceM(center, point);

        final highway = tags['highway']?.toString();
        final calming = tags['traffic_calming']?.toString();
        final amenity = tags['amenity']?.toString();
        final enforcement = tags['enforcement']?.toString();
        if (highway == 'speed_camera' || enforcement == 'maxspeed') {
          alerts.add(RouteAlert(
            type: RouteAlertType.speedCamera,
            location: point,
            name: tags['name:fa']?.toString() ?? tags['name']?.toString(),
          ));
        } else if (calming != null) {
          alerts.add(RouteAlert(
            type: RouteAlertType.speedBump,
            location: point,
            name: tags['name:fa']?.toString() ?? tags['name']?.toString(),
          ));
        } else if (highway == 'traffic_signals') {
          alerts.add(RouteAlert(
            type: RouteAlertType.trafficLight,
            location: point,
            name: tags['name:fa']?.toString() ?? tags['name']?.toString(),
          ));
        } else if (amenity == 'police') {
          alerts.add(RouteAlert(
            type: RouteAlertType.policeCheckpoint,
            location: point,
            name: tags['name:fa']?.toString() ?? tags['name']?.toString(),
          ));
        }

        final geometry = e['geometry'];
        var wayDistance = distance;
        if (geometry is List && geometry.length >= 2) {
          for (var i = 1; i < geometry.length; i++) {
            final ga = geometry[i - 1];
            final gb = geometry[i];
            if (ga is! Map || gb is! Map) continue;
            final a = _elementPoint(Map<String, dynamic>.from(ga));
            final b = _elementPoint(Map<String, dynamic>.from(gb));
            if (a == null || b == null) continue;
            final segmentDistance = _distanceToSegmentM(center, a, b);
            wayDistance = math.min(wayDistance, segmentDistance);
            final bearing = _bearing(a, b);
            headingCandidates
                .add((heading: bearing, distance: segmentDistance));
            if (nearestRoad == null || segmentDistance < nearestRoad.distance) {
              final projected = _projectSegment(center, a, b);
              nearestRoad = (
                point: projected.point,
                distance: segmentDistance,
                heading: bearing,
              );
            }
          }
        }
        final speed = _parseSpeed(tags['maxspeed']);
        if (speed != null) {
          speedCandidates.add((speed: speed, distance: wayDistance));
        }
      }
      speedCandidates.sort((a, b) => a.distance.compareTo(b.distance));
      final roadHeading =
          _chooseHeading(headingCandidates, preferredHeadingDeg);
      alerts.sort((a, b) => _distanceM(center, a.location)
          .compareTo(_distanceM(center, b.location)));
      final uniqueAlerts = <RouteAlert>[];
      for (final alert in alerts) {
        if (uniqueAlerts.every((x) =>
            x.type != alert.type ||
            _distanceM(x.location, alert.location) > 40)) {
          uniqueAlerts.add(alert);
        }
      }
      _onlineCache = RoadSafetySnapshot(
        alerts: List.unmodifiable(uniqueAlerts),
        speedLimitKmh:
            speedCandidates.isEmpty ? null : speedCandidates.first.speed,
        roadHeadingDeg: roadHeading,
        roadMatchedPosition: nearestRoad != null && nearestRoad.distance <= 35.0
            ? nearestRoad.point
            : null,
      );
      _lastOnlineCenter = center;
      _lastOnlineRequest = DateTime.now();
      return _onlineCache;
    } catch (_) {
      return _onlineCache;
    }
  }

  LatLng? _elementPoint(Map<String, dynamic> e) {
    final lat = _asDouble(e['lat']);
    final lon = _asDouble(e['lon']);
    if (lat != null && lon != null) return LatLng(lat, lon);
    final center = e['center'];
    if (center is Map) {
      final c = Map<String, dynamic>.from(center);
      final clat = _asDouble(c['lat']);
      final clon = _asDouble(c['lon']);
      if (clat != null && clon != null) return LatLng(clat, clon);
    }
    return null;
  }

  DateTime? _lastOfflineRequest;
  LatLng? _lastOfflineCenter;
  RoadSafetySnapshot _offlineCache = const RoadSafetySnapshot();

  /// Offline road-safety: speed limit (nearest road's `way_data.speed_kmh`,
  /// already present in every already-built map.sqlite) plus speed-camera /
  /// speed-bump / traffic-signal / police-checkpoint alerts (POI rows whose
  /// `categories.name` is `speed_camera`, `traffic_calming`, `traffic_signals`
  /// or `police`). `police` is already extracted by every existing build;
  /// the other three category names are extracted by the builder's `pois()`
  /// starting with this update, so a map built/downloaded before it will
  /// only show the speed limit and police markers until it is rebuilt and
  /// re-downloaded — never a network request either way.
  Future<RoadSafetySnapshot> offline(
    File mapFile,
    LatLng center, {
    double radiusM = 450,
    double? preferredHeadingDeg,
  }) async {
    final lastCenter = _lastOfflineCenter;
    if (_lastOfflineRequest != null &&
        DateTime.now().difference(_lastOfflineRequest!) <
            const Duration(seconds: 8) &&
        lastCenter != null &&
        _distanceM(center, lastCenter) < 70) {
      return _offlineCache;
    }
    try {
      if (!await mapFile.exists() || await mapFile.length() == 0) {
        return const RoadSafetySnapshot();
      }
      final id = p.basenameWithoutExtension(mapFile.path).toUpperCase();
      final artifacts =
          await _vectorMaps.prepare(containerFile: mapFile, id: id);
      final snapshot = await Isolate.run(() => _offlineSync(
            artifacts.sqliteFile.path,
            center.latitude,
            center.longitude,
            radiusM,
            preferredHeadingDeg,
          ));
      _offlineCache = snapshot;
      _lastOfflineCenter = center;
      _lastOfflineRequest = DateTime.now();
      return snapshot;
    } catch (_) {
      return _offlineCache;
    }
  }

  static RoadSafetySnapshot _offlineSync(
    String sqlitePath,
    double centerLat,
    double centerLng,
    double radiusM,
    double? preferredHeadingDeg,
  ) {
    final center = LatLng(centerLat, centerLng);
    final db = sqlite.sqlite3.open(sqlitePath, mode: sqlite.OpenMode.readOnly);
    try {
      final latDeg = radiusM / 110540.0;
      final lonDeg =
          radiusM / (111320.0 * math.cos(centerLat * math.pi / 180).abs().clamp(0.05, 1.0));
      final minLat = centerLat - latDeg, maxLat = centerLat + latDeg;
      final minLon = centerLng - lonDeg, maxLon = centerLng + lonDeg;

      // نزدیک‌ترین قطعه‌ی جاده برای محدودیت سرعت و جهت جاده.
      int? speedLimit;
      double? roadHeading;
      LatLng? roadMatchedPosition;
      try {
        final roadRows = db.select(
          'SELECT s.a,s.b,w.speed_kmh,na.lat_e7 alat,na.lon_e7 alon,nb.lat_e7 blat,nb.lon_e7 blon '
          'FROM road_index r JOIN segments s ON s.id BETWEEN r.seg_from AND r.seg_to '
          'JOIN way_data w ON w.way_id=s.way_id '
          'JOIN node_data na ON na.id=s.a JOIN node_data nb ON nb.id=s.b '
          'WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=? LIMIT 600',
          [minLon, maxLon, minLat, maxLat],
        );
        double bestDistance = double.infinity;
        for (final r in roadRows) {
          final a = LatLng((r['alat'] as num).toDouble() * 1e-7,
              (r['alon'] as num).toDouble() * 1e-7);
          final b = LatLng((r['blat'] as num).toDouble() * 1e-7,
              (r['blon'] as num).toDouble() * 1e-7);
          final distance = _segmentDistanceM(center, a, b);
          if (distance < bestDistance) {
            bestDistance = distance;
            speedLimit = (r['speed_kmh'] as num?)?.toInt();
            roadHeading = _bearingStatic(a, b);
            if (distance <= 35.0) {
              roadMatchedPosition = _projectSegmentStatic(center, a, b);
            }
          }
        }
      } catch (_) {
        // road_index/segments may be missing on a graph-less/legacy ABM.
      }

      // دوربین/سرعت‌گیر/چراغ‌راهنمایی/ایست‌بازرسی نزدیک، از جدول POI همان استان.
      final alerts = <RouteAlert>[];
      try {
        const categoryToAlert = <String, RouteAlertType>{
          'speed_camera': RouteAlertType.speedCamera,
          'traffic_calming': RouteAlertType.speedBump,
          'traffic_signals': RouteAlertType.trafficLight,
          'police': RouteAlertType.policeCheckpoint,
        };
        final poiRows = db.select(
          'SELECT c.name category, n.name, n.name_fa, p.lat, p.lon '
          'FROM spatial s JOIN features f ON f.id=s.id '
          'JOIN categories c ON c.id=f.category_id '
          'JOIN poi p ON p.id=f.id AND f.kind=0 '
          'LEFT JOIN names n ON n.id=f.name_id '
          "WHERE c.name IN ('speed_camera','traffic_calming','traffic_signals','police') "
          'AND s.max_lon>=? AND s.min_lon<=? AND s.max_lat>=? AND s.min_lat<=? LIMIT 300',
          [minLon, maxLon, minLat, maxLat],
        );
        for (final r in poiRows) {
          final type = categoryToAlert['${r['category']}'];
          if (type == null) continue;
          final lat = (r['lat'] as num?)?.toDouble();
          final lon = (r['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final point = LatLng(lat, lon);
          if (_haversineM(center, point) > radiusM) continue;
          final name = '${r['name_fa'] ?? ''}'.trim().isNotEmpty
              ? '${r['name_fa']}'.trim()
              : ('${r['name'] ?? ''}'.trim().isEmpty ? null : '${r['name']}'.trim());
          alerts.add(RouteAlert(type: type, location: point, name: name));
        }
      } catch (_) {
        // categories/features/poi may be missing on a routing-only ABM.
      }
      alerts.sort((a, b) =>
          _haversineM(center, a.location).compareTo(_haversineM(center, b.location)));
      final uniqueAlerts = <RouteAlert>[];
      for (final alert in alerts) {
        if (uniqueAlerts.every((x) =>
            x.type != alert.type || _haversineM(x.location, alert.location) > 40)) {
          uniqueAlerts.add(alert);
        }
      }

      return RoadSafetySnapshot(
        alerts: List.unmodifiable(uniqueAlerts),
        speedLimitKmh: speedLimit,
        roadHeadingDeg: roadHeading,
        roadMatchedPosition: roadMatchedPosition,
      );
    } finally {
      db.dispose();
    }
  }

  /// هشدارهای (دوربین/سرعت‌گیر/چراغ/پلیس) روی خودِ مسیرِ آفلاین؛ از POIهای
  /// همان map.sqlite، فقط نقاطی که حداکثر [corridorM] متر از خط مسیر فاصله دارند.
  /// نتیجه به‌ترتیبِ پیشرفت روی مسیر مرتب است.
  static Future<List<RouteAlert>> routeAlertsOffline(
    String sqlitePath,
    List<LatLng> geometry, {
    double corridorM = 35,
  }) async {
    if (geometry.length < 2) return const [];
    final flat = <double>[
      for (final g in geometry) ...[g.latitude, g.longitude],
    ];
    try {
      final rows = await Isolate.run(
          () => _routeAlertsSync(sqlitePath, flat, corridorM));
      return [
        for (final r in rows)
          RouteAlert(
            type: RouteAlertType.values[r.$1],
            location: LatLng(r.$2, r.$3),
            name: r.$4,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static List<(int, double, double, String?)> _routeAlertsSync(
    String sqlitePath,
    List<double> flat,
    double corridorM,
  ) {
    const typeByCategory = <String, RouteAlertType>{
      'speed_camera': RouteAlertType.speedCamera,
      'traffic_calming': RouteAlertType.speedBump,
      'traffic_signals': RouteAlertType.trafficLight,
      'police': RouteAlertType.policeCheckpoint,
    };
    final n = flat.length ~/ 2;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (var i = 0; i < n; i++) {
      final la = flat[2 * i], lo = flat[2 * i + 1];
      if (la < minLat) minLat = la;
      if (la > maxLat) maxLat = la;
      if (lo < minLon) minLon = lo;
      if (lo > maxLon) maxLon = lo;
    }
    final padLat = corridorM / 110540.0;
    final padLon = corridorM /
        (111320.0 * math.cos((minLat + maxLat) / 2 * math.pi / 180).abs().clamp(0.05, 1.0));
    minLat -= padLat; maxLat += padLat; minLon -= padLon; maxLon += padLon;

    final db = sqlite.sqlite3.open(sqlitePath, mode: sqlite.OpenMode.readOnly);
    try {
      final rows = db.select(
        'SELECT c.name category, n.name, n.name_fa, s.min_lat lat, s.min_lon lon '
        'FROM spatial s JOIN features f ON f.id=s.id AND f.kind=0 '
        'JOIN categories c ON c.id=f.category_id '
        'LEFT JOIN names n ON n.id=f.name_id '
        "WHERE c.name IN ('speed_camera','traffic_calming','traffic_signals','police') "
        'AND s.max_lon>=? AND s.min_lon<=? AND s.max_lat>=? AND s.min_lat<=? LIMIT 20000',
        [minLon, maxLon, minLat, maxLat],
      );
      final found = <({int type, double lat, double lon, String? name, double progress})>[];
      for (final r in rows) {
        final type = typeByCategory['${r['category']}'];
        final lat = (r['lat'] as num?)?.toDouble();
        final lon = (r['lon'] as num?)?.toDouble();
        if (type == null || lat == null || lon == null) continue;
        final p = LatLng(lat, lon);
        final mx = 111320.0 * math.cos(lat * math.pi / 180);
        var best = double.infinity;
        var bestProgress = 0.0;
        var acc = 0.0;
        for (var i = 1; i < n; i++) {
          final a = LatLng(flat[2 * i - 2], flat[2 * i - 1]);
          final b = LatLng(flat[2 * i], flat[2 * i + 1]);
          final segLen = math.sqrt(
              math.pow((b.latitude - a.latitude) * 110540.0, 2) +
                  math.pow((b.longitude - a.longitude) * mx, 2));
          if (lat >= math.min(a.latitude, b.latitude) - padLat &&
              lat <= math.max(a.latitude, b.latitude) + padLat &&
              lon >= math.min(a.longitude, b.longitude) - padLon &&
              lon <= math.max(a.longitude, b.longitude) + padLon) {
            final d = _segmentDistanceM(p, a, b);
            if (d < best) {
              best = d;
              final q = _projectSegmentStatic(p, a, b);
              final part = segLen <= 1e-6
                  ? 0.0
                  : _haversineM(a, q).clamp(0.0, segLen).toDouble();
              bestProgress = acc + part;
            }
          }
          acc += segLen;
        }
        if (best > corridorM) continue;
        final fa = '${r['name_fa'] ?? ''}'.trim();
        final nm = '${r['name'] ?? ''}'.trim();
        found.add((
          type: type.index,
          lat: lat,
          lon: lon,
          name: fa.isNotEmpty ? fa : (nm.isEmpty ? null : nm),
          progress: bestProgress,
        ));
      }
      found.sort((a, b) => a.progress.compareTo(b.progress));
      final out = <(int, double, double, String?)>[];
      for (final f in found) {
        final dup = out.any((o) =>
            o.$1 == f.type &&
            _haversineM(LatLng(o.$2, o.$3), LatLng(f.lat, f.lon)) <= 40);
        if (!dup) out.add((f.type, f.lat, f.lon, f.name));
      }
      return out;
    } finally {
      db.dispose();
    }
  }

  static double _haversineM(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aa = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }

  static double _segmentDistanceM(LatLng p, LatLng a, LatLng b) {
    final latRad = p.latitude * math.pi / 180;
    final mx = 111320.0 * math.cos(latRad);
    final ax = (a.longitude - p.longitude) * mx;
    final ay = (a.latitude - p.latitude) * 110540.0;
    final bx = (b.longitude - p.longitude) * mx;
    final by = (b.latitude - p.latitude) * 110540.0;
    final dx = bx - ax;
    final dy = by - ay;
    final len = dx * dx + dy * dy;
    if (len < 1e-9) return math.sqrt(ax * ax + ay * ay);
    final t = (-(ax * dx + ay * dy) / len).clamp(0.0, 1.0);
    final x = ax + dx * t;
    final y = ay + dy * t;
    return math.sqrt(x * x + y * y);
  }

  static LatLng _projectSegmentStatic(LatLng p, LatLng a, LatLng b) {
    final latRad = p.latitude * math.pi / 180;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final ax = (a.longitude - p.longitude) * mx;
    final ay = (a.latitude - p.latitude) * my;
    final bx = (b.longitude - p.longitude) * mx;
    final by = (b.latitude - p.latitude) * my;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 <= 1e-9
        ? 0.0
        : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  static double _bearingStatic(LatLng a, LatLng b) {
    final y = (b.longitude - a.longitude) *
        math.cos((a.latitude + b.latitude) * math.pi / 360.0);
    final x = b.latitude - a.latitude;
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  int? _parseSpeed(Object? value) {
    if (value == null) return null;
    final raw = value.toString().trim().toLowerCase();
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(raw);
    if (match == null) return null;
    final n = double.tryParse(match.group(1)!);
    if (n == null || !n.isFinite || n <= 0 || n > 250) return null;
    final kmh = raw.contains('mph') ? n * 1.609344 : n;
    return kmh.round().clamp(5, 250);
  }

  double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  double _distanceM(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aa = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }

  double _distanceToSegmentM(LatLng p, LatLng a, LatLng b) {
    final latRad = p.latitude * math.pi / 180;
    final mx = 111320.0 * math.cos(latRad);
    final ax = (a.longitude - p.longitude) * mx;
    final ay = (a.latitude - p.latitude) * 110540.0;
    final bx = (b.longitude - p.longitude) * mx;
    final by = (b.latitude - p.latitude) * 110540.0;
    final dx = bx - ax;
    final dy = by - ay;
    final len = dx * dx + dy * dy;
    if (len < 1e-9) return math.sqrt(ax * ax + ay * ay);
    final t = (-(ax * dx + ay * dy) / len).clamp(0.0, 1.0);
    final x = ax + dx * t;
    final y = ay + dy * t;
    return math.sqrt(x * x + y * y);
  }

  ({LatLng point, double t}) _projectSegment(LatLng p, LatLng a, LatLng b) {
    final latRad = p.latitude * math.pi / 180;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final ax = (a.longitude - p.longitude) * mx;
    final ay = (a.latitude - p.latitude) * my;
    final bx = (b.longitude - p.longitude) * mx;
    final by = (b.latitude - p.latitude) * my;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 <= 1e-9
        ? 0.0
        : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
    return (
      point: LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      ),
      t: t,
    );
  }

  double? _chooseHeading(
      List<({double heading, double distance})> candidates, double? preferred) {
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    if (preferred == null || !preferred.isFinite)
      return candidates.first.heading;
    final nearest = candidates.take(12).toList(growable: false);
    ({double heading, double distance})? best;
    var bestScore = double.infinity;
    for (final c in nearest) {
      final d = _angleDistance(c.heading, preferred);
      // Prefer a physically close road, but use GPS direction to choose the
      // correct direction on a two-way road. Both directions are equivalent
      // for the camera, so compare the 180-degree equivalent too.
      final score = c.distance + math.min(d, (180.0 - d).abs()) * 1.8;
      if (score < bestScore) {
        bestScore = score;
        best = c;
      }
    }
    final h = best?.heading;
    if (h == null) return null;
    // heading خیابان دوطرفه است؛ جهتی را برگردان که با حرکتِ واقعی هم‌سو باشد،
    // وگرنه ماشین ۱۸۰° برعکس (رو به عقب) رسم می‌شد.
    final flipped = (h + 180.0) % 360.0;
    return _angleDistance(flipped, preferred) < _angleDistance(h, preferred)
        ? flipped
        : h;
  }

  double _angleDistance(double a, double b) {
    final d = ((a - b + 540) % 360) - 180;
    return d.abs();
  }

  double _bearing(LatLng a, LatLng b) {
    final y = (b.longitude - a.longitude) *
        math.cos((a.latitude + b.latitude) * math.pi / 360.0);
    final x = b.latitude - a.latitude;
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
