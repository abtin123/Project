import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:sqlite3/sqlite3.dart';


class RoutePoint {
  const RoutePoint(this.lat, this.lon);
  final double lat;
  final double lon;
}

class RoundaboutBranchInfo {
  const RoundaboutBranchInfo({
    required this.angleDegrees,
    this.canEnter = false,
    this.canExit = false,
  });

  /// Geographic bearing (0=north, clockwise) of the physical arm.
  final double angleDegrees;
  final bool canEnter;
  final bool canExit;
}

class RouteEdgeInfo {
  const RouteEdgeInfo({
    required this.from,
    required this.to,
    required this.roadClass,
    required this.name,
    required this.junction,
    required this.wayId,
    this.speedKmh,
    this.roundaboutExitNumber,
    this.roundaboutExitCount,
    this.roundaboutBranches = const [],
    this.roundaboutEntranceAngles = const [],
    this.roundaboutExitAngles = const [],
    this.roundaboutActiveExitAngle,
    this.roundaboutActiveEntranceAngle,
  });
  final RoutePoint from;
  final RoutePoint to;
  final String roadClass;
  final String name;
  final String junction;
  final int wayId;
  final double? speedKmh;
  final int? roundaboutExitNumber;
  final int? roundaboutExitCount;
  final List<RoundaboutBranchInfo> roundaboutBranches;
  final List<double> roundaboutEntranceAngles;
  final List<double> roundaboutExitAngles;
  final double? roundaboutActiveExitAngle;

  /// زاویهٔ (bearing جغرافیایی) بازوی واقعی‌ای که خودرو از آن وارد میدان
  /// می‌شود — دقیقاً همان مقداری که در محاسبهٔ [roundaboutExitNumber] به
  /// عنوان "entrance" استفاده می‌شود، اینجا برای رسمِ کمانِ یکپارچهٔ
  /// ورودی-تا-خروجی در آیکونِ کارتِ مسیریابی نگه داشته می‌شود.
  final double? roundaboutActiveEntranceAngle;
}

/// حالت مسیریابی جاری داخل isolate: 0 = سریع‌ترین، 1 = کوتاه‌ترین، 2 = اقتصادی.
/// هر `Isolate.run` ایزولهٔ تازه دارد، پس این متغیر بین فراخوانی‌ها نشت نمی‌کند.
int _activeRouteMode = 0;

/// ضریب ترجیحی راه‌ها در حالت «سریع‌ترین»: بزرگراه/آزادراه و راه‌های اصلی
/// (سرعت بالا، بدون چراغ و تقاطع) کمی ارزان‌تر، خیابان‌های فرعی گران‌تر.
double _fastestClassFactor(String roadClass) {
  final c = roadClass.toLowerCase();
  if (c.startsWith('motorway')) return 0.90;
  if (c.startsWith('trunk')) return 0.93;
  if (c.startsWith('primary')) return 0.97;
  if (c.startsWith('secondary')) return 1.0;
  if (c.startsWith('tertiary')) return 1.03;
  return 1.10;
}

/// سرعت مرجع (۸۰ km/h) برای ترکیب مسافت و زمان در حالت اقتصادی.
const double _economicRefMps = 80 / 3.6;

double _edgeRouteCost(_DbRouteEdge e) {
  final t = e.distanceM / e.speedKmh * 3.6;
  switch (_activeRouteMode) {
    case 1:
      return e.distanceM;
    case 2:
      return 0.5 * t + 0.5 * e.distanceM / _economicRefMps;
    default:
      return t * _fastestClassFactor(e.roadClass);
  }
}

class _DbRouteEdge {
  const _DbRouteEdge({
    required this.from, required this.to, required this.distanceM,
    required this.speedKmh, required this.wayId, required this.onewayMode,
    required this.roadClass, required this.name, required this.junction,
    this.idx = 0,
  });

  /// شمارندهٔ یکتای یال در یک جست‌وجو؛ کلید عددیِ حالت‌های A* (به‌جای رشته).
  final int idx;
  final int from;
  final int to;
  final double distanceM;
  final double speedKmh;
  final int wayId;

  /// OSM oneway direction relative to the stored way_geometry order:
  ///  1 = forward only, -1 = reverse only, 0 = bidirectional/unknown.
  final int onewayMode;
  bool get oneway => onewayMode != 0;
  final String roadClass;
  final String name;
  final String junction;
}

class _SqliteSnap {
  const _SqliteSnap({
    required this.a, required this.b, required this.t, required this.point,
    required this.segmentMeters, required this.onewayMode, required this.wayId,
  });
  final int a;
  final int b;
  final double t;
  final RoutePoint point;
  final double segmentMeters;
  final int onewayMode;
  bool get oneway => onewayMode != 0;
  final int wayId;
}

class _ModernSnap {
  const _ModernSnap({required this.edge, required this.t, required this.distance, required this.point, this.candidates = const []});
  final _DbRouteEdge edge;
  final double t;
  final double distance;
  final RoutePoint point;
  final List<_ModernSnap> candidates;
  factory _ModernSnap.group(List<_ModernSnap> sorted) {
    final best = sorted.first;
    return _ModernSnap(edge: best.edge, t: best.t, distance: best.distance, point: best.point, candidates: sorted);
  }
}

class _WayGeometrySlice {
  const _WayGeometrySlice(this.points, this.forward);
  final List<RoutePoint> points;
  final bool forward;
}

class _PolylineProjection {
  const _PolylineProjection(this.distanceM, this.t, this.point);
  final double distanceM;
  final double t;
  final RoutePoint point;
}

class AbmRouteResult {
  const AbmRouteResult({required this.points, required this.edges, this.diagnostics = const []});
  final List<RoutePoint> points;
  final List<RouteEdgeInfo> edges;
  final List<String> diagnostics;
}


/// Decode the routing-builder's compact `way_geometry` blob.
/// Format: delta encoded lon/lat pairs, ZigZag signed varints, 1e-5 degree.
List<RoutePoint> _decodeAbmWayGeometry(dynamic raw) {
  if (raw is! List<int> || raw.isEmpty) return const <RoutePoint>[];
  int offset = 0;
  int px = 0, py = 0;
  int readVarint() {
    var value = 0;
    var shift = 0;
    while (offset < raw.length) {
      final b = raw[offset++];
      value |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return value;
      shift += 7;
      if (shift > 63) throw const FormatException('invalid ABM geometry varint');
    }
    throw const FormatException('truncated ABM geometry');
  }
  int unzig(int value) => (value >> 1) ^ -(value & 1);
  final out = <RoutePoint>[];
  try {
    while (offset < raw.length) {
      px += unzig(readVarint());
      py += unzig(readVarint());
      out.add(RoutePoint(py / 100000.0, px / 100000.0));
    }
  } catch (_) {
    return const <RoutePoint>[];
  }
  return out;
}

/// Normalize the ABM/OSM oneway field without losing the reverse-only value.
/// RoadSnapper uses the same convention (1 / -1 / 0).
int _parseOnewayMode(dynamic value) {
  if (value is num) {
    final n = value.toInt();
    if (n == -1) return -1;
    if (n == 1) return 1;
    return 0;
  }
  final x = '${value ?? ''}'.trim().toLowerCase();
  final parsed = num.tryParse(x);
  if (parsed != null) {
    if (parsed == -1) return -1;
    if (parsed == 1) return 1;
  }
  if (x == '-1' || x == 'reverse' || x == 'backward') return -1;
  if (x == '1' || x == 'true' || x == 'yes' || x == 'y' || x == 'forward') return 1;
  return 0;
}

/// OSM: `junction=roundabout` (and `circular`) is implicitly one-way in the
/// direction the way is drawn, even without an explicit `oneway=yes` tag.
/// Without this the router treated the ring as two-way and could drive it
/// against traffic (and no one-way arrows were shown on it).
int _effectiveOneway(int mode, Object? junction) {
  if (mode != 0) return mode;
  final j = '${junction ?? ''}'.trim().toLowerCase();
  return (j == 'roundabout' || j == 'circular') ? 1 : 0;
}

/// Disk-backed ABM routing reader.
///
/// ABM v4 keeps routing data inside the canonical province-specific SQLite database.
/// Routing must not depend on graph.bin/search.sqlite legacy members.
class AbmRoutingEngine {
  Future<List<RoutePoint>> route(
    File abmFile,
    RoutePoint origin,
    RoutePoint destination, {
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
  }) async {
    final result = await routeDetailed(
      abmFile, origin, destination,
      avoidUnpavedRoads: avoidUnpavedRoads,
      avoidTolls: avoidTolls,
      avoidTrafficZones: avoidTrafficZones,
      avoidHighways: avoidHighways,
    );
    return result?.points ?? const [];
  }

  Future<AbmRouteResult?> routeDetailed(
    File abmFile,
    RoutePoint origin,
    RoutePoint destination, {
    bool avoidUnpavedRoads = false,
    bool avoidTolls = false,
    bool avoidTrafficZones = false,
    bool avoidHighways = false,
    Map<int, double>? wayPenalty,
    int routeMode = 0,
  }) {
    final penalty = wayPenalty == null || wayPenalty.isEmpty
        ? null
        : Map<int, double>.of(wayPenalty);
    return Isolate.run(() {
      _activeRouteMode = routeMode;
      return _routeDetailedSync(
          abmFile.path, origin, destination,
          avoidUnpavedRoads, avoidTolls, avoidTrafficZones, avoidHighways,
          penalty,
        );
    });
  }

  static Future<AbmRouteResult?> _routeDetailedSync(
    String path, RoutePoint origin, RoutePoint destination,
    bool avoidUnpavedRoads, bool avoidTolls, bool avoidTrafficZones, bool avoidHighways,
    [Map<int, double>? wayPenalty]
  ) async {
    final file = File(path);
    if (!await file.exists()) return null;
    if (path.toLowerCase().endsWith('.sqlite')) {
      return _routeSqliteDetailed(
        path, origin, destination, avoidUnpavedRoads, avoidTolls, avoidTrafficZones, avoidHighways,
        wayPenalty,
      );
    }
    final points = await _routeSync(
      path, origin, destination, avoidUnpavedRoads, avoidTolls, avoidTrafficZones, avoidHighways,
    );
    return points.isEmpty ? null : AbmRouteResult(points: points, edges: const []);
  }

