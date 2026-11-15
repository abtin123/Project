import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../features/routing/data/routing_service.dart'
    show RouteAlert, RouteAlertType;
import 'abm_models.dart' show AbmKlass;

abstract final class RoadHazards {
  static const String sourceId = 'abm-hazards';
  static const String layerPrefix = 'abm-hz-';

  static const double minLoadZoom = 10.5;

  static const int maxDetailZoom = 18;

  static const List<RoadHazardSpec> specs = <RoadHazardSpec>[
    RoadHazardSpec(
      id: 'speed_camera',
      priority: 10,
      minZoom: 11,
      spacingPx: 50,
      iconSize: [11, 0.30, 14, 0.40, 17, 0.52, 20, 0.62],
      padding: 9,
      poiGroup: AbmKlass.poiSpeedCamera,
    ),
    RoadHazardSpec(
      id: 'section_camera',
      priority: 12,
      minZoom: 12,
      spacingPx: 52,
      iconSize: [12, 0.28, 14, 0.38, 17, 0.50, 20, 0.60],
      padding: 9,
      poiGroup: AbmKlass.poiSpeedCamera,
    ),
    RoadHazardSpec(
      id: 'speed_limit',
      priority: 20,
      minZoom: 12,
      spacingPx: 82,
      iconSize: [12, 0.28, 14, 0.36, 17, 0.46, 20, 0.56],
      padding: 10,
    ),
    RoadHazardSpec(
      id: 'camera',
      priority: 30,
      minZoom: 13,
      spacingPx: 48,
      iconSize: [13, 0.28, 15, 0.38, 17, 0.48, 20, 0.58],
      padding: 8,
      poiGroup: AbmKlass.poiSpeedCamera,
    ),
    RoadHazardSpec(
      id: 'police',
      priority: 34,
      minZoom: 13,
      spacingPx: 50,
      iconSize: [13, 0.28, 15, 0.38, 17, 0.48, 20, 0.58],
      padding: 8,
    ),
    RoadHazardSpec(
      id: 'traffic_light',
      priority: 36,
      minZoom: 13,
      spacingPx: 44,
      iconSize: [13, 0.25, 15, 0.34, 17, 0.44, 20, 0.54],
      padding: 7,
      poiGroup: AbmKlass.poiTrafficLight,
    ),

    RoadHazardSpec(
      id: 'speed_bump',
      priority: 50,
      minZoom: 14,
      spacingPx: 44,
      iconSize: [14, 0.24, 16, 0.33, 18, 0.42, 20, 0.50],
      padding: 7,
      poiGroup: AbmKlass.poiSpeedBump,
    ),
    RoadHazardSpec(
      id: 'uneven_road',
      priority: 56,
      minZoom: 15,
      spacingPx: 46,
      iconSize: [15, 0.23, 17, 0.32, 20, 0.44],
      padding: 6,
      poiGroup: AbmKlass.poiSpeedBump,
      tier: RoadHazardTier.minor,
    ),

    RoadHazardSpec(
      id: 'road_works',
      priority: 65,
      minZoom: 15,
      spacingPx: 46,
      iconSize: [15, 0.23, 17, 0.33, 20, 0.45],
      padding: 6,
      tier: RoadHazardTier.minor,
    ),
    RoadHazardSpec(
      id: 'curve',
      priority: 70,
      minZoom: 16,
      spacingPx: 46,
      iconSize: [16, 0.24, 18, 0.34, 20, 0.45],
      padding: 6,
      tier: RoadHazardTier.minor,
    ),
    RoadHazardSpec(
      id: 'narrow_road',
      priority: 72,
      minZoom: 16,
      spacingPx: 46,
      iconSize: [16, 0.24, 18, 0.34, 20, 0.45],
      padding: 6,
      tier: RoadHazardTier.minor,
    ),
    RoadHazardSpec(
      id: 'slippery',
      priority: 74,
      minZoom: 16,
      spacingPx: 46,
      iconSize: [16, 0.24, 18, 0.34, 20, 0.45],
      padding: 6,
      tier: RoadHazardTier.minor,
    ),
    RoadHazardSpec(
      id: 'pedestrian',
      priority: 80,
      minZoom: 17,
      spacingPx: 40,
      iconSize: [17, 0.24, 18, 0.32, 20, 0.42],
      padding: 5,
      tier: RoadHazardTier.minor,
    ),
    RoadHazardSpec(
      id: 'accident',
      priority: 84,
      minZoom: 17,
      spacingPx: 48,
      iconSize: [17, 0.24, 18, 0.33, 20, 0.44],
      padding: 6,
      tier: RoadHazardTier.minor,
    ),
  ];

