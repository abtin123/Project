import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../features/routing/data/routing_service.dart'
    show RouteAlert, RouteAlertType;
import 'abm_models.dart' show AbmKlass;

/// سیستم نمایشِ عوارض جاده‌ای (دوربین، محدودیت سرعت، سرعت‌گیر، هشدارها) روی نقشه.
///
/// اصل طراحی: «MapLibre تصمیم می‌گیرد، نه ویجت».
///  * همهٔ عوارض در **یک** GeoJSON source به نام [sourceId] هستند و با
///    **Symbol Layer** رسم می‌شوند (نه Marker/Annotation).
///  * هر نوع عارضه یک لایهٔ جدا دارد؛ ترتیبِ لایه‌ها = اولویتِ collision
///    (MapLibre از بالاترین لایه شروع به جانمایی می‌کند و آیکنی که با آیکنِ
///    قبلی برخورد کند حذف می‌شود).
///  * `minzoom/maxzoom`، اندازهٔ آیکن بر حسب zoom، `icon-padding` و
///    `symbol-sort-key` همه در خودِ Style Layer تعریف می‌شوند.
///  * یک فیلتر `step` روی zoom، ویژگیِ `mz` هر عارضه را با zoom فعلی مقایسه
///    می‌کند تا با زوم‌کردن، عوارضِ مخفی‌شده کم‌کم ظاهر شوند.
///  * `mz` یک‌بار هنگام بارگذاری داده (در Isolate) با یک الگوریتم grid-thinning
///    بر اساس تراکم محاسبه می‌شود؛ پس هنگام زوم/حرکت هیچ Sprite ای ساخته یا
///    حذف نمی‌شود و فقط GPU فیلتر را دوباره ارزیابی می‌کند.
abstract final class RoadHazards {
  static const String sourceId = 'abm-hazards';
  static const String layerPrefix = 'abm-hz-';

  /// زیر این zoom هیچ عارضه‌ای نمایش داده نمی‌شود، پس بارگذاری هم انجام نمی‌شود.
  static const double minLoadZoom = 10.5;

  /// نقشه حداکثر تا zoom 18 باز می‌شود؛ جزئیات کامل همان‌جا فعال است.
  static const int maxDetailZoom = 18;

