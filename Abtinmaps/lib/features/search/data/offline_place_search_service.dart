import 'dart:isolate';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

import '../../../abtinmap/abm_map_service.dart';
import '../../../core/geo/geo_types.dart';
import '../../offline_maps/data/map_catalog.dart';
import '../../offline_maps/data/vector_map_service.dart';
import 'place_search_service.dart';

class OfflinePlaceSearchService {
  OfflinePlaceSearchService(this._maps);
  final AbmMapService _maps;
  final VectorMapService _vectorMaps = VectorMapService();

  Future<List<PlaceSearchResult>> searchAcrossRegions(
    String query, {
    required List<MapRegion> orderedRegions,
    double? biasLat,
    double? biasLng,
    int limit = 12,
    bool localOnly = true,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2 || orderedRegions.isEmpty) return const [];
    final merged = <PlaceSearchResult>[];
    var placesOnlyFrom = orderedRegions.length;
    for (var i = 0; i < orderedRegions.length; i++) {
      final region = orderedRegions[i];
      final regionResults = await search(
        trimmed,
        mapFileName: region.abmFileName,
        biasLat: biasLat,
        biasLng: biasLng,
        limit: limit,
        localOnly: localOnly,
      );
      merged.addAll(regionResults);
      if (i == 0 &&
          regionResults.length >= limit &&
          regionResults.any((r) =>
              !r.anchored &&
              (r.distanceMeters ?? double.infinity) < 15000)) {
        placesOnlyFrom = i + 1;
        break;
      }
    }
    for (var j = placesOnlyFrom; j < orderedRegions.length; j++) {
      merged.addAll(await search(
        trimmed,
        mapFileName: orderedRegions[j].abmFileName,
        biasLat: biasLat,
        biasLng: biasLng,
        limit: limit,
        localOnly: localOnly,
        placesOnly: true,
      ));
    }
    return rankPlaceResults(
      trimmed,
      merged,
      limit: limit,
      localRadiusMeters: localOnly && biasLat != null ? 20000 : null,
    );
  }

  Future<List<PlaceSearchResult>> search(
    String query, {
    required String mapFileName,
    double? biasLat,
    double? biasLng,
    String? city,
    int limit = 12,
    bool localOnly = true,
    bool placesOnly = false,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      return const [];
    }
    final container = await _maps.localFile(mapFileName);
    if (!await container.exists()) {
      return const [];
    }
    final id = mapFileName.toLowerCase().endsWith('.abm')
        ? mapFileName.substring(0, mapFileName.length - 4)
        : mapFileName;
    try {
      final artifacts = await _vectorMaps.prepare(containerFile: container, id: id);
      final raw = await Isolate.run(() => _searchSync(
            artifacts.sqliteFile.path,
            trimmed,
            biasLat,
            biasLng,
            (limit * 25).clamp(100, 300),
            placesOnly,
          ));
      for (final line in (raw['trace'] as List).cast<String>()) {
      }
      final rows = (raw['results'] as List).cast<Map>();
      final results = rows.map((r) => PlaceSearchResult(
            name: '${r['name']}',
            region: (r['region'] as String?)?.isEmpty == true
                ? null
                : (placeTypeLabelFor('${r['region']}') ??
                    categoryLabelFor('${r['region']}') ??
                    r['region'] as String?),
            point: LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
            isOffline: true,
            distanceMeters: (r['distance'] as num?)?.toDouble(),
            boosted: r['boost'] == true,
            placeRank: r['placeRank'] as int?,
            anchored: r['anchored'] == true,
          )).toList(growable: false);
      return rankPlaceResults(
        trimmed,
        results,
        limit: limit,
        localRadiusMeters: localOnly && biasLat != null ? 20000 : null,
      );
    } catch (error, stack) {
      return const [];
    }
  }