  static final Map<String, RoadHazardSpec> _specById = <String, RoadHazardSpec>{
    for (final s in specs) s.id: s,
  };


  static const Map<String, String> _categoryKinds = <String, String>{
    'speed_camera': 'speed_camera',
    'enforcement': 'speed_camera',
    'average_speed_camera': 'section_camera',
    'section_control': 'section_camera',
    'traffic_camera': 'camera',
    'red_light_camera': 'camera',
    'surveillance_camera': 'camera',
    'traffic_signals': 'traffic_light',
    'traffic_signal': 'traffic_light',
    'traffic_light': 'traffic_light',
    'traffic_calming': 'speed_bump',
    'speed_bump': 'speed_bump',
    'speed_hump': 'speed_bump',
    'bump': 'speed_bump',
    'hump': 'speed_bump',
    'table': 'speed_bump',
    'cushion': 'speed_bump',
    'rumble_strip': 'uneven_road',
    'uneven_road': 'uneven_road',
    'rough_road': 'uneven_road',
    'crossing': 'pedestrian',
    'pedestrian_crossing': 'pedestrian',
    'construction': 'road_works',
    'road_works': 'road_works',
    'sharp_curve': 'curve',
    'curve': 'curve',
    'slippery': 'slippery',
    'narrow_road': 'narrow_road',
    'road_narrows': 'narrow_road',
    'accident': 'accident',
    'crash': 'accident',
  };

  static String? kindForCategory(Object? raw) {
    final key = '${raw ?? ''}'.trim().toLowerCase();
    if (key.isEmpty) return null;
    return _categoryKinds[key];
  }

  static bool isHazardCategory(Object? raw) => kindForCategory(raw) != null;

  static Set<String> visibleKinds(Set<int>? visibleKlasses) => <String>{
        for (final s in specs)
          if (visibleKlasses == null ||
              s.poiGroup == null ||
              visibleKlasses.contains(s.poiGroup))
            s.id,
      };


  static void applyToStyle(Map<String, dynamic> style) {
    final sources = Map<String, dynamic>.from(
        (style['sources'] as Map?)?.map((k, v) => MapEntry('$k', v)) ??
            const <String, dynamic>{});
    sources[sourceId] = <String, dynamic>{
      'type': 'geojson',
      'data': <String, dynamic>{
        'type': 'FeatureCollection',
        'features': <dynamic>[],
      },
    };
    style['sources'] = sources;

    final layers = List<dynamic>.from(style['layers'] as List? ?? const []);
    layers.removeWhere(
        (l) => l is Map && '${l['id']}'.startsWith(layerPrefix));

    final minor = <Map<String, dynamic>>[];
    final critical = <Map<String, dynamic>>[];
    for (final spec in specs.reversed) {
      (spec.tier == RoadHazardTier.minor ? minor : critical)
          .add(_layerFor(spec));
    }

    var minorAt = layers.indexWhere((l) =>
        l is Map &&
        (l['id'] == 'highway-name-path' || l['id'] == 'abm-road-major-labels'));
    if (minorAt < 0) minorAt = layers.length;
    layers.insertAll(minorAt, minor);
    layers.addAll(critical);
    style['layers'] = layers;
  }