  /// ترتیب = از «اولویت بالا» به «اولویت پایین».
  static const List<RoadHazardSpec> specs = <RoadHazardSpec>[
    // خیلی مهم: زودتر ظاهر می‌شوند و در collision حق تقدم دارند.
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

    // متوسط: از زوم شهری به بعد.
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

    // فرعی: زیر نام خیابان‌ها و فقط در زوم‌های بالاتر.
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

  // ---------------------------------------------------------------------
  // دسته‌بندیِ دادهٔ خام (categories.name / poi.category در SQLite آبتین)
  // ---------------------------------------------------------------------

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

  /// این POIها از لایهٔ عمومیِ `poi-points` حذف می‌شوند و فقط با لایه‌های
  /// hazard رسم می‌شوند (جلوگیری از دو بار نمایش + آیکن عمومیِ `abm-poi`).
  static bool isHazardCategory(Object? raw) => kindForCategory(raw) != null;

  /// کدام نوع‌ها با توجه به تیک‌های «دستهٔ POI» در تنظیمات دیده شوند.
  /// null = همه‌ی دسته‌ها روشن است.
  static Set<String> visibleKinds(Set<int>? visibleKlasses) => <String>{
        for (final s in specs)
          if (visibleKlasses == null ||
              s.poiGroup == null ||
              visibleKlasses.contains(s.poiGroup))
            s.id,
      };

  // ---------------------------------------------------------------------
  // Style: source + layerها (در AbmStyleAssets.resolve فراخوانی می‌شود)
  // ---------------------------------------------------------------------

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
    // specs از پراولویت به کم‌اولویت است؛ در آرایهٔ style لایهٔ بالاتر
    // (آخر) اول جانمایی می‌شود، پس معکوس اضافه می‌کنیم.
    for (final spec in specs.reversed) {
      (spec.tier == RoadHazardTier.minor ? minor : critical)
          .add(_layerFor(spec));
    }

    // عوارض فرعی: بالاتر از POI، پایین‌تر از نام خیابان‌ها (برچسب‌ها برنده‌اند).
    var minorAt = layers.indexWhere((l) =>
        l is Map &&
        (l['id'] == 'highway-name-path' || l['id'] == 'abm-road-major-labels'));
    if (minorAt < 0) minorAt = layers.length;
    layers.insertAll(minorAt, minor);
    // عوارض مهم: بالاترین لایه‌ها => اول جانمایی می‌شوند و هیچ برچسبی روی
    // دوربین/محدودیت سرعت نمی‌نشیند.
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
        // collision / decluttering توسط خودِ MapLibre
        'icon-allow-overlap': false,
        'icon-ignore-placement': false,
        'icon-optional': false,
        'icon-padding': spec.padding,
        'icon-pitch-alignment': 'viewport',
        'icon-rotation-alignment': 'viewport',
        'symbol-sort-key': <dynamic>['get', 'sk'],
      },
      'paint': <String, dynamic>{
        // در zoom پایین ظریف‌تر؛ در zoom بالا کاملاً خوانا.
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

  /// `zoom` در فیلتر فقط به‌عنوان ورودیِ یک `step` سطح‌بالا مجاز است.
  /// خروجیِ هر پله: «ویژگیِ mz این عارضه از zoom فعلی بیشتر نباشد».
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

  // ---------------------------------------------------------------------
  // ساخت GeoJSON با dedupe + grid-thinning بر اساس تراکم
  // ---------------------------------------------------------------------

  /// ورودی: همهٔ عوارض (SQLite viewport + هشدارهای زنده). خروجی: FeatureCollection
  /// با ویژگی‌های `kind`, `mz`, `sk`, `limit`, `name`. تابع خالص و Isolate-safe است.
  static Map<String, dynamic> compose(List<RoadHazard> input) {
    // 1) dedupe: هر نوع در سلول ~۱۲ متری فقط یک‌بار.
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

    // 2) thinning: هر عارضه کم‌ترین zoomی را می‌گیرد که در آن سلولش آزاد است.
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
            // کمتر = اولویت بیشتر در جانمایی (symbol-sort-key)
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

  /// سلولِ شبکه با اندازهٔ [spacingPx] پیکسل در zoom داده‌شده (کاشی ۵۱۲ پیکسلی).
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

  // ---------------------------------------------------------------------
  // بارگذاری از SQLite آبتین (داخل Isolate صدا زده شود)
  // ---------------------------------------------------------------------

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

    // الف) مسیر سریع: شروع از ایندکس R-tree (`spatial`). view `poi` ستون‌های
    // lat/lon را محاسبه می‌کند و SQLite مجبور بود در هر refresh کل جدول
    // features را اسکن کند — حتی وقتی در دید هیچ دوربینی نبود.
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

    // ب) فقط برای نقشه‌های قدیمی که R-tree ندارند: view `poi`.
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

    // ج) تابلوی محدودیت سرعت از `way_data.speed_kmh` راه‌های اصلی.
    if (zoom >= 11.5) {
      try {
        out.addAll(_speedLimitSigns(db, box));
      } catch (_) {/* graph-less / legacy ABM */}
    }
    return out;
  }

  /// فقط راه‌های اصلی (class_id ۱ تا ۵: آزادراه .. فرعی۲). برای هر way یک تابلو
  /// در ابتدا و سپس هر چند صد متر؛ تراکم‌زدایی بعداً در [compose] انجام می‌شود.
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

  /// در Sprite Sheet جدید فقط 30/60/80 وجود دارد؛ مقدار دیگری را عمداً
  /// با عدد اشتباه نمایش نمی‌دهیم.
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

/// تنظیمات یک نوع عارضه. `id` همان `kind` در GeoJSON و پسوند نام Sprite
/// (`abm-hz-<id>`) و نام لایه است.
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

  /// کمتر = مهم‌تر (جانمایی و collision).
  final int priority;
  final int minZoom;
  final int maxZoom;

  /// حداقل فاصلهٔ صفحه‌ایِ دو عارضه از یک نوع در هر zoom (پیکسل).
  final double spacingPx;

  /// جفت‌های [zoom, iconSize, zoom, iconSize, ...]
  final List<double> iconSize;
  final String anchor;
  final double offsetY;
  final double padding;
  final RoadHazardTier tier;

  /// کلید دستهٔ POI در تنظیمات (AbmKlass) که این نوع را روشن/خاموش می‌کند.
  final int? poiGroup;
}

/// یک عارضهٔ خام (قبل از thinning).
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

  /// فقط برای `speed_limit` (km/h گردشده).
  final int? limit;

  /// کمترین zoomی که این عارضه مجاز است ظاهر شود (مثلاً تابلو در راه فرعی دیرتر).
  final double? baseZoom;

  /// اولویتِ داخلِ یک نوع (۰ = مهم‌ترین).
  final int rank;

  /// هشدارهای زندهٔ مسیر → عارضهٔ نقشه. دوربین، سرعت‌گیر و چراغ راهنما
  /// همگی (و ایست بازرسی/پلیس) وارد همین source می‌شوند.
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