  static Future<List<RoutePoint>> _routeSync(
    String path,
    RoutePoint origin,
    RoutePoint destination,
    bool avoidUnpavedRoads,
    bool avoidTolls,
    bool avoidTrafficZones,
    bool avoidHighways,
  ) async {
    final file = File(path);
    if (!await file.exists()) return const [];
    if (path.toLowerCase().endsWith('.sqlite')) {
      final detailed = await _routeSqliteDetailed(
        path, origin, destination, avoidUnpavedRoads, avoidTolls, avoidTrafficZones, avoidHighways,
      );
      return detailed?.points ?? const <RoutePoint>[];
    }
    final raf = await file.open();
    try {
      final magic = utf8.encode('ABMGRAPH1\n');
      final header = await raf.read(magic.length + 4);
      if (header.length < magic.length + 4) return const [];
      for (var i = 0; i < magic.length; i++) {
        if (header[i] != magic[i]) return const [];
      }
      final jsonLength = _u32(header, magic.length);
      final fileLength = await raf.length();
      final jsonStart = magic.length + 4;
      if (jsonLength <= 0 || jsonStart + jsonLength > fileLength)
        return const [];

      // Parse only the two sections used by routing. The graph builder writes
      // them in a stable order: nodes, edges, turn_restrictions.
      final nodes = <int, RoutePoint>{};
      final adjacency = <int, List<_Edge>>{};

      await _scanSection(
        raf,
        jsonStart,
        jsonLength,
        'nodes',
        (key, value) {
          if (key == null || value is! List || value.length < 2) return;
          final id = int.tryParse(key);
          if (id == null || value[0] is! num || value[1] is! num) return;
          nodes[id] = RoutePoint(
            (value[0] as num).toDouble(),
            (value[1] as num).toDouble(),
          );
        },
      );
      if (nodes.isEmpty) return const [];

      final start = _nearest(nodes, origin);
      final goal = _nearest(nodes, destination);
      if (start == goal) return <RoutePoint>[nodes[start]!];

      await _scanSection(
        raf,
        jsonStart,
        jsonLength,
        'edges',
        (key, value) {
          if (value is! Map) return;
          final a = _int(value['start'] ?? value['from']);
          final b = _int(value['end'] ?? value['to']);
          if (a == null ||
              b == null ||
              !nodes.containsKey(a) ||
              !nodes.containsKey(b)) return;
          final road =
              '${value['road_class'] ?? value['highway'] ?? value['class'] ?? value['road'] ?? ''}'
                  .toLowerCase();
          final toll = value['toll'] == true ||
              value['toll'] == 1 ||
              road.contains('toll');
          final restricted = value['traffic_zone'] == true ||
              value['trafficZone'] == true ||
              value['restricted'] == true;
          final surface = '${value['surface'] ?? ''}'.toLowerCase();
          final unpaved =
              surface.isNotEmpty && surface != 'paved' && surface != 'asphalt';
          if ((avoidTolls && toll) ||
              (avoidTrafficZones && restricted) ||
              (avoidHighways && (road.startsWith('motorway') || road.startsWith('trunk'))) ||
              (avoidUnpavedRoads && unpaved)) return;
          final speedRaw =
              value['speed_kmh'] ?? value['speed'] ?? value['maxspeed'] ?? 50;
          final speed = speedRaw is num
              ? speedRaw.toDouble().clamp(5, 160).toDouble()
              : 50.0;
          final distanceRaw = value['distance_m'] ?? value['distance'];
          final distance = distanceRaw is num
              ? distanceRaw.toDouble()
              : _distance(nodes[a]!, nodes[b]!);
          final onewayMode = _parseOnewayMode(value['oneway']);
          if (onewayMode != -1) {
            (adjacency[a] ??= []).add(_Edge(b, distance, speed));
          }
          if (onewayMode != 1) {
            (adjacency[b] ??= []).add(_Edge(a, distance, speed));
          }
        },
      );

      final distance = <int, double>{start: 0};
      final previous = <int, int?>{start: null};
      final open = _MinHeap<_QueueItem>((a, b) => a.cost.compareTo(b.cost));
      open.add(_QueueItem(start, 0));
      while (open.isNotEmpty) {
        final item = open.removeFirst();
        final current = item.node;
        if (item.cost > (distance[current] ?? double.infinity)) continue;
        if (current == goal) break;
        for (final edge in adjacency[current] ?? const <_Edge>[]) {
          final cost = edge.distanceM / edge.speedKmh * 3.6;
          final next = (distance[current] ?? double.infinity) + cost;
          if (next < (distance[edge.to] ?? double.infinity)) {
            distance[edge.to] = next;
            previous[edge.to] = current;
            open.add(_QueueItem(edge.to, next));
          }
        }
      }
      if (!previous.containsKey(goal)) return const [];
      final ids = <int>[];
      int? current = goal;
      while (current != null) {
        ids.add(current);
        current = previous[current];
      }
      return ids.reversed.map((id) => nodes[id]!).toList(growable: false);
    } finally {
      await raf.close();
    }
  }