  static Map<String, dynamic> _searchSync(
    String sqlitePath,
    String query,
    double? biasLat,
    double? biasLng,
    int limit,
    bool placesOnly,
  ) {
    final trace = <String>[];
    trace.add('SQL OPEN path=$sqlitePath');
    final db = sqlite3.open(sqlitePath, mode: OpenMode.readOnly);
    try {
      final objects = db.select(
        "SELECT name,type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name",
      );
      trace.add('SQL SCHEMA objects=${objects.length} names=${objects.map((r) => r['name']).join(',')}');
      final normalized = normalizeSearchText(query);
      trace.add('QUERY normalized="$normalized" candidates=$limit');
      final ftsTerms = normalized
          .split(RegExp(r'\s+'))
          .where((x) => x.isNotEmpty)
          .map((x) => '"${x.replaceAll('"', ' ')}"*')
          .join(' AND ');
      const baseSelect =
          'SELECT f.id, f.kind, n.name, n.name_fa, n.name_en, c.name AS category, '
          '(s.min_lat+s.max_lat)/2 AS lat, (s.min_lon+s.max_lon)/2 AS lon, f.opening_hours ';
      const joins = 'JOIN features f ON f.name_id=n.id '
          'JOIN categories c ON c.id=f.category_id '
          'JOIN spatial s ON s.id=f.id ';
      final hasOrigin = biasLat != null && biasLng != null;
      const latExpr = '((s.min_lat+s.max_lat)/2)';
      const lonExpr = '((s.min_lon+s.max_lon)/2)';
      final distOrder = hasOrigin
          ? '(($latExpr-?)*($latExpr-?)+($lonExpr-?)*($lonExpr-?)*?)'
          : '';
      final cosLat = hasOrigin ? math.cos(biasLat! * math.pi / 180) : 1.0;
      final distArgs = hasOrigin
          ? <Object?>[biasLat, biasLat, biasLng, biasLng, cosLat * cosLat]
          : const <Object?>[];
      var rows = db.select('SELECT 1 WHERE 0');
      final placeRows = <Row>[];
      if (ftsTerms.isNotEmpty) {
        try {
          placeRows.addAll(db.select(
            '${baseSelect}FROM search_fts JOIN names n ON n.id=search_fts.rowid '
            'JOIN features f ON f.name_id=n.id AND f.kind=1 '
            'JOIN categories c ON c.id=f.category_id '
            'JOIN spatial s ON s.id=f.id '
            'WHERE search_fts MATCH ? AND s.min_lat IS NOT NULL AND s.min_lon IS NOT NULL '
            "ORDER BY CASE c.name WHEN 'city' THEN 0 WHEN 'town' THEN 1 "
            "WHEN 'village' THEN 2 WHEN 'suburb' THEN 3 WHEN 'hamlet' THEN 4 "
            "WHEN 'neighbourhood' THEN 5 ELSE 6 END"
            '${hasOrigin ? ', $distOrder' : ''} LIMIT 30',
            [ftsTerms, ...distArgs],
          ));
        } catch (_) {
        }
      }
      trace.add('SQL PLACES rows=${placeRows.length}');
      try {
        if (placesOnly) throw const FormatException('places-only');
        rows = db.select(
          '${baseSelect}FROM search_fts JOIN names n ON n.id=search_fts.rowid $joins'
          'WHERE search_fts MATCH ? AND s.min_lat IS NOT NULL AND s.min_lon IS NOT NULL '
          'ORDER BY ${hasOrigin ? distOrder : 'bm25(search_fts)'} LIMIT ?',
          [ftsTerms, ...distArgs, limit],
        );
      } catch (_) {
      }
      trace.add('SQL FTS rows=${rows.length}');
      if (!placesOnly && rows.isEmpty) {
        final like = '%$normalized%';
        rows = db.select(
          '${baseSelect}FROM names n $joins'
          'WHERE (n.name_fa LIKE ? OR n.name LIKE ? OR n.name_en LIKE ?) '
          'AND s.min_lat IS NOT NULL AND s.min_lon IS NOT NULL '
          '${hasOrigin ? 'ORDER BY $distOrder ' : ''}LIMIT ?',
          [like, like, like, ...distArgs, limit],
        );
        trace.add('SQL LIKE rows=${rows.length}');
      }
      // "city + place" queries (e.g. "تهران شهرک آزادی"): the place name does
      // not contain the city name, so the AND query above finds nothing.
      // Detect a leading/trailing city/town token, search the rest of the
      // query only around that city.
      final anchoredRows = <Row>[];
      _CityAnchor? anchor;
      if (placeRows.isEmpty && rows.isEmpty) {
        anchor = _findAnchor(
          db,
          normalized.split(' ').where((x) => x.isNotEmpty).toList(),
        );
        if (anchor != null) {
          final restTerms = anchor.rest
              .map((x) => '"${x.replaceAll('"', ' ')}"*')
              .join(' AND ');
          final radius = anchor.category == 'city' ? 0.35 : 0.12;
          final cosA = math.cos(anchor.lat * math.pi / 180);
          final dLon = radius / (cosA.abs() < 0.2 ? 0.2 : cosA);
          const bbox = 'AND ((s.min_lat+s.max_lat)/2) BETWEEN ? AND ? '
              'AND ((s.min_lon+s.max_lon)/2) BETWEEN ? AND ? ';
          final bboxArgs = <Object?>[
            anchor.lat - radius,
            anchor.lat + radius,
            anchor.lon - dLon,
            anchor.lon + dLon,
          ];
          const aOrder = '(($latExpr-?)*($latExpr-?)+($lonExpr-?)*($lonExpr-?)*?)';
          final aArgs = <Object?>[
            anchor.lat,
            anchor.lat,
            anchor.lon,
            anchor.lon,
            cosA * cosA,
          ];
          try {
            anchoredRows.addAll(db.select(
              '${baseSelect}FROM search_fts JOIN names n ON n.id=search_fts.rowid '
              'JOIN features f ON f.name_id=n.id AND f.kind=1 '
              'JOIN categories c ON c.id=f.category_id '
              'JOIN spatial s ON s.id=f.id '
              'WHERE search_fts MATCH ? AND s.min_lat IS NOT NULL '
              'AND s.min_lon IS NOT NULL $bbox'
              'ORDER BY $aOrder LIMIT 30',
              [restTerms, ...bboxArgs, ...aArgs],
            ));
          } catch (_) {}
          if (!placesOnly) {
            try {
              anchoredRows.addAll(db.select(
                '${baseSelect}FROM search_fts JOIN names n ON n.id=search_fts.rowid $joins'
                'WHERE search_fts MATCH ? AND s.min_lat IS NOT NULL '
                'AND s.min_lon IS NOT NULL $bbox'
                'ORDER BY $aOrder LIMIT ?',
                [restTerms, ...bboxArgs, ...aArgs, limit],
              ));
            } catch (_) {}
          }
          trace.add('SQL ANCHOR city="${anchor.name}" rest="${anchor.rest.join(' ')}" '
              'rows=${anchoredRows.length}');
        }
      }
      final intents =
          placesOnly ? const <PlaceCategoryIntent>[] : categoryIntentsFor(query);
      final boostedIds = <Object?>{};
      final catRows = <Row>[];
      if (intents.isNotEmpty) {
        final names = [for (final i in intents) ...i.categories];
        final ph = List.filled(names.length, '?').join(',');
        try {
          catRows.addAll(db.select(
            '${baseSelect}FROM features f '
            'JOIN categories c ON c.id=f.category_id '
            'LEFT JOIN names n ON n.id=f.name_id '
            'JOIN spatial s ON s.id=f.id '
            'WHERE c.name IN ($ph) AND s.min_lat IS NOT NULL AND s.min_lon IS NOT NULL '
            '${hasOrigin ? 'ORDER BY $distOrder ' : ''}LIMIT ?',
            [...names, ...distArgs, limit],
          ));
        } catch (_) {}
        for (final r in catRows) {
          boostedIds.add(r['id']);
        }
        trace.add('SQL CATEGORY rows=${catRows.length}');
      }
      final origin = biasLat == null || biasLng == null ? null : LatLng(biasLat, biasLng);
      final results = <Map<String, dynamic>>[];
      var skippedNoPoint = 0;
      final allRows = <MapEntry<Row, bool>>[
        for (final r in anchoredRows) MapEntry(r, true),
        for (final r in [...placeRows, ...catRows, ...rows]) MapEntry(r, false),
      ];
      for (final entry in allRows) {
        final r = entry.key;
        final isAnchored = entry.value;
        final lat = (r['lat'] as num?)?.toDouble();
        final lon = (r['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) {
          skippedNoPoint++;
          continue;
        }
        final point = LatLng(lat, lon);
        final isPlace = (r['kind'] as num?)?.toInt() == 1;
        final distFrom = isAnchored && anchor != null
            ? LatLng(anchor.lat, anchor.lon)
            : origin;
        results.add({
          'anchored': isAnchored,
          'boost': boostedIds.contains(r['id']),
          'placeRank':
              isPlace ? placeRankForCategory('${r['category'] ?? ''}') : null,
          'name': _firstText(r['name_fa'], r['name'], r['name_en']) ??
              categoryLabelFor('${r['category'] ?? ''}') ??
              query,
          'region': '${r['category'] ?? ''}'.trim(),
          'lat': lat,
          'lon': lon,
          'distance': distFrom == null ? null : _distance(distFrom, point),
        });
      }
      final limited = results;
      trace.add('RESULTS usable=${results.length} skippedNoPoint=$skippedNoPoint returned=${limited.length}');
      for (var i = 0; i < limited.length; i++) {
        final r = limited[i];
        trace.add('RESULT[$i] name="${r['name']}" category="${r['region']}" '
            'point=${(r['lat'] as num).toStringAsFixed(6)},${(r['lon'] as num).toStringAsFixed(6)} '
            'distanceM=${(r['distance'] as num?)?.toStringAsFixed(1) ?? '-'}');
      }
      return {'results': limited, 'trace': trace};
    } catch (error, stack) {
      trace.add('ERROR SQL_POI error=$error\n$stack');
      return {'results': const [], 'trace': trace};
    } finally {
      db.dispose();
    }
  }

  /// Finds a city/town named by 1–2 leading or trailing tokens of the query.
  static _CityAnchor? _findAnchor(Database db, List<String> tokens) {
    if (tokens.length < 2) return null;
    final maxLen = math.min(2, tokens.length - 1);
    final names = <String>[];
    final rests = <List<String>>[];
    for (var len = maxLen; len >= 1; len--) {
      names.add(tokens.sublist(0, len).join(' '));
      rests.add(tokens.sublist(len));
      names.add(tokens.sublist(tokens.length - len).join(' '));
      rests.add(tokens.sublist(0, tokens.length - len));
    }
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final phrase = name
          .split(' ')
          .map((x) => '"${x.replaceAll('"', ' ')}"')
          .join(' ');
      try {
        final found = db.select(
          'SELECT n.name, n.name_fa, n.name_en, c.name AS category, '
          '(s.min_lat+s.max_lat)/2 AS lat, (s.min_lon+s.max_lon)/2 AS lon '
          'FROM search_fts JOIN names n ON n.id=search_fts.rowid '
          'JOIN features f ON f.name_id=n.id AND f.kind=1 '
          'JOIN categories c ON c.id=f.category_id '
          'JOIN spatial s ON s.id=f.id '
          "WHERE search_fts MATCH ? AND c.name IN ('city','town') "
          'AND s.min_lat IS NOT NULL AND s.min_lon IS NOT NULL '
          "ORDER BY CASE c.name WHEN 'city' THEN 0 ELSE 1 END LIMIT 20",
          [phrase],
        );
        for (final r in found) {
          final exact = [r['name_fa'], r['name'], r['name_en']]
              .any((v) => v != null && normalizeSearchText('$v') == name);
          if (!exact) continue;
          return _CityAnchor(
            name,
            (r['lat'] as num).toDouble(),
            (r['lon'] as num).toDouble(),
            '${r['category']}',
            rests[i],
          );
        }
      } catch (_) {}
    }
    return null;
  }

  static String? _firstText(Object? a, Object? b, Object? c) {
    for (final value in [a, b, c]) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static double _distance(LatLng a, LatLng b) {
    const r = 6371008.8;
    final p1 = a.latitude * 3.141592653589793 / 180;
    final p2 = b.latitude * 3.141592653589793 / 180;
    final dp = (b.latitude - a.latitude) * 3.141592653589793 / 180;
    final dl = (b.longitude - a.longitude) * 3.141592653589793 / 180;
    final h = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }
}

class _CityAnchor {
  const _CityAnchor(this.name, this.lat, this.lon, this.category, this.rest);
  final String name;
  final double lat;
  final double lon;
  final String category;
  final List<String> rest;
}