  static Map<String, dynamic> _layerFor(RoadHazardSpec spec) {
    final isLimit = spec.id == 'speed_limit';
    return <String, dynamic>{
      'id': '$layerPrefix${spec.id}',
      'type': 'symbol',
      'source': sourceId,
      'minzoom': spec.minZoom,
      'maxzoom': spec.maxZoom,
      'filter': <dynamic>[
        'all',
        <dynamic>['==', <dynamic>['get', 'kind'], spec.id],
        _zoomGate(spec),
      ],
      'layout': <String, dynamic>{
        'icon-image': isLimit
            ? <dynamic>[
                'concat',
                '${layerPrefix}limit-',
                <dynamic>['to-string', <dynamic>['get', 'limit']],
              ]
            : '$layerPrefix${spec.id == 'section_camera' ? 'camera' : spec.id}',
        'icon-size': <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          ...spec.iconSize,
        ],
        'icon-anchor': spec.anchor,
        'icon-offset': <double>[0, spec.offsetY],
        'icon-allow-overlap': false,
        'icon-ignore-placement': false,
        'icon-optional': false,
        'icon-padding': spec.padding,
        'icon-pitch-alignment': 'viewport',
        'icon-rotation-alignment': 'viewport',
        'symbol-sort-key': <dynamic>['get', 'sk'],
      },
      'paint': <String, dynamic>{
        'icon-opacity': <dynamic>[
          'interpolate',
          <dynamic>['linear'],
          <dynamic>['zoom'],
          spec.minZoom,
          0.82,
          spec.minZoom + 3,
          1.0,
        ],
      },
    };
  }

  static List<dynamic> _zoomGate(RoadHazardSpec spec) {
    final first = spec.minZoom;
    final last = maxDetailZoom;
    return <dynamic>[
      'step',
      <dynamic>['zoom'],
      false,
      for (var z = first; z < last; z++) ...<dynamic>[
        z,
        <dynamic>['<=', <dynamic>['get', 'mz'], z],
      ],
      last,
      true,
    ];
  }


  static Map<String, dynamic> compose(List<RoadHazard> input) {
    final seen = <String>{};
    final byKind = <String, List<RoadHazard>>{};
    for (final h in input) {
      final spec = _specById[h.kind];
      if (spec == null) continue;
      if (h.kind == 'speed_limit' && h.limit == null) continue;
      final key =
          '${h.kind}:${(h.lat * 9000).round()}:${(h.lon * 9000).round()}';
      if (!seen.add(key)) continue;
      byKind.putIfAbsent(h.kind, () => <RoadHazard>[]).add(h);
    }

    final features = <Map<String, dynamic>>[];
    for (final entry in byKind.entries) {
      final spec = _specById[entry.key]!;
      final list = entry.value
        ..sort((a, b) {
          final r = a.rank.compareTo(b.rank);
          if (r != 0) return r;
          final la = a.lat.compareTo(b.lat);
          return la != 0 ? la : a.lon.compareTo(b.lon);
        });
      final full = maxDetailZoom;
      final occupied = <int, Set<int>>{
        for (var z = spec.minZoom; z <= full; z++) z: <int>{},
      };
      for (final h in list) {
        final start = math.max(spec.minZoom, (h.baseZoom ?? 0).ceil());
        var assigned = full;
        for (var z = math.min(start, full); z <= full; z++) {
          if (!occupied[z]!.contains(_cell(h, z, spec.spacingPx))) {
            assigned = z;
            break;
          }
        }
        for (var z = assigned; z <= full; z++) {
          occupied[z]!.add(_cell(h, z, spec.spacingPx));
        }
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[h.lon, h.lat],
          },
          'properties': <String, dynamic>{
            'kind': h.kind,
            'mz': assigned,
            'sk': spec.priority * 10 + h.rank.clamp(0, 9).toInt(),
            if (h.limit != null) 'limit': h.limit,
            if (h.name.isNotEmpty) 'name': h.name,
          },
        });
      }
    }
    return <String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    };
  }

  static int _cell(RoadHazard h, int zoom, double spacingPx) {
    final latRad = h.lat * math.pi / 180.0;
    final metersPerPx =
        40075016.686 * math.cos(latRad).abs().clamp(0.05, 1.0) /
            (512.0 * math.pow(2.0, zoom));
    final size = spacingPx * metersPerPx;
    final x = (h.lon * 111320.0 * math.cos(latRad) / size).floor();
    final y = (h.lat * 110574.0 / size).floor();
    const off = 0x4000000; // 2^26
    return (x + off) * 0x8000000 + (y + off); // کلید یکتا در ۶۴ بیت
  }


  static List<RoadHazard> loadFromSqlite(
    sqlite.Database db, {
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double zoom,
  }) {
    if (zoom < minLoadZoom) return const <RoadHazard>[];
    final out = <RoadHazard>[];
    final box = <Object>[minLon, maxLon, minLat, maxLat];

    final placeholders =
        List<String>.filled(_categoryKinds.length, '?').join(',');
    var rtreeOk = false;
    try {
      final rows = db.select(
        'SELECT c.name category, n.name, n.name_fa, s.min_lat lat, s.min_lon lon '
        'FROM spatial s JOIN features f ON f.id=s.id AND f.kind=0 '
        'JOIN categories c ON c.id=f.category_id '
        'LEFT JOIN names n ON n.id=f.name_id '
        'WHERE c.name IN ($placeholders) '
        'AND s.max_lon>=? AND s.min_lon<=? AND s.max_lat>=? AND s.min_lat<=? '
        'LIMIT 8000',
        <Object>[..._categoryKinds.keys, ...box],
      );
      rtreeOk = true;
      for (final r in rows) {
        final kind = kindForCategory(r['category']);
        final lat = (r['lat'] as num?)?.toDouble();
        final lon = (r['lon'] as num?)?.toDouble();
        if (kind == null || lat == null || lon == null) continue;
        out.add(RoadHazard(
          kind: kind,
          lon: lon,
          lat: lat,
          name: _firstNonEmpty(<Object?>[r['name_fa'], r['name']]),
        ));
      }
    } catch (_) {/* نقشهٔ قدیمی بدون spatial/features */}

    if (!rtreeOk) {
      try {
        final rows = db.select(
          'SELECT name,name_fa,category,lat,lon FROM poi '
          'WHERE category IN ($placeholders) '
          'AND lon>=? AND lon<=? AND lat>=? AND lat<=? LIMIT 8000',
          <Object>[..._categoryKinds.keys, ...box],
        );
        for (final r in rows) {
          final kind = kindForCategory(r['category']);
          final lat = (r['lat'] as num?)?.toDouble();
          final lon = (r['lon'] as num?)?.toDouble();
          if (kind == null || lat == null || lon == null) continue;
          out.add(RoadHazard(
            kind: kind,
            lon: lon,
            lat: lat,
            name: _firstNonEmpty(<Object?>[r['name_fa'], r['name']]),
          ));
        }
      } catch (_) {}
    }

    if (zoom >= 11.5) {
      try {
        out.addAll(_speedLimitSigns(db, box));
      } catch (_) {/* graph-less / legacy ABM */}
    }
    return out;
  }

  static List<RoadHazard> _speedLimitSigns(
      sqlite.Database db, List<Object> box) {
    final rows = db.select(
      'SELECT DISTINCT s.id sid, s.way_id, w.class_id, w.speed_kmh, '
      'na.lat_e7 alat, na.lon_e7 alon, nb.lat_e7 blat, nb.lon_e7 blon '
      'FROM road_index r JOIN segments s ON s.id BETWEEN r.seg_from AND r.seg_to '
      'JOIN way_data w ON w.way_id=s.way_id '
      'JOIN node_data na ON na.id=s.a JOIN node_data nb ON nb.id=s.b '
      'WHERE w.class_id BETWEEN 1 AND 5 AND w.speed_kmh>0 '
      'AND r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=? '
      'ORDER BY s.way_id,s.id LIMIT 30000',
      box,
    );
    const intervalM = <int, double>{1: 3000, 2: 2500, 3: 2000, 4: 1500, 5: 1000};
    const baseZoom = <int, double>{1: 12, 2: 12, 3: 13, 4: 14, 5: 15};
    final out = <RoadHazard>[];
    int? currentWay;
    var acc = 0.0;
    var nextAt = 0.0;
    for (final r in rows) {
      final way = (r['way_id'] as num).toInt();
      if (way != currentWay) {
        currentWay = way;
        acc = 0.0;
        nextAt = 0.0;
      }
      final cls = (r['class_id'] as num).toInt();
      final aLat = (r['alat'] as num).toDouble() * 1e-7;
      final aLon = (r['alon'] as num).toDouble() * 1e-7;
      final bLat = (r['blat'] as num).toDouble() * 1e-7;
      final bLon = (r['blon'] as num).toDouble() * 1e-7;
      final segLen = _haversineM(aLat, aLon, bLat, bLon);
      if (acc >= nextAt) {
        final limit = limitSpriteValue((r['speed_kmh'] as num).toInt());
        if (limit != null) {
          out.add(RoadHazard(
            kind: 'speed_limit',
            lon: (aLon + bLon) / 2,
            lat: (aLat + bLat) / 2,
            limit: limit,
            baseZoom: baseZoom[cls] ?? 15,
            rank: (cls - 1).clamp(0, 9).toInt(),
          ));
        }
        nextAt = acc + (intervalM[cls] ?? 1500);
      }
      acc += segLen;
    }
    return out;
  }

  static int? limitSpriteValue(int kmh) {
    const supported = <int>{30, 60, 80};
    return supported.contains(kmh) ? kmh : null;
  }

  static String _firstNonEmpty(List<Object?> values) {
    for (final v in values) {
      final t = '${v ?? ''}'.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  static double _haversineM(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    final dLat = (la2 - la1) * math.pi / 180;
    final dLon = (lo2 - lo1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la1 * math.pi / 180) *
            math.cos(la2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

enum RoadHazardTier { critical, minor }

class RoadHazardSpec {
  const RoadHazardSpec({
    required this.id,
    required this.priority,
    required this.minZoom,
    required this.spacingPx,
    required this.iconSize,
    this.maxZoom = 24,
    this.anchor = 'center',
    this.offsetY = 0,
    this.padding = 8,
    this.tier = RoadHazardTier.critical,
    this.poiGroup,
  });

  final String id;

  final int priority;
  final int minZoom;
  final int maxZoom;

  final double spacingPx;

  final List<double> iconSize;
  final String anchor;
  final double offsetY;
  final double padding;
  final RoadHazardTier tier;

  final int? poiGroup;
}

class RoadHazard {
  const RoadHazard({
    required this.kind,
    required this.lon,
    required this.lat,
    this.name = '',
    this.limit,
    this.baseZoom,
    this.rank = 0,
  });

  final String kind;
  final double lon;
  final double lat;
  final String name;

  final int? limit;

  final double? baseZoom;

  final int rank;

  static RoadHazard? fromAlert(RouteAlert a) {
    final kind = switch (a.type) {
      RouteAlertType.speedCamera => 'speed_camera',
      RouteAlertType.speedBump => 'speed_bump',
      RouteAlertType.trafficLight => 'traffic_light',
      RouteAlertType.policeCheckpoint => 'police',
    };
    if (kind == null) return null;
    return RoadHazard(
      kind: kind,
      lon: a.location.longitude,
      lat: a.location.latitude,
      name: a.name ?? '',
    );
  }
}