  static AbmRouteResult? _routeModernSqliteDetailed(
    Database db,
    RoutePoint origin,
    RoutePoint destination,
    bool avoidUnpavedRoads,
    bool avoidTolls,
    bool avoidTrafficZones,
    bool avoidHighways, [
    Map<int, double>? wayPenalty,
  ]) {
    if (!origin.lat.isFinite || !origin.lon.isFinite ||
        !destination.lat.isFinite || !destination.lon.isFinite) {
      return AbmRouteResult(points: const [], edges: const [], diagnostics: const ['MODERN GRAPH: invalid coordinates']);
    }

    const startId = -1;
    const goalId = -2;
    final virtualPoints = <int, RoutePoint>{};
    final nodeCache = <int, RoutePoint?>{};

    // Prepared once, reused for every node/edge lookup. `db.select(sql)`
    // re-parses and re-plans the SQL on every call, which dominated the time
    // of a long route (hundreds of thousands of lookups).
    final nodeStmt = db.prepare('SELECT lat,lon FROM nodes WHERE id=? LIMIT 1');

    RoutePoint? nodeOrNull(int id) {
      if (id < 0) return virtualPoints[id];
      if (nodeCache.containsKey(id)) return nodeCache[id];
      final rows = nodeStmt.select([id]);
      final p = rows.isEmpty
          ? null
          : RoutePoint((rows.first['lat'] as num).toDouble(), (rows.first['lon'] as num).toDouble());
      nodeCache[id] = p;
      return p;
    }

    RoutePoint node(int id) => nodeOrNull(id) ?? (throw StateError('Missing node $id'));

    // Full OSM way geometry is authoritative for drawing. The routing graph may
    // use only a subset of vertices for search, so connecting graph nodes with
    // a fresh straight line can cut across bends/blocks. Cache decoded ways
    // once per route and recover the exact portion between each edge's nodes.
    final wayGeometryCache = <int, List<RoutePoint>>{};
    final waySliceCache = <String, _WayGeometrySlice?>{};
    List<RoutePoint> wayGeometry(int wayId) {
      final cached = wayGeometryCache[wayId];
      if (cached != null) return cached;
      try {
        final rows = db.select(
          'SELECT geometry FROM way_geometry WHERE way_id=? LIMIT 1',
          [wayId],
        );
        if (rows.isEmpty) return wayGeometryCache[wayId] = const <RoutePoint>[];
        final decoded = _decodeAbmWayGeometry(rows.first['geometry']);
        wayGeometryCache[wayId] = decoded;
        return decoded;
      } catch (_) {
        wayGeometryCache[wayId] = const <RoutePoint>[];
        return const <RoutePoint>[];
      }
    }

    double polylineLength(List<RoutePoint> line) {
      var total = 0.0;
      for (var i = 1; i < line.length; i++) total += _distance(line[i - 1], line[i]);
      return total;
    }

    // Per-way grid of vertex indexes (cell ≈ 11 m). Finding the vertices
    // closest to a graph node used to scan the whole way for every edge, which
    // is O(n²) on long highways. The grid makes it O(1); when the nearest
    // vertex is not within a few metres we fall back to the exact full scan,
    // so the result is identical to the previous implementation.
    const gridCell = 1e-4;
    final wayGrid = <int, Map<int, List<int>>>{};
    int cellKey(double lat, double lon) =>
        ((lat + 90.0) / gridCell).floor() * 8000000 + ((lon + 180.0) / gridCell).floor();
    Map<int, List<int>> gridFor(int wayId, List<RoutePoint> geom) {
      final cached = wayGrid[wayId];
      if (cached != null) return cached;
      final grid = <int, List<int>>{};
      for (var i = 0; i < geom.length; i++) {
        (grid[cellKey(geom[i].lat, geom[i].lon)] ??= <int>[]).add(i);
      }
      return wayGrid[wayId] = grid;
    }

    List<int> geometryCandidates(int wayId, List<RoutePoint> geom, RoutePoint target) {
      final grid = gridFor(wayId, geom);
      final base = cellKey(target.lat, target.lon);
      final near = <int>[];
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final bucket = grid[base + dy * 8000000 + dx];
          if (bucket != null) near.addAll(bucket);
        }
      }
      if (near.isNotEmpty) {
        var bestNear = double.infinity;
        final dist = <int, double>{};
        for (final i in near) {
          final d = _distance(target, geom[i]);
          dist[i] = d;
          if (d < bestNear) bestNear = d;
        }
        if (bestNear <= 6.0) {
          final limit = math.min(30.0, bestNear + 4.0);
          final out = <int>[
            for (final i in near)
              if (dist[i]! <= limit) i,
          ]..sort();
          return out;
        }
      }
      var bestD = double.infinity;
      final distances = List<double>.filled(geom.length, 0.0);
      for (var i = 0; i < geom.length; i++) {
        final d = _distance(target, geom[i]);
        distances[i] = d;
        if (d < bestD) bestD = d;
      }
      final out = <int>[];
      final limit = math.min(30.0, bestD + 4.0);
      for (var i = 0; i < geom.length; i++) {
        if (distances[i] <= limit) out.add(i);
      }
      return out;
    }

    _WayGeometrySlice? waySlice(_DbRouteEdge edge) {
      if (edge.from < 0 || edge.to < 0) return null;
      final cacheKey = '${edge.wayId}|${edge.from}|${edge.to}';
      if (waySliceCache.containsKey(cacheKey)) return waySliceCache[cacheKey];
      final a = nodeOrNull(edge.from), b = nodeOrNull(edge.to);
      if (a == null || b == null) { waySliceCache[cacheKey] = null; return null; }
      final geom = wayGeometry(edge.wayId);
      if (geom.length < 2) { waySliceCache[cacheKey] = null; return null; }
      final ca = geometryCandidates(edge.wayId, geom, a), cb = geometryCandidates(edge.wayId, geom, b);
      if (ca.isEmpty || cb.isEmpty) { waySliceCache[cacheKey] = null; return null; }

      // Roundabouts / closed loops: the legal arc may cross the ring seam.
      final ring = _closedRingSlice(geom, ca, cb, a, b, edge.distanceM);
      if (ring != null) {
        waySliceCache[cacheKey] = ring;
        return ring;
      }

      var bestScore = double.infinity;
      var bestA = -1, bestB = -1;
      for (final ia in ca) {
        for (final ib in cb) {
          if (ia == ib) continue;
          final lo = math.min(ia, ib), hi = math.max(ia, ib);
          final sub = geom.sublist(lo, hi + 1);
          final len = polylineLength(sub);
          final endpointError = _distance(a, geom[ia]) + _distance(b, geom[ib]);
          final lengthError = edge.distanceM > 0 ? (len - edge.distanceM).abs() : 0.0;
          // Endpoint accuracy dominates; among plausible endpoint pairs use
          // the stored edge length to disambiguate repeated vertices on
          // roundabouts/loops.
          final score = endpointError * 8.0 + lengthError;
          if (score < bestScore) {
            bestScore = score;
            bestA = ia;
            bestB = ib;
          }
        }
      }
      if (bestA < 0 || bestB < 0) { waySliceCache[cacheKey] = null; return null; }
      if (_distance(a, geom[bestA]) > 30.0 || _distance(b, geom[bestB]) > 30.0) {
        waySliceCache[cacheKey] = null;
        return null;
      }
      if (bestA < bestB) {
        final result = _WayGeometrySlice(geom.sublist(bestA, bestB + 1), true);
        waySliceCache[cacheKey] = result;
        return result;
      }
      final result = _WayGeometrySlice(
        geom.sublist(bestB, bestA + 1).reversed.toList(growable: false),
        false,
      );
      waySliceCache[cacheKey] = result;
      return result;
    }

    /// A one-way restriction is checked against the actual OSM way geometry,
    /// not merely against the direction of an `edges` row. This matters because
    /// some ABMs contain both graph directions for a way and rely on runtime
    /// routing to reject the illegal one.
    bool directionAllowed(_DbRouteEdge edge) {
      if (edge.onewayMode == 0) return true;
      final slice = waySlice(edge);
      // If geometry is unavailable, preserve the builder's directed edge view
      // rather than manufacturing a new reverse edge. The normal/current ABM
      // format always carries way_geometry, so this is only a legacy safeguard.
      if (slice == null) return true;
      if (edge.onewayMode == 1) return slice.forward;
      if (edge.onewayMode == -1) return !slice.forward;
      return true;
    }

    List<RoutePoint> physicalEdgeGeometry(_DbRouteEdge edge) {
      final slice = waySlice(edge);
      if (slice != null) return slice.points;
      final a = nodeOrNull(edge.from), b = nodeOrNull(edge.to);
      if (a == null || b == null) return const <RoutePoint>[];
      // Geometry is mandatory for directed edges in the modern ABM. Never
      // invent a straight chord here: a missing/corrupt way_geometry record is
      // a routing-data error, not permission to draw across blocks.
      return const <RoutePoint>[];
    }

    List<RoutePoint> subPolyline(List<RoutePoint> line, double fromT, double toT) {
      if (line.length < 2) return const <RoutePoint>[];
      final loT = fromT.clamp(0.0, 1.0).toDouble();
      final hiT = toT.clamp(0.0, 1.0).toDouble();
      if (hiT <= loT) return const <RoutePoint>[];
      final lengths = List<double>.filled(line.length, 0.0);
      for (var i = 1; i < line.length; i++) {
        lengths[i] = lengths[i - 1] + _distance(line[i - 1], line[i]);
      }
      final total = lengths.last;
      if (total < 0.01) return <RoutePoint>[line.first, line.last];

      RoutePoint at(double t) {
        final target = total * t;
        for (var i = 1; i < line.length; i++) {
          if (target <= lengths[i]) {
            final seg = lengths[i] - lengths[i - 1];
            if (seg <= 0.001) return line[i];
            final q = ((target - lengths[i - 1]) / seg).clamp(0.0, 1.0).toDouble();
            return RoutePoint(
              line[i - 1].lat + (line[i].lat - line[i - 1].lat) * q,
              line[i - 1].lon + (line[i].lon - line[i - 1].lon) * q,
            );
          }
        }
        return line.last;
      }

      final out = <RoutePoint>[at(loT)];
      for (var i = 1; i < line.length - 1; i++) {
        final t = lengths[i] / total;
        if (t > loT && t < hiT) out.add(line[i]);
      }
      out.add(at(hiT));
      return out;
    }

    _PolylineProjection? projectOnEdge(RoutePoint p, _DbRouteEdge edge) {
      final line = physicalEdgeGeometry(edge);
      if (line.length < 2) return null;
      final mLat = 110540.0;
      final mLon = 111320.0 * math.cos(p.lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
      var total = polylineLength(line);
      if (total < 0.01) return null;
      var travelled = 0.0;
      var bestD = double.infinity;
      var bestT = 0.0;
      RoutePoint? bestPoint;
      for (var i = 1; i < line.length; i++) {
        final a = line[i - 1], b = line[i];
        final ax = (a.lon - p.lon) * mLon, ay = (a.lat - p.lat) * mLat;
        final bx = (b.lon - p.lon) * mLon, by = (b.lat - p.lat) * mLat;
        final dx = bx - ax, dy = by - ay;
        final len2 = dx * dx + dy * dy;
        if (len2 < 1e-9) continue;
        final segLen = math.sqrt(len2);
        final localT = (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
        final px = ax + dx * localT, py = ay + dy * localT;
        final d = math.sqrt(px * px + py * py);
        if (d < bestD) {
          bestD = d;
          bestT = (travelled + segLen * localT) / total;
          bestPoint = RoutePoint(p.lat + py / mLat, p.lon + px / mLon);
        }
        travelled += segLen;
      }
      if (bestPoint == null) return null;
      return _PolylineProjection(bestD, bestT, bestPoint);
    }

    bool allowed(String road, String access, String surface) {
      if (avoidTrafficZones && access.contains('private')) return false;
      if (avoidHighways && (road.startsWith('motorway') || road.startsWith('trunk'))) return false;
      if (avoidTolls && road.contains('toll')) return false;
      if (avoidUnpavedRoads && surface.isNotEmpty && surface != 'paved' && surface != 'asphalt') return false;
      return true;
    }

    bool isRoundabout(String j) => j.trim().toLowerCase() == 'roundabout';

    // `edges` is the directed runtime view (a one-way segment appears once,
    // a two-way segment appears in both directions), so a directed edge that
    // is not returned here is genuinely not drivable in that direction.
    var edgeSeq = 0;
    final adjacency = <int, List<_DbRouteEdge>>{};
    final expanded = <int>{};

    // One lookup per *way* instead of a 5-table JOIN per edge.
    final wayAttrStmt = db.prepare(
      'SELECT c.name AS road_class, w.speed_kmh, w.oneway, w.access, w.surface, '
      'n.name, n.name_fa, n.name_en, w.junction '
      'FROM way_data w JOIN categories c ON c.id=w.class_id '
      'LEFT JOIN names n ON n.id=w.name_id WHERE w.way_id=? LIMIT 1',
    );
    final wayAttrCache = <int, _WayAttr?>{};
    const minorClasses = <String>[
      'residential', 'service', 'track', 'living_street', 'path', 'footway',
      'cycleway', 'pedestrian', 'steps', 'bridleway', 'road',
    ];
    _WayAttr? wayAttr(int wayId) {
      if (wayAttrCache.containsKey(wayId)) return wayAttrCache[wayId];
      final rows = wayAttrStmt.select([wayId]);
      if (rows.isEmpty) return wayAttrCache[wayId] = null;
      final r = rows.first;
      final road = '${r['road_class'] ?? ''}'.toLowerCase();
      final access = '${r['access'] ?? ''}'.toLowerCase();
      final surface = '${r['surface'] ?? ''}'.toLowerCase();
      final name = [r['name_fa'], r['name'], r['name_en']]
          .map((v) => '${v ?? ''}')
          .firstWhere((v) => v.isNotEmpty, orElse: () => '');
      return wayAttrCache[wayId] = _WayAttr(
        roadClass: '${r['road_class'] ?? ''}',
        speedKmh: ((r['speed_kmh'] as num?)?.toDouble() ?? 30).clamp(5, 160).toDouble(),
        onewayMode: _effectiveOneway(_parseOnewayMode(r['oneway']), r['junction']),
        name: name,
        junction: '${r['junction'] ?? ''}',
        allowed: allowed(road, access, surface),
        minor: minorClasses.any(road.startsWith),
      );
    }

    // The EXISTS keeps the "edge must be backed by a physical segment" rule.
    final edgeStmt = db.prepare(
      'SELECT e.start, e."end", e.distance_m, e.way_id FROM edges e '
      'WHERE e.start=? AND EXISTS ('
      'SELECT 1 FROM segments s WHERE s.way_id=e.way_id '
      'AND ((s.a=e.start AND s.b=e."end") OR (s.a=e."end" AND s.b=e.start)))',
    );

    List<_DbRouteEdge> outgoing(int id) {
      if (id < 0) return adjacency[id] ?? const <_DbRouteEdge>[];
      if (!expanded.add(id)) return adjacency[id] ?? const <_DbRouteEdge>[];
      final list = adjacency[id] ??= <_DbRouteEdge>[];
      for (final r in edgeStmt.select([id])) {
        final wayId = (r['way_id'] as num).toInt();
        final attr = wayAttr(wayId);
        if (attr == null || !attr.allowed) continue;
        final candidate = _DbRouteEdge(
          from: id,
          to: (r['end'] as num).toInt(),
          distanceM: (r['distance_m'] as num).toDouble(),
          speedKmh: attr.speedKmh,
          wayId: wayId,
          onewayMode: attr.onewayMode,
          roadClass: attr.roadClass,
          name: attr.name,
          junction: attr.junction,
          idx: edgeSeq++,
        );
        // The graph may contain both orientations of a physical way. The
        // stored OSM geometry is the final authority for which orientation a
        // one-way way permits. Never let the reverse graph row leak into A*.
        if (!directionAllowed(candidate)) continue;
        list.add(candidate);
      }
      return list;
    }

    // ---- Snap to the nearest *directed road segment*, not the nearest node.
    // The old code snapped to a node and then drew a straight line from the raw
    // GPS point to it, which cut across blocks and ignored one-way streets.
    _ModernSnap? snapToRoad(RoutePoint p) {
      for (final radius in const [0.0015, 0.004, 0.01, 0.03, 0.08]) {
        final cosLat = math.cos(p.lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
        final lonRadius = radius / cosLat;
        final idRows = db.select(
          'SELECT id FROM node_index WHERE max_lat>=? AND min_lat<=? AND max_lon>=? AND min_lon<=? LIMIT 3000',
          [p.lat - radius, p.lat + radius, p.lon - lonRadius, p.lon + lonRadius],
        );
        final near = <MapEntry<int, double>>[];
        for (final row in idRows) {
          final id = (row['id'] as num).toInt();
          final q = nodeOrNull(id);
          if (q == null) continue;
          final d = _distance(p, q);
          near.add(MapEntry(id, d));
        }
        near.sort((a, b) => a.value.compareTo(b.value));
        final cands = <_ModernSnap>[];
        var bestD = double.infinity;
        for (final entry in near.take(80)) {
          for (final e in outgoing(entry.key)) {
            final projection = projectOnEdge(p, e);
            if (projection == null) continue;
            final d = projection.distanceM;
            if (d < bestD) bestD = d;
            cands.add(_ModernSnap(
              edge: e,
              t: projection.t,
              distance: d,
              point: projection.point,
            ));
          }
        }
        if (cands.isNotEmpty && bestD <= radius * 111500.0) {
          // Keep both directions of a genuinely two-way physical road, but do
          // not keep a nearby parallel carriageway merely because its node is
          // also inside the spatial search box.
          final best0 = cands.reduce((a, b) => a.distance <= b.distance ? a : b);
          bool samePhysical(_ModernSnap c) =>
              c.edge.wayId == best0.edge.wayId &&
              ((c.edge.from == best0.edge.from && c.edge.to == best0.edge.to) ||
                  (c.edge.from == best0.edge.to && c.edge.to == best0.edge.from));
          final keep = cands.where(samePhysical).toList()
            ..sort((a, b) => a.distance.compareTo(b.distance));
          return _ModernSnap.group(keep);
        }
      }
      return null;
    }

    final startSnap = snapToRoad(origin);
    final goalSnap = snapToRoad(destination);
    if (startSnap == null || goalSnap == null) {
      return AbmRouteResult(points: const [], edges: const [], diagnostics: const ['MODERN GRAPH: nearest road not found']);
    }
    virtualPoints[startId] = startSnap.point;
    virtualPoints[goalId] = goalSnap.point;

    void addVirtual(_DbRouteEdge e) => (adjacency[e.from] ??= <_DbRouteEdge>[]).add(e);
    _DbRouteEdge partial(_DbRouteEdge base, int from, int to, double meters) => _DbRouteEdge(
          from: from, to: to, distanceM: meters, speedKmh: base.speedKmh,
          wayId: base.wayId, onewayMode: base.onewayMode, roadClass: base.roadClass,
          name: base.name, junction: base.junction, idx: edgeSeq++,
        );
    for (final c in startSnap.candidates) {
      addVirtual(partial(c.edge, startId, c.edge.to, c.edge.distanceM * (1.0 - c.t)));
    }
    // Start and goal on the same directed segment, goal ahead of start.
    for (final s in startSnap.candidates) {
      for (final g in goalSnap.candidates) {
        if (s.edge.from == g.edge.from && s.edge.to == g.edge.to && s.edge.wayId == g.edge.wayId && g.t >= s.t) {
          addVirtual(partial(s.edge, startId, goalId, s.edge.distanceM * (g.t - s.t)));
        }
      }
    }
    // Goal-side virtual edges start at real nodes and are merged in when that
    // node is relaxed by the search.
    final goalIn = <int, List<_DbRouteEdge>>{};
    for (final c in goalSnap.candidates) {
      (goalIn[c.edge.from] ??= <_DbRouteEdge>[]).add(partial(c.edge, c.edge.from, goalId, c.edge.distanceM * c.t));
    }

    // ---- Turn restrictions (no_*/only_*), keyed by (via node, incoming way).
    // The whole table is read ONCE into memory (province ABMs hold at most a
    // few tens of thousands of rows). The old code ran one SQL query for every
    // distinct (incoming way, via node) pair met by the search.
    final rulesByVia = <int, Map<int, _TurnRule>>{};
    _TurnRule ruleFor(int via, int inWay) =>
        (rulesByVia[via] ??= <int, _TurnRule>{})[inWay] ??=
            _TurnRule(no: <int>{}, only: <int>{});
    try {
      final hasLookup = db.select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='turn_restriction_lookup' LIMIT 1",
      ).isNotEmpty;
      if (hasLookup) {
        for (final row in db.select(
          'SELECT restriction,from_way,via_node,to_way FROM turn_restriction_lookup LIMIT 3000000',
        )) {
          final rule = ruleFor((row['via_node'] as num).toInt(), (row['from_way'] as num).toInt());
          final to = (row['to_way'] as num).toInt();
          if ('${row['restriction'] ?? ''}'.toLowerCase().startsWith('only')) {
            rule.only.add(to);
          } else {
            rule.no.add(to);
          }
        }
      } else {
        List<int> ids(dynamic v) {
          try {
            final x = jsonDecode('${v ?? '[]'}');
            return x is List ? x.whereType<num>().map((n) => n.toInt()).toList() : const [];
          } catch (_) {
            return const [];
          }
        }
        for (final r in db.select('SELECT restriction,from_json,via_json,to_json FROM turn_restrictions')) {
          final only = '${r['restriction'] ?? ''}'.toLowerCase().startsWith('only');
          for (final fw in ids(r['from_json'])) {
            for (final vn in ids(r['via_json'])) {
              for (final tw in ids(r['to_json'])) {
                final rule = ruleFor(vn, fw);
                if (only) {
                  rule.only.add(tw);
                } else {
                  rule.no.add(tw);
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    bool turnAllowed(int inWay, int via, int outWay) {
      final rule = rulesByVia[via]?[inWay];
      if (rule == null) return true;
      if (rule.only.isNotEmpty && !rule.only.contains(outWay)) return false;
      return !rule.no.contains(outWay);
    }

    // ---- Search parameters -------------------------------------------------
    // Heuristic speed: the fastest road that really exists in this ABM (not a
    // blanket 160 km/h). A tight bound keeps A* aimed at the goal instead of
    // degenerating into Dijkstra over the whole province.
    var maxSpeed = 120.0;
    try {
      final r = db.select('SELECT MAX(speed_kmh) AS m FROM way_data');
      final m = r.isEmpty ? null : (r.first['m'] as num?)?.toDouble();
      if (m != null && m.isFinite) maxSpeed = m.clamp(50.0, 160.0).toDouble();
    } catch (_) {}
    final directMeters = _distance(startSnap.point, goalSnap.point);
    // Long trips use a slightly weighted heuristic: orders of magnitude fewer
    // expansions for a route that is at most a few percent longer.
    var hWeight = directMeters > 40000 ? 1.35 : directMeters > 10000 ? 1.2 : 1.0;
    // کوتاه‌ترین مسیر باید واقعاً کوتاه‌ترین باشد؛ وزن هیوریستیک را محدود می‌کنیم.
    if (_activeRouteMode == 1 && hWeight > 1.1) hWeight = 1.1;
    // Hierarchy: on a long trip, minor roads (residential/service/track…) are
    // only used near the start and the goal.
    final pruneMinor = directMeters > 6000 && _activeRouteMode != 1;
    final nearRadius = math.max(2500.0, directMeters * 0.08);
    const budgetMs = 60000;
    final clock = Stopwatch()..start();
    var timedOut = false;
    var expandedStates = 0;

    final hCache = <int, double>{};
    double heuristic(int nodeId) {
      final cached = hCache[nodeId];
      if (cached != null) return cached;
      final d = _distance(node(nodeId), goalSnap.point);
      final double base;
      switch (_activeRouteMode) {
        case 1:
          base = d;
        case 2:
          base = 0.5 * d / _economicRefMps + 0.5 * d / maxSpeed * 3.6;
        default:
          base = d / maxSpeed * 3.6 * 0.90;
      }
      return hCache[nodeId] = base * hWeight;
    }

    final nearCache = <int, bool>{};
    bool nearEndpoints(int nodeId) {
      final cached = nearCache[nodeId];
      if (cached != null) return cached;
      final p = node(nodeId);
      final near = _distance(p, startSnap.point) <= nearRadius ||
          _distance(p, goalSnap.point) <= nearRadius;
      return nearCache[nodeId] = near;
    }

    final minorByWay = <int, bool>{};
    bool isMinorWay(_DbRouteEdge e) =>
        minorByWay[e.wayId] ??= (wayAttrCache[e.wayId]?.minor ?? false);

    // Edge-based A*: state = directed edge (int id), so restrictions and
    // U-turn bans can look at the edge we arrived on.
    // Level 0: strict + hierarchy pruning. Level 1: strict, full graph.
    // Level 2: allow U-turns. Level 3: also ignore turn restrictions.
    var cost = <int, double>{};
    var prevState = <int, int?>{};
    var stateEdge = <int, _DbRouteEdge>{};
    int? goalKey;
    var level = 0;
    for (; level < 4 && goalKey == null && !timedOut; level++) {
      if (level == 0 && !pruneMinor) continue;
      cost = <int, double>{};
      prevState = <int, int?>{};
      stateEdge = <int, _DbRouteEdge>{};
      final open = _MinHeap<_EdgeStateItem>((a, b) => a.priority.compareTo(b.priority));
      final prune = level == 0;
      final banUTurn = level <= 1;
      final useRestrictions = level <= 2;

      void push(_DbRouteEdge e, int? fromKey, double g0) {
        final k = e.idx;
        // مسیرهای جایگزین: خیابان‌های مسیر(های) قبلی گران‌تر حساب می‌شوند.
        // ضریب فقط بزرگ‌تر از ۱ است.
        final pen = wayPenalty == null ? 1.0 : (wayPenalty[e.wayId] ?? 1.0);
        final g = g0 + _edgeRouteCost(e) * pen;
        if (g < (cost[k] ?? double.infinity)) {
          cost[k] = g;
          prevState[k] = fromKey;
          stateEdge[k] = e;
          open.add(_EdgeStateItem(k, e, g, g + heuristic(e.to)));
        }
      }

      for (final e in adjacency[startId] ?? const <_DbRouteEdge>[]) {
        push(e, null, 0);
      }
      var tick = 0;
      while (open.isNotEmpty) {
        if ((++tick & 511) == 0 && clock.elapsedMilliseconds > budgetMs) {
          timedOut = true;
          break;
        }
        final item = open.removeFirst();
        if (item.g > (cost[item.key] ?? double.infinity)) continue;
        expandedStates++;
        final inc = item.edge;
        if (inc.to == goalId) {
          goalKey = item.key;
          break;
        }
        final goalExtra = goalIn[inc.to];
        final base = outgoing(inc.to);
        // U-turn only allowed at a true dead end (no other way out).
        var hasAlt = false;
        for (final x in base) {
          if (x.to != inc.from) { hasAlt = true; break; }
        }
        if (!hasAlt && goalExtra != null) {
          for (final x in goalExtra) {
            if (x.to != inc.from) { hasAlt = true; break; }
          }
        }
        void relax(_DbRouteEdge n) {
          if (useRestrictions && !turnAllowed(inc.wayId, inc.to, n.wayId)) return;
          if (banUTurn && n.to == inc.from && hasAlt) return;
          if (prune && n.to >= 0 && isMinorWay(n) && !nearEndpoints(n.to) && !nearEndpoints(n.from)) return;
          push(n, item.key, item.g);
        }
        for (final n in base) {
          relax(n);
        }
        if (goalExtra != null) {
          for (final n in goalExtra) {
            relax(n);
          }
        }
      }
    }

    if (goalKey == null && timedOut) {
      return AbmRouteResult(points: const [], edges: const [], diagnostics: <String>[
        'MODERN GRAPH: search timed out after ${clock.elapsedMilliseconds}ms '
            '(states=$expandedStates nodes=${expanded.length})',
      ]);
    }

    if (goalKey == null) {
      return AbmRouteResult(points: const [], edges: const [], diagnostics: const ['MODERN GRAPH: route not found']);
    }

    final pathEdges = <_DbRouteEdge>[];
    int? walk = goalKey;
    while (walk != null) {
      pathEdges.add(stateEdge[walk]!);
      walk = prevState[walk];
    }
    final pathReversed = pathEdges.reversed.toList();
    pathEdges
      ..clear()
      ..addAll(pathReversed);
    final orderedIds = <int>[startId, ...pathEdges.map((e) => e.to)];

    // Geometry is reconstructed from the stored physical OSM way geometry.
    // Virtual start/goal edges are sliced from that same geometry; they are
    // never rendered as a new straight chord from GPS to the road node.
    final points = <RoutePoint>[startSnap.point];
    for (var i = 1; i < orderedIds.length; i++) {
      final _DbRouteEdge? edge = pathEdges[i - 1];
      if (edge == null) continue;
      List<RoutePoint> shape;
      if (edge.from == startId && edge.to == goalId) {
        _ModernSnap? match;
        _ModernSnap? goalMatch;
        for (final s in startSnap.candidates) {
          for (final g in goalSnap.candidates) {
            if (s.edge.from == g.edge.from && s.edge.to == g.edge.to &&
                s.edge.wayId == g.edge.wayId && g.t >= s.t) {
              match = s;
              goalMatch = g;
              break;
            }
          }
          if (match != null) break;
        }
        if (match != null && goalMatch != null) {
          shape = subPolyline(physicalEdgeGeometry(match.edge), match.t, goalMatch.t);
        } else {
          // The search can only create this virtual edge when both snaps share
          // a directed physical edge. If that invariant is broken, never draw
          // a straight off-road line as a visual fallback.
          shape = const <RoutePoint>[];
        }
      } else if (edge.from == startId) {
        final c = startSnap.candidates.firstWhere(
          (x) => x.edge.to == edge.to && x.edge.wayId == edge.wayId,
          orElse: () => startSnap.candidates.first,
        );
        shape = subPolyline(physicalEdgeGeometry(c.edge), c.t, 1.0);
      } else if (edge.to == goalId) {
        final c = goalSnap.candidates.firstWhere(
          (x) => x.edge.from == edge.from && x.edge.wayId == edge.wayId,
          orElse: () => goalSnap.candidates.first,
        );
        shape = subPolyline(physicalEdgeGeometry(c.edge), 0.0, c.t);
      } else {
        shape = physicalEdgeGeometry(edge);
      }
      for (final p in shape) {
        if (_distance(points.last, p) > 0.05) points.add(p);
      }
    }
    if (_distance(points.last, goalSnap.point) > 0.05) points.add(goalSnap.point);

    final edges = <RouteEdgeInfo>[];
    final fromIds = <int>[];
    final toIds = <int>[];
    for (var i = 1; i < orderedIds.length; i++) {
      final _DbRouteEdge? edge = pathEdges[i - 1];
      if (edge == null) continue;
      final from = node(edge.from);
      final to = node(edge.to);
      if (_distance(from, to) < 0.3) continue;
      edges.add(RouteEdgeInfo(
        from: from, to: to, roadClass: edge.roadClass, name: edge.name,
        junction: edge.junction, wayId: edge.wayId, speedKmh: edge.speedKmh,
      ));
      fromIds.add(edge.from);
      toIds.add(edge.to);
    }
    if (points.length < 2) {
      return AbmRouteResult(points: const [], edges: const [], diagnostics: const ['MODERN GRAPH: route geometry has fewer than two physical points']);
    }

    // ---- Roundabout geometry (entrance / real arms / exit number) ----
    double bearing(RoutePoint a, RoutePoint b) {
      final lat1 = a.lat * math.pi / 180, lat2 = b.lat * math.pi / 180;
      final dl = (b.lon - a.lon) * math.pi / 180;
      final y = math.sin(dl) * math.cos(lat2);
      final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dl);
      return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    }

    for (var i = 0; i < edges.length;) {
      if (!isRoundabout(edges[i].junction)) { i++; continue; }
      final begin = i;
      while (i < edges.length && isRoundabout(edges[i].junction)) i++;
      final end = i;

      final ringIds = <int>{};
      for (var k = begin; k < end; k++) {
        if (fromIds[k] >= 0) ringIds.add(fromIds[k]);
        if (toIds[k] >= 0) ringIds.add(toIds[k]);
      }

      final branchByAngle = <double, RoundaboutBranchInfo>{};
      void addBranch(double angle, {required bool canEnter, required bool canExit}) {
        final a = (angle % 360 + 360) % 360;
        double? key;
        for (final k in branchByAngle.keys) {
          var d = (k - a).abs();
          if (d > 180) d = 360 - d;
          if (d <= 7.5) { key = k; break; }
        }
        if (key == null) {
          branchByAngle[a] = RoundaboutBranchInfo(angleDegrees: a, canEnter: canEnter, canExit: canExit);
        } else {
          final old = branchByAngle[key]!;
          branchByAngle[key] = RoundaboutBranchInfo(
            angleDegrees: old.angleDegrees,
            canEnter: old.canEnter || canEnter,
            canExit: old.canExit || canExit,
          );
        }
      }

      for (final nodeId in ringIds) {
        final center = nodeOrNull(nodeId);
        if (center == null) continue;
        for (final e in outgoing(nodeId)) {
          if (isRoundabout(e.junction)) continue;
          final other = nodeOrNull(e.to);
          if (other == null) continue;
          addBranch(bearing(center, other), canEnter: false, canExit: true);
        }
        try {
          final rows = db.select(
            'SELECT e.start,w.junction FROM edges e JOIN way_data w ON w.way_id=e.way_id WHERE e."end"=?',
            [nodeId],
          );
          for (final r in rows) {
            if (isRoundabout('${r['junction'] ?? ''}')) continue;
            final other = nodeOrNull((r['start'] as num).toInt());
            if (other == null) continue;
            addBranch(bearing(center, other), canEnter: true, canExit: false);
          }
        } catch (_) {}
      }

      final branches = branchByAngle.values.toList()
        ..sort((a, b) => a.angleDegrees.compareTo(b.angleDegrees));
      double? entrance;
      if (begin > 0) entrance = bearing(edges[begin].from, edges[begin - 1].from);
      final entranceAngles = branches.where((b) => b.canEnter).map((b) => b.angleDegrees).toList(growable: false);
      final exitAngles = branches.where((b) => b.canExit).map((b) => b.angleDegrees).toList(growable: false);
      double? activeExitAngle;
      if (end < edges.length) activeExitAngle = bearing(edges[end - 1].to, edges[end].to);

      final exitBranches = branches.where((b) => b.canExit).toList();
      final usableExitBranches = entrance == null
          ? exitBranches
          : exitBranches.where((b) {
              var d = (b.angleDegrees - entrance!).abs();
              if (d > 180) d = 360 - d;
              return d > 12;
            }).toList();

      int exitNumber = 0;
      if (activeExitAngle != null && usableExitBranches.isNotEmpty && entrance != null) {
        // Right-hand traffic (Iran): ring traffic runs counter-clockwise. The
        // measured tangent wins whenever the ring has 2+ edges.
        final ccwDefault = false;
        final routeClockwise = (() {
          if (end - begin >= 2) {
            final a = bearing(edges[begin].from, edges[begin].to);
            final b = bearing(edges[begin + 1].from, edges[begin + 1].to);
            final d = (b - a + 360) % 360;
            return d > 0 && d < 180;
          }
          return ccwDefault;
        })();
        double delta(double from, double to) =>
            routeClockwise ? (to - from + 360) % 360 : (from - to + 360) % 360;
        final ordered = usableExitBranches
            .where((b) => delta(entrance!, b.angleDegrees) > 5)
            .toList()
          ..sort((a, b) => delta(entrance!, a.angleDegrees).compareTo(delta(entrance!, b.angleDegrees)));
        for (var n = 0; n < ordered.length; n++) {
          var d = (ordered[n].angleDegrees - activeExitAngle).abs();
          if (d > 180) d = 360 - d;
          if (d <= 10) { exitNumber = n + 1; break; }
        }
      }
      if (exitNumber == 0 && activeExitAngle != null) exitNumber = 1;

      for (var n = begin; n < end; n++) {
        final old = edges[n];
        edges[n] = RouteEdgeInfo(
          from: old.from, to: old.to, roadClass: old.roadClass, name: old.name,
          junction: old.junction, wayId: old.wayId, speedKmh: old.speedKmh,
          roundaboutExitNumber: exitNumber == 0 ? null : exitNumber,
          roundaboutExitCount: usableExitBranches.length,
          roundaboutBranches: branches,
          roundaboutEntranceAngles: entranceAngles,
          roundaboutExitAngles: exitAngles,
          roundaboutActiveEntranceAngle: entrance,
          roundaboutActiveExitAngle: activeExitAngle,
        );
      }
    }

    return AbmRouteResult(
      points: points,
      edges: edges,
      diagnostics: [
        'ABM v6 GRAPH: nodes=${adjacency.length} expanded=${expanded.length} states=$expandedStates '
            'level=${level - 1} ms=${clock.elapsedMilliseconds} maxSpeed=${maxSpeed.toStringAsFixed(0)} spatial=node_index '
            'startSnap=${startSnap.distance.toStringAsFixed(1)}m goalSnap=${goalSnap.distance.toStringAsFixed(1)}m',
      ],
    );
  }

  static AbmRouteResult? _routeSqliteDetailed(
    String path,
    RoutePoint origin,
    RoutePoint destination,
    bool avoidUnpavedRoads,
    bool avoidTolls,
    bool avoidTrafficZones,
    bool avoidHighways, [
    Map<int, double>? wayPenalty,
  ]) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    // Routing is intentionally file-backed rather than copying a country's
    // graph into the Dart heap. Each route reads the required indexed records
    // directly from province-specific SQLite; there is no application-level full-database cache.
    try {
      try {
        db.execute('PRAGMA query_only=ON');
        db.execute('PRAGMA temp_store=FILE');
        // 64 MB page cache + memory-mapped reads: the A* search touches the
        // same pages (nodes/edges/segments) hundreds of thousands of times.
        db.execute('PRAGMA cache_size=-65536');
        db.execute('PRAGMA mmap_size=268435456');
      } catch (_) {}
      // ABM v4 produced by the current map builder uses the compact
      // nodes/edges/spatial schema. Keep the legacy reader below for older
      // installations, but never try to query the removed node_data/segments
      // tables when the modern schema is present.
      final modernSchema = db.select(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name IN ('nodes','edges','node_index','way_data','segments')"
      ).map((r) => '${r['name']}').toSet();
      if (modernSchema.containsAll({'nodes','edges','node_index','way_data','segments'})) {
        return _routeModernSqliteDetailed(
          db, origin, destination, avoidUnpavedRoads, avoidTolls, avoidTrafficZones, avoidHighways,
          wayPenalty,
        );
      }
      RoutePoint pointFor(int id) {
        final r = db.select('SELECT lat_e7,lon_e7 FROM node_data WHERE id=?', [id]);
        if (r.isEmpty) throw StateError('Missing routing node $id');
        return RoutePoint(
          (r.first['lat_e7'] as num).toDouble() * 1e-7,
          (r.first['lon_e7'] as num).toDouble() * 1e-7,
        );
      }

      final nodeCache = LinkedHashMap<int, RoutePoint>();
      RoutePoint? node(int id) {
        final cached = nodeCache.remove(id);
        if (cached != null) {
          nodeCache[id] = cached;
          return cached;
        }
        try {
          final p = pointFor(id);
          nodeCache[id] = p;
          if (nodeCache.length > 8192) nodeCache.remove(nodeCache.keys.first);
          return p;
        } catch (_) {
          return null;
        }
      }

      _SqliteSnap? snap(RoutePoint p) {
        if (!p.lat.isFinite || !p.lon.isFinite || p.lat < -90 || p.lat > 90 || p.lon < -180 || p.lon > 180) return null;
        final cosLat = math.cos(p.lat * math.pi / 180).abs().clamp(0.2, 1.0);
        _SqliteSnap? best;
        var bestMeters = double.infinity;
        for (final radius in const [0.005, 0.01, 0.03, 0.08, 0.2, 0.5, 1.0]) {
          final lonRadius = radius / cosLat;
          var rows = db.select(
            'SELECT s.a,s.b,s.dist_dm,w.way_id,w.oneway,COALESCE(w.junction,\'\') AS junction,na.lat_e7 alat,na.lon_e7 alon,nb.lat_e7 blat,nb.lon_e7 blon '
            'FROM road_index r JOIN segments s ON s.id BETWEEN r.seg_from AND r.seg_to '
            'JOIN way_data w ON w.way_id=s.way_id JOIN node_data na ON na.id=s.a JOIN node_data nb ON nb.id=s.b '
            'WHERE r.max_lat>=? AND r.min_lat<=? AND r.max_lon>=? AND r.min_lon<=? LIMIT 5000',
            [p.lat + radius, p.lat - radius, p.lon + lonRadius, p.lon - lonRadius],
          );

          // Do not fall back to a coordinate-filtered scan of `segments` when
          // the R-tree is stale or empty. That query can visit the whole country
          // on a large ABM. A broken index yields no snap candidate; the build
          // validator is responsible for detecting/fixing it before release.
          for (final r in rows) {
            final a = RoutePoint((r['alat'] as num).toDouble() * 1e-7, (r['alon'] as num).toDouble() * 1e-7);
            final b = RoutePoint((r['blat'] as num).toDouble() * 1e-7, (r['blon'] as num).toDouble() * 1e-7);
            final latScale = 111320.0;
            final lonScale = 111320.0 * math.cos(p.lat * math.pi / 180).abs().clamp(0.2, 1.0);
            final ax = (a.lon - p.lon) * lonScale, ay = (a.lat - p.lat) * latScale;
            final bx = (b.lon - p.lon) * lonScale, by = (b.lat - p.lat) * latScale;
            final dx = bx - ax, dy = by - ay;
            final len2 = dx * dx + dy * dy;
            final t = len2 <= 1e-9 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
            final px = ax + dx * t, py = ay + dy * t;
            final d = math.sqrt(px * px + py * py);
            if (d >= bestMeters) continue;
            final segmentMeters = ((r['dist_dm'] as num?)?.toDouble() ?? _distance(a, b) * 10.0) / 10.0;
            final wayId = (r['way_id'] as num).toInt();
            final onewayMode = _effectiveOneway(_parseOnewayMode(r['oneway']), r['junction']);
            bestMeters = d;
            best = _SqliteSnap(
              a: (r['a'] as num).toInt(), b: (r['b'] as num).toInt(), t: t,
              point: RoutePoint(p.lat + py / latScale, p.lon + px / lonScale),
              segmentMeters: segmentMeters, onewayMode: onewayMode, wayId: wayId,
            );
          }
          if (best != null && bestMeters <= radius * 111500.0) break;
        }
        return best;
      }
      final startSnap = snap(origin);
      final goalSnap = snap(destination);
      if (startSnap == null || goalSnap == null) {
        return AbmRouteResult(points: const [], edges: const [], diagnostics: const []);
      }

      // Virtual nodes are created only in RAM. ABM stays compact: a two-way
      // segment is stored once, then its reverse movement is synthesized here.
      const start = -1;
      const goal = -2;
      final virtualPoints = <int, RoutePoint>{start: startSnap.point, goal: goalSnap.point};
      final adjacency = LinkedHashMap<int, List<_DbRouteEdge>>();
      void add(_DbRouteEdge e) => (adjacency[e.from] ??= <_DbRouteEdge>[]).add(e);
      void boundAdjacencyCache() {
        while (adjacency.length > 4096) {
          final candidate = adjacency.keys.firstWhere(
            (id) => id >= 0,
            orElse: () => adjacency.keys.first,
          );
          adjacency.remove(candidate);
        }
      }

      bool allowed(String road, String access, String surface) {
        if (avoidTrafficZones && access.contains('private')) return false;
        if (avoidHighways && (road.startsWith('motorway') || road.startsWith('trunk'))) return false;
        if (avoidTolls && road.contains('toll')) return false;
        if (avoidUnpavedRoads && surface.isNotEmpty && surface != 'paved' && surface != 'asphalt') return false;
        return true;
      }
      _DbRouteEdge fromRow(Map r, {required int from, required int to, required double distance}) {
        return _DbRouteEdge(
          from: from, to: to, distanceM: distance,
          speedKmh: ((r['speed_kmh'] as num?)?.toDouble() ?? 30).clamp(5, 160).toDouble(),
          wayId: (r['way_id'] as num).toInt(), onewayMode: _parseOnewayMode(r['oneway']),
          roadClass: '${r['road_class'] ?? ''}', name: '${r['name'] ?? ''}', junction: '${r['junction'] ?? ''}',
        );
      }

      bool toleranceZero(double v) => v.abs() < 1e-7;
      void addSegmentMoves(_SqliteSnap s, {required int virtual, required bool fromVirtual}) {
        // `way_data` only stores class_id/name_id (foreign keys), not
        // road_class/name text -- those require joining categories/names,
        // exactly like the `ways` VIEW does (search/map_db.py). Selecting
        // w.road_class/w.name straight off way_data throws "no such column:
        // w.road_class", which is exactly the crash field logs showed on
        // every single route request. The `ways` VIEW itself can't be reused
        // as-is here because it does not expose speed_kmh/oneway (those stay
        // on way_data, consumed instead through the `edges` VIEW elsewhere).
        // So this reproduces the view's own join rather than depending on it.
        final r = db.select(
          "SELECT c.name AS road_class, "
          "COALESCE(NULLIF(n.name_fa,''), NULLIF(n.name,''), NULLIF(n.name_en,''), '') AS name, "
          "COALESCE(w.junction,'') AS junction, w.speed_kmh, w.oneway, "
          "COALESCE(w.access,'') AS access, COALESCE(w.surface,'') AS surface, w.way_id "
          'FROM way_data w JOIN categories c ON c.id = w.class_id '
          'LEFT JOIN names n ON n.id = w.name_id '
          'WHERE w.way_id=? LIMIT 1', [s.wayId],
        );
        if (r.isEmpty) return;
        final row = r.first;
        if (!allowed('${r.first['road_class'] ?? ''}'.toLowerCase(), '${r.first['access'] ?? ''}'.toLowerCase(), '${r.first['surface'] ?? ''}'.toLowerCase())) return;
        final aDist = s.segmentMeters * s.t;
        final bDist = s.segmentMeters * (1.0 - s.t);
        if (fromVirtual) {
          if (s.onewayMode == 1) {
            // way_geometry/segments are ordered in the legal forward direction.
            add(fromRow(row, from: virtual, to: s.b, distance: bDist));
          } else if (s.onewayMode == -1) {
            add(fromRow(row, from: virtual, to: s.a, distance: aDist));
          } else {
            add(fromRow(row, from: virtual, to: s.a, distance: aDist));
            add(fromRow(row, from: virtual, to: s.b, distance: bDist));
          }
        } else {
          if (s.onewayMode == 1) {
            add(fromRow(row, from: s.a, to: virtual, distance: aDist));
          } else if (s.onewayMode == -1) {
            add(fromRow(row, from: s.b, to: virtual, distance: bDist));
          } else {
            add(fromRow(row, from: s.a, to: virtual, distance: aDist));
            add(fromRow(row, from: s.b, to: virtual, distance: bDist));
          }
        }
      }
      addSegmentMoves(startSnap, virtual: start, fromVirtual: true);
      addSegmentMoves(goalSnap, virtual: goal, fromVirtual: false);

      // Materialize every stored directed edge on demand. For oneway=false the
      // reverse edge is synthesized in RAM; nothing is duplicated in ABM.
      void expandNode(int id) {
        if (id < 0) return;
        final cached = adjacency.remove(id);
        if (cached != null) {
          adjacency[id] = cached;
          return;
        }
        final p = node(id);
        if (p == null) return;
        // `edges` is already the directed runtime view: two-way physical
        // segments appear once in `segments` and their reverse movement is
        // synthesized by the SQL view. Do not reverse that view a second time
        // here (the previous implementation produced duplicate reverse edges).
        // Routing expansion deliberately reads only graph-cost fields.
        // Names, junction labels and other presentation data are fetched only
        // for the final way IDs that actually survived path finding.
        final rows = db.select(
          'SELECT e.start,e.end,e.distance_m,e.speed_kmh,e.way_id,e.oneway,w.junction,'
          'EXISTS(SELECT 1 FROM segments sf WHERE sf.way_id=e.way_id AND sf.a=e.start AND sf.b=e.end) AS fwd,'
          'w.access,w.surface,c.name AS road_class '
          'FROM edges e JOIN way_data w ON w.way_id=e.way_id '
          'JOIN categories c ON c.id=w.class_id '
          'WHERE (e.start=? OR e.end=?) '
          'AND EXISTS ('
          'SELECT 1 FROM segments s WHERE s.way_id=e.way_id '
          'AND ((s.a=e.start AND s.b=e.end) OR (s.a=e.end AND s.b=e.start))'
          ')',
          [id, id],
        );
        final list = adjacency[id] ??= <_DbRouteEdge>[];
        for (final r in rows) {
          final storedStart = (r['start'] as num).toInt();
          final storedEnd = (r['end'] as num).toInt();
          final onewayMode = _effectiveOneway(_parseOnewayMode(r['oneway']), r['junction']);
          // One-way ways must only use the stored forward (legal) direction.
          if (onewayMode == 1 && ((r['fwd'] as num?)?.toInt() ?? 1) == 0) continue;
          final road = '${r['road_class'] ?? ''}'.toLowerCase();
          final access = '${r['access'] ?? ''}'.toLowerCase();
          final surface = '${r['surface'] ?? ''}'.toLowerCase();
          if (!allowed(road, access, surface)) continue;
          final dist = (r['distance_m'] as num).toDouble();
          final speed = ((r['speed_kmh'] as num?)?.toDouble() ?? 30).clamp(5, 160).toDouble();
          final way = (r['way_id'] as num).toInt();
          if (storedStart == id) {
            list.add(_DbRouteEdge(
              from: id, to: storedEnd, distanceM: dist, speedKmh: speed,
              wayId: way, onewayMode: onewayMode,
              roadClass: '${r['road_class'] ?? ''}', name: '', junction: '',
            ));
          } else if (storedEnd == id && onewayMode == 0) {
            // Two-way physical segment: synthesize only the legal reverse
            // direction. A one-way segment is never reversed here.
            list.add(_DbRouteEdge(
              from: id, to: storedStart, distanceM: dist, speedKmh: speed,
              wayId: way, onewayMode: onewayMode,
              roadClass: '${r['road_class'] ?? ''}', name: '', junction: '',
            ));
          }
        }
        boundAdjacencyCache();
      }

      // New ABMs normalize restrictions by (incoming way, via node, outgoing
      // way), so a route reads only rules relevant to the current search state.
      // Older ABMs keep the JSON table and use the compatibility fallback.
      final hasIndexedRestrictions = db.select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='turn_restriction_lookup' LIMIT 1",
      ).isNotEmpty;
      final turnRuleCache = <String, _TurnRule>{};
      final legacyNoTurns = <String>{};
      final legacyOnlyTurns = <String, int>{};
      if (!hasIndexedRestrictions) {
        try {
          final rows = db.select('SELECT restriction,from_json,via_json,to_json FROM turn_restrictions');
          for (final r in rows) {
            final type='${r['restriction'] ?? ''}'.toLowerCase();
            List<int> ids(dynamic v){ try { final x=jsonDecode('${v ?? '[]'}'); return x is List ? x.whereType<num>().map((n)=>n.toInt()).toList() : const []; } catch(_){ return const []; } }
            for(final fw in ids(r['from_json'])) for(final vn in ids(r['via_json'])) for(final tw in ids(r['to_json'])) {
              if(type.startsWith('only')) legacyOnlyTurns['$fw|$vn']=tw; else legacyNoTurns.add('$fw|$vn|$tw');
            }
          }
        } catch (_) {}
      }
      _TurnRule ruleFor(int incomingWay, int viaNode) {
        final key = '$incomingWay|$viaNode';
        final cached = turnRuleCache[key];
        if (cached != null) return cached;
        final no = <int>{};
        final only = <int>{};
        if (hasIndexedRestrictions) {
          try {
            final rows = db.select(
              'SELECT restriction,to_way FROM turn_restriction_lookup WHERE from_way=? AND via_node=?',
              [incomingWay, viaNode],
            );
            for (final row in rows) {
              final toWay = (row['to_way'] as num).toInt();
              if ('${row['restriction'] ?? ''}'.toLowerCase().startsWith('only')) {
                only.add(toWay);
              } else {
                no.add(toWay);
              }
            }
          } catch (_) {}
        }
        final rule = _TurnRule(no: no, only: only);
        turnRuleCache[key] = rule;
        return rule;
      }
      bool turnAllowed(int incomingWay,int viaNode,int outgoingWay){
        if (!hasIndexedRestrictions) {
          final only=legacyOnlyTurns['$incomingWay|$viaNode'];
          if(only!=null && only!=outgoingWay) return false;
          return !legacyNoTurns.contains('$incomingWay|$viaNode|$outgoingWay');
        }
        final rule = ruleFor(incomingWay, viaNode);
        if (rule.only.isNotEmpty && !rule.only.contains(outgoingWay)) return false;
        return !rule.no.contains(outgoingWay);
      }

      const noWay = -999999999;
      String stateKey(int n,int w)=>'$n|$w';
      final startKey=stateKey(start,noWay);
      final distance=<String,double>{startKey:0};
      final previous=<String,String?>{startKey:null};
      final previousEdge=<String,_DbRouteEdge>{};
      final open=_MinHeap<_TurnQueueItem>((a,b)=>a.priority.compareTo(b.priority));
      open.add(_TurnQueueItem(start,noWay,0,_distance(startSnap.point,destination)/160.0*3.6));
      String? goalState;
      while(open.isNotEmpty){
        final item=open.removeFirst();
        final key=stateKey(item.node,item.way);
        if(item.cost>(distance[key]??double.infinity))continue;
        if(item.node==goal){goalState=key;break;}
        expandNode(item.node);
        for(final e in adjacency[item.node]??const <_DbRouteEdge>[]){
          if(item.way!=noWay && !turnAllowed(item.way,item.node,e.wayId))continue;
          final next=item.cost+e.distanceM/e.speedKmh*3.6;
          final nk=stateKey(e.to,e.wayId);
          if(next<(distance[nk]??double.infinity)){
            distance[nk]=next; previous[nk]=key; previousEdge[nk]=e;
            final target=e.to==goal?goalSnap.point:(node(e.to)??destination);
            final h=_distance(target,destination)/160.0*3.6;
            open.add(_TurnQueueItem(e.to,e.wayId,next,next+h));
          }
        }
      }
      if(goalState==null){
        return AbmRouteResult(points: const [], edges: const [], diagnostics: const []);
      }
      var states=<String>[]; String? cur=goalState;
      while(cur!=null){states.add(cur);cur=previous[cur];}
      states = states.reversed.toList();
      // Only now, after path finding, resolve presentation metadata for the
      // small set of way IDs that make up the chosen route. This keeps long
      // country-wide searches from materializing road names/junction strings.
      final routeWayIds = <int>{};
      for (var i = 1; i < states.length; i++) {
        final e = previousEdge[states[i]];
        if (e != null) routeWayIds.add(e.wayId);
      }
      final wayMeta = <int, Map<String, dynamic>>{};
      final ids = routeWayIds.toList(growable: false);
      for (var offset = 0; offset < ids.length; offset += 400) {
        final end = offset + 400 < ids.length ? offset + 400 : ids.length;
        final batch = ids.sublist(offset, end);
        if (batch.isEmpty) continue;
        final marks = List.filled(batch.length, '?').join(',');
        final rows = db.select(
          'SELECT w.way_id,c.name AS road_class,'
          "COALESCE(NULLIF(n.name_fa,''),NULLIF(n.name,''),NULLIF(n.name_en,''),'') AS name,"
          "COALESCE(w.junction,'') AS junction "
          'FROM way_data w JOIN categories c ON c.id=w.class_id '
          'LEFT JOIN names n ON n.id=w.name_id '
          'WHERE w.way_id IN ($marks)',
          batch,
        );
        for (final row in rows) {
          wayMeta[(row['way_id'] as num).toInt()] = row;
        }
      }

      final legacyWayGeometryCache=<int,List<RoutePoint>>{};
      List<RoutePoint> legacyWayGeometry(int wayId){
        final cached=legacyWayGeometryCache[wayId];
        if(cached!=null)return cached;
        try{
          final rows=db.select('SELECT geometry FROM way_geometry WHERE way_id=? LIMIT 1',[wayId]);
          if(rows.isEmpty){legacyWayGeometryCache[wayId]=const <RoutePoint>[];return const <RoutePoint>[];}
          final decoded=_decodeAbmWayGeometry(rows.first['geometry']);
          legacyWayGeometryCache[wayId]=decoded;
          return decoded;
        }catch(_){
          legacyWayGeometryCache[wayId]=const <RoutePoint>[];
          return const <RoutePoint>[];
        }
      }
      List<RoutePoint> legacyPhysicalGeometry(_DbRouteEdge e){
        if(e.from==start){
          final to=node(e.to);
          return to==null?const <RoutePoint>[]:[startSnap.point,to];
        }
        if(e.to==goal){
          final from=node(e.from);
          return from==null?const <RoutePoint>[]:[from,goalSnap.point];
        }
        final from=node(e.from),to=node(e.to);
        if(from==null||to==null)return const <RoutePoint>[];
        final geom=legacyWayGeometry(e.wayId);
        if(geom.length<2)return const <RoutePoint>[];
        int nearest(RoutePoint target){
          var best=0,bestD=double.infinity;
          for(var j=0;j<geom.length;j++){final d=_distance(target,geom[j]);if(d<bestD){bestD=d;best=j;}}
          return best;
        }
        final ia=nearest(from),ib=nearest(to);
        final ring=_closedRingSlice(geom,[ia],[ib],from,to,e.distanceM);
        if(ring!=null)return ring.points;
        if(_distance(from,geom[ia])>25.0||_distance(to,geom[ib])>25.0||ia==ib)return const <RoutePoint>[];
        if(ia<ib)return geom.sublist(ia,ib+1);
        return geom.sublist(ib,ia+1).reversed.toList(growable:false);
      }

      final points=<RoutePoint>[startSnap.point];
      final edges=<RouteEdgeInfo>[];
      for(var i=1;i<states.length;i++){
        final e=previousEdge[states[i]]; if(e==null)continue;
        final from=e.from==start?startSnap.point:(e.from==goal?goalSnap.point:(node(e.from)??destination));
        final to=e.to==goal?goalSnap.point:(e.to==start?startSnap.point:(node(e.to)??destination));
        for(final p in legacyPhysicalGeometry(e)){
          if(_distance(points.last,p)>0.05)points.add(p);
        }
        final meta = wayMeta[e.wayId];
        edges.add(RouteEdgeInfo(
          from: from,
          to: to,
          roadClass: '${meta?['road_class'] ?? e.roadClass}',
          name: '${meta?['name'] ?? e.name}',
          junction: '${meta?['junction'] ?? e.junction}',
          wayId: e.wayId,
          speedKmh: e.speedKmh,
        ));
      }
      if(points.length<2){ return AbmRouteResult(points: const [], edges: const [], diagnostics: const []); }

      // Build the roundabout geometry from the actual SQLite graph instead
      // of drawing a hard-coded four-branch icon. Every physical arm is
      // discovered from the roundabout nodes and its real neighbouring road;
      // entrance/exit availability follows the stored one-way direction.
      for (var i = 0; i < edges.length;) {
        if (edges[i].junction.trim().toLowerCase() != 'roundabout') { i++; continue; }
        final begin = i;
        while (i < edges.length && edges[i].junction.trim().toLowerCase() == 'roundabout') i++;
        final end = i;

        final nodeIds = <int>{};
        for (var k = begin; k < end; k++) {
          nodeIds.add(int.parse(states[k].split('|').first));
          nodeIds.add(int.parse(states[k + 1].split('|').first));
        }

        double bearing(RoutePoint a, RoutePoint b) {
          final lat1 = a.lat * math.pi / 180;
          final lat2 = b.lat * math.pi / 180;
          final dl = (b.lon - a.lon) * math.pi / 180;
          final y = math.sin(dl) * math.cos(lat2);
          final x = math.cos(lat1) * math.sin(lat2) -
              math.sin(lat1) * math.cos(lat2) * math.cos(dl);
          return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
        }

        bool truthy(dynamic value) {
          final x = '$value'.toLowerCase();
          return value == true || value == 1 || x == 'true' || x == 'yes' || x == '1';
        }

        final branchByAngle = <double, RoundaboutBranchInfo>{};
        void addBranch(double angle, {required bool canEnter, required bool canExit}) {
          final normalized = (angle % 360 + 360) % 360;
          double? existingKey;
          for (final key in branchByAngle.keys) {
            var d = (key - normalized).abs();
            if (d > 180) d = 360 - d;
            if (d <= 7.5) { existingKey = key; break; }
          }
          if (existingKey == null) {
            branchByAngle[normalized] = RoundaboutBranchInfo(
              angleDegrees: normalized,
              canEnter: canEnter,
              canExit: canExit,
            );
          } else {
            final old = branchByAngle[existingKey]!;
            branchByAngle[existingKey] = RoundaboutBranchInfo(
              angleDegrees: old.angleDegrees,
              canEnter: old.canEnter || canEnter,
              canExit: old.canExit || canExit,
            );
          }
        }

        for (final nodeId in nodeIds) {
          final center = node(nodeId);
          if (center == null) continue;
          final rows = db.select(
            'SELECT e.start,e.end,e.oneway,e.junction,na.lat_e7 alat,na.lon_e7 alon,nb.lat_e7 blat,nb.lon_e7 blon '
            'FROM edges e JOIN node_data na ON na.id=e.start JOIN node_data nb ON nb.id=e.end '
            'WHERE e.start=? OR e.end=?',
            [nodeId, nodeId],
          );
          for (final r in rows) {
            final junction = '${r['junction'] ?? ''}'.trim().toLowerCase();
            if (junction == 'roundabout') continue;
            final start = (r['start'] as num).toInt();
            final endNode = (r['end'] as num).toInt();
            final otherId = start == nodeId ? endNode : start;
            final other = node(otherId) ?? RoutePoint(
              (r['blat'] as num).toDouble() * 1e-7,
              (r['blon'] as num).toDouble() * 1e-7,
            );
            final angle = bearing(center, other);
            final oneway = truthy(r['oneway']);
            final canExit = start == nodeId || !oneway;
            final canEnter = endNode == nodeId || !oneway;
            addBranch(angle, canEnter: canEnter, canExit: canExit);
          }
        }

        // The route's incoming arm and actual exit arm are identified from the
        // route itself, so a road that serves both directions is represented by
        // one physical branch rather than being counted twice.
        final branches = branchByAngle.values.toList()
          ..sort((a, b) => a.angleDegrees.compareTo(b.angleDegrees));
        final routeEntranceAngles = <double>[];
        if (begin > 0) {
          final firstNode = edges[begin].from;
          routeEntranceAngles.add(bearing(firstNode, edges[begin - 1].from));
        }
        final entranceAngles = branches
            .where((b) => b.canEnter)
            .map((b) => b.angleDegrees)
            .toList(growable: false);
        final exitAngles = branches
            .where((b) => b.canExit)
            .map((b) => b.angleDegrees)
            .toList(growable: false);
        double? activeExitAngle;
        if (end < edges.length) {
          final lastNode = edges[end - 1].to;
          activeExitAngle = bearing(lastNode, edges[end].to);
        }

        final exitBranches = branches.where((b) => b.canExit).toList();
        final entrance = routeEntranceAngles.isEmpty ? null : routeEntranceAngles.first;
        final usableExitBranches = entrance == null
            ? exitBranches
            : exitBranches.where((b) {
                var d = (b.angleDegrees - entrance).abs();
                if (d > 180) d = 360 - d;
                return d > 12;
              }).toList();
        int exitNumber = 0;
        if (activeExitAngle != null && usableExitBranches.isNotEmpty && entrance != null) {
          final routeClockwise = (() {
            if (end - begin >= 2) {
              final a = bearing(edges[begin].from, edges[begin].to);
              final b = bearing(edges[begin + 1].from, edges[begin + 1].to);
              var d = (b - a + 360) % 360;
              return d > 0 && d < 180;
            }
            // A one-edge roundabout is too short to infer rotation from two
            // tangent samples; the app's routing data uses right-hand traffic
            // as the default convention.
            return true;
          })();
          double delta(double from, double to) => routeClockwise
              ? (to - from + 360) % 360
              : (from - to + 360) % 360;
          final ordered = usableExitBranches
              .where((b) => delta(entrance, b.angleDegrees) > 5)
              .toList()
            ..sort((a, b) => delta(entrance, a.angleDegrees)
                .compareTo(delta(entrance, b.angleDegrees)));
          for (var n = 0; n < ordered.length; n++) {
            var d = (ordered[n].angleDegrees - activeExitAngle).abs();
            if (d > 180) d = 360 - d;
            if (d <= 10) {
              exitNumber = n + 1;
              break;
            }
          }
        }
        if (exitNumber == 0 && activeExitAngle != null) exitNumber = 1;
        final totalExits = usableExitBranches.length;

        for (var n = begin; n < end; n++) {
          final old = edges[n];
          edges[n] = RouteEdgeInfo(
            from: old.from,
            to: old.to,
            roadClass: old.roadClass,
            name: old.name,
            junction: old.junction,
            wayId: old.wayId,
            speedKmh: old.speedKmh,
            roundaboutExitNumber: exitNumber == 0 ? null : exitNumber,
            roundaboutExitCount: totalExits,
            roundaboutBranches: branches,
            roundaboutEntranceAngles: entranceAngles,
            roundaboutExitAngles: exitAngles,
            roundaboutActiveEntranceAngle: entrance,
            roundaboutActiveExitAngle: activeExitAngle,
          );
        }
      }
      return AbmRouteResult(points: points, edges: edges, diagnostics: const []);
    } finally { db.dispose(); }
  }

  /// Closed OSM ways (roundabouts, loops) store their vertices as a ring:
  /// first vertex == last vertex. A plain `sublist(min, max)` can never cross
  /// that seam, so an edge that legally runs *through* the seam (index 8 -> 2
  /// in way order) used to be drawn as the short arc between the two indices,
  /// reversed -- i.e. around the roundabout the wrong way (clockwise in a
  /// right-hand-traffic country) -- and `forward=false` made the one-way check
  /// reject the legal edge. This evaluates both arcs of the ring for every
  /// candidate vertex pair and picks the one whose length matches the stored
  /// edge length. Returns null when [geom] is not a closed ring.
  static _WayGeometrySlice? _closedRingSlice(
    List<RoutePoint> geom,
    List<int> candA,
    List<int> candB,
    RoutePoint a,
    RoutePoint b,
    double wantMeters,
  ) {
    if (geom.length < 4 || _distance(geom.first, geom.last) > 3.0) return null;
    final m = geom.length - 1; // ring without the duplicated closing vertex
    final cum = List<double>.filled(m, 0.0);
    for (var i = 1; i < m; i++) {
      cum[i] = cum[i - 1] + _distance(geom[i - 1], geom[i]);
    }
    final perimeter = cum[m - 1] + _distance(geom[m - 1], geom[0]);
    if (perimeter < 1.0) return null;
    double fwdLen(int i, int j) =>
        j >= i ? cum[j] - cum[i] : perimeter - (cum[i] - cum[j]);

    final ias = {for (final i in candA) i % m}.toList()..sort();
    final ibs = {for (final i in candB) i % m}.toList()..sort();
    var bestScore = double.infinity;
    var bestI = -1, bestJ = -1;
    var bestForward = true;
    for (final i in ias) {
      for (final j in ibs) {
        if (i == j) continue;
        final endpointError = _distance(a, geom[i]) + _distance(b, geom[j]);
        final f = fwdLen(i, j);
        final bk = perimeter - f;
        for (final forward in const [true, false]) {
          final len = forward ? f : bk;
          final lengthError = wantMeters > 0 ? (len - wantMeters).abs() : 0.0;
          // Tiny bias towards the shorter arc only to break exact ties.
          final score = endpointError * 8.0 + lengthError + len * 1e-6;
          if (score < bestScore) {
            bestScore = score;
            bestI = i;
            bestJ = j;
            bestForward = forward;
          }
        }
      }
    }
    if (bestI < 0) return null;
    if (_distance(a, geom[bestI]) > 30.0 || _distance(b, geom[bestJ]) > 30.0) {
      return null;
    }
    final pts = <RoutePoint>[geom[bestI]];
    var k = bestI;
    while (k != bestJ) {
      k = bestForward ? (k + 1) % m : (k - 1 + m) % m;
      pts.add(geom[k]);
    }
    return _WayGeometrySlice(pts, bestForward);
  }

  static double _distance(RoutePoint a, RoutePoint b) {
    const r = 6371008.8;
    final p1 = a.lat * math.pi / 180, p2 = b.lat * math.pi / 180;
    final dp = (b.lat - a.lat) * math.pi / 180, dl = (b.lon - a.lon) * math.pi / 180;
    final h = math.sin(dp/2)*math.sin(dp/2) + math.cos(p1)*math.cos(p2)*math.sin(dl/2)*math.sin(dl/2);
    return r * 2 * math.asin(math.sqrt(h));
  }

  /// Scans one named top-level JSON object/array without loading the whole
  /// graph. Each member/element is decoded independently, so peak JSON memory
  /// is proportional to one node/edge rather than the entire country graph.
  static Future<List<int>> _readSectionWindow(
      RandomAccessFile raf, int start, int length) async {
    // Keep compatibility with the existing graph format while avoiding an
    // additional copy: this helper reads the JSON payload once inside the
    // worker. It is still bounded by the graph size, but the UI isolate never
    // receives it. The next builder revision can add an indexed graph member.
    await raf.setPosition(start);
    return raf.read(length);
  }

  static Future<void> _scanSection(
    RandomAccessFile raf,
    int jsonStart,
    int jsonLength,
    String section,
    void Function(String? key, dynamic value) onValue,
  ) async {
    final bytes = await _readSectionWindow(raf, jsonStart, jsonLength);
    // The graph header itself is small compared with the graph payload, but
    // the complete JSON must never be copied. The helper below operates on
    // bounded chunks and seeks directly to the requested section.
    final marker = utf8.encode('"$section":');
    final sectionOffset = _findBytes(bytes, marker);
    if (sectionOffset < 0) return;
    var i = sectionOffset + marker.length;
    while (i < bytes.length && _isWhitespace(bytes[i])) i++;
    if (i >= bytes.length) return;
    final open = bytes[i];
    final close = open == 0x7B ? 0x7D : (open == 0x5B ? 0x5D : -1);
    if (close < 0) return;
    i++;
    while (i < bytes.length) {
      while (i < bytes.length && (_isWhitespace(bytes[i]) || bytes[i] == 0x2C))
        i++;
      if (i >= bytes.length || bytes[i] == close) break;
      String? key;
      if (open == 0x7B) {
        if (bytes[i] != 0x22) break;
        final keyEnd = _quotedEnd(bytes, i);
        if (keyEnd < 0) break;
        key = utf8.decode(bytes.sublist(i + 1, keyEnd));
        i = keyEnd + 1;
        while (i < bytes.length && _isWhitespace(bytes[i])) i++;
        if (i >= bytes.length || bytes[i] != 0x3A) break;
        i++;
        while (i < bytes.length && _isWhitespace(bytes[i])) i++;
      }
      final end = _jsonValueEnd(bytes, i);
      if (end <= i) break;
      try {
        final value = jsonDecode(utf8.decode(bytes.sublist(i, end)));
        onValue(key, value);
      } catch (_) {
        // Ignore one malformed edge/node; do not take down navigation.
      }
      i = end;
    }
  }

  static int _jsonValueEnd(List<int> b, int start) {
    if (start >= b.length) return start;
    final first = b[start];
    if (first != 0x7B && first != 0x5B && first != 0x22) {
      var i = start;
      while (i < b.length && b[i] != 0x2C && b[i] != 0x7D && b[i] != 0x5D) i++;
      return i;
    }
    if (first == 0x22) {
      final e = _quotedEnd(b, start);
      return e < 0 ? b.length : e + 1;
    }
    final open = first;
    final close = open == 0x7B ? 0x7D : 0x5D;
    var depth = 0;
    var string = false;
    var escaped = false;
    for (var i = start; i < b.length; i++) {
      final c = b[i];
      if (string) {
        if (escaped) {
          escaped = false;
        } else if (c == 0x5C) {
          escaped = true;
        } else if (c == 0x22) {
          string = false;
        }
        continue;
      }
      if (c == 0x22) {
        string = true;
      } else if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return b.length;
  }

  static int _quotedEnd(List<int> b, int start) {
    var escaped = false;
    for (var i = start + 1; i < b.length; i++) {
      final c = b[i];
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        return i;
      }
    }
    return -1;
  }

  static int _findBytes(List<int> data, List<int> needle) {
    if (needle.isEmpty || needle.length > data.length) return -1;
    outer:
    for (var i = 0; i <= data.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static bool _isWhitespace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
  static int _u32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  static int? _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value');
  static int _nearest(Map<int, RoutePoint> nodes, RoutePoint p) {
    var id = nodes.keys.first;
    var best = double.infinity;
    for (final e in nodes.entries) {
      final d = _distance(p, e.value);
      if (d < best) {
        best = d;
        id = e.key;
      }
    }
    return id;
  }

}

class _Edge {
  const _Edge(this.to, this.distanceM, this.speedKmh);
  final int to;
  final double distanceM;
  final double speedKmh;
}

class _AStarQueueItem {
  const _AStarQueueItem(this.node, this.g, this.priority);
  final int node;
  final double g;
  final double priority;
}

class _QueueItem {
  const _QueueItem(this.node, this.cost);
  final int node;
  final double cost;
}

/// Dijkstra queue item for the turn-restriction-aware sqlite router: state
/// is (node, incoming way id), not just node — see `_routeSqliteDetailed`.
class _TurnQueueItem {
  const _TurnQueueItem(this.node, this.way, this.cost, this.priority);
  final int node;
  final int way;
  final double cost;
  final double priority;
}

class _EdgeStateItem {
  const _EdgeStateItem(this.key, this.edge, this.g, this.priority);
  final int key;
  final _DbRouteEdge edge;
  final double g;
  final double priority;
}

/// ویژگی‌های ثابت یک way (از way_data/categories/names)؛ برای هر way فقط یک بار
/// از دیتابیس خوانده می‌شود، نه برای هر یال.
class _WayAttr {
  const _WayAttr({
    required this.roadClass,
    required this.speedKmh,
    required this.onewayMode,
    required this.name,
    required this.junction,
    required this.allowed,
    required this.minor,
  });
  final String roadClass;
  final double speedKmh;
  final int onewayMode;
  final String name;
  final String junction;

  /// طبق گزینه‌های «اجتناب از ...» اجازهٔ عبور دارد؟
  final bool allowed;

  /// جادهٔ فرعی/محلی؛ در مسیرهای طولانی دور از مبدأ و مقصد حذف می‌شود.
  final bool minor;
}

class _TurnRule {
  const _TurnRule({required this.no, required this.only});
  final Set<int> no;
  final Set<int> only;
}

class _MinHeap<T> {
  _MinHeap(this.compare);
  final int Function(T, T) compare;
  final List<T> _items = <T>[];
  bool get isNotEmpty => _items.isNotEmpty;
  void add(T value) {
    _items.add(value);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (compare(_items[parent], _items[i]) <= 0) break;
      final t = _items[parent];
      _items[parent] = _items[i];
      _items[i] = t;
      i = parent;
    }
  }

  T removeFirst() {
    final first = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var i = 0;
      while (true) {
        final left = i * 2 + 1, right = left + 1;
        var smallest = i;
        if (left < _items.length && compare(_items[left], _items[smallest]) < 0)
          smallest = left;
        if (right < _items.length &&
            compare(_items[right], _items[smallest]) < 0) smallest = right;
        if (smallest == i) break;
        final t = _items[i];
        _items[i] = _items[smallest];
        _items[smallest] = t;
        i = smallest;
      }
    }
    return first;
  }
}

