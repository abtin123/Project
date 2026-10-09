import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;



class VectorMapInstallException implements Exception {
  const VectorMapInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AbmBBox {
  const AbmBBox(this.minLon, this.minLat, this.maxLon, this.maxLat);
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
}

class AbmVectorFeature {
  const AbmVectorFeature({
    required this.id,
    required this.layer,
    required this.geometry,
    required this.properties,
    required this.bbox,
    this.renderPriority = 0,
    this.minZoom = 0,
  });
  final int id;
  final String layer;
  final List<List<double>> geometry;
  final Map<String, dynamic> properties;
  final AbmBBox bbox;
  final int renderPriority;
  final double minZoom;

  Map<String, dynamic> toGeoJson() => {
        'type': 'Feature',
        'id': id,
        'geometry': {
          'type': geometry.length == 1 ? 'Point' : 'LineString',
          'coordinates': geometry.length == 1 ? geometry.first : geometry,
        },
        'properties': properties,
      };
}

class VectorMapArtifacts {
  const VectorMapArtifacts({
    required this.sqliteFile,
    required this.metadata,
    required this.mbtilesFile,
  });

  /// province-specific SQLite is the data/query store only: search, POI, road metadata and
  /// routing. It stays on disk and is queried directly when data is needed;
  /// the whole database is never copied into an application-level cache.
  final File sqliteFile;
  final Map<String, dynamic> metadata;

  /// province-specific MBTiles is the cartographic basemap. MapLibre reads it directly for
  /// roads, buildings, landuse, water and boundaries.
  final File mbtilesFile;

}

class _ReadyArtifacts {
  const _ReadyArtifacts(this.sig, this.artifacts);
  final String sig;
  final VectorMapArtifacts artifacts;
}

class VectorMapService {
  /// Keep SQLite read-only and file-backed. Do not configure a large database
  /// cache or mmap the whole country database: indexed queries are executed
  /// directly against the on-disk file. SQLite may still use its normal small
  /// internal page cache as part of query execution.
  static void configureReadOnly(sqlite.Database db) {
    try {
      db.execute('PRAGMA query_only=ON');
      db.execute('PRAGMA temp_store=FILE');
    } catch (_) {}
  }
  final Map<String, Future<VectorMapArtifacts>> _inFlight = <String, Future<VectorMapArtifacts>>{};
  final Map<String, _ReadyArtifacts> _ready = <String, _ReadyArtifacts>{};
  Future<Directory> dataDirectory(String id) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'AbtinMaps', 'maps', id.toUpperCase()));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<bool> isInstalled({required File containerFile}) async {
    try {
      return await containerFile.exists() && await containerFile.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String id) async {
    _ready.clear();
    final d = await dataDirectory(id);
    if (await d.exists()) await d.delete(recursive: true);
  }

  Future<VectorMapArtifacts> prepare({
    required File containerFile,
    required String id,
    void Function(double)? onProgress,
  }) async {
    final key = containerFile.path;
    // Fast path: viewport/routing/search call prepare() many times per second.
    // Reuse the already-validated artifacts while the container is unchanged,
    // instead of re-reading metadata + several stat() calls every time.
    String? sig;
    try {
      final st = await containerFile.stat();
      sig = '$id:${st.size}:${st.modified.millisecondsSinceEpoch}';
      final hit = _ready[key];
      if (hit != null &&
          hit.sig == sig &&
          hit.artifacts.sqliteFile.existsSync() &&
          hit.artifacts.mbtilesFile.existsSync()) {
        onProgress?.call(1);
        return hit.artifacts;
      }
    } catch (_) {}
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _prepareInternal(containerFile: containerFile, id: id, onProgress: onProgress);
    _inFlight[key] = future;
    try {
      final artifacts = await future;
      if (sig != null) _ready[key] = _ReadyArtifacts(sig, artifacts);
      return artifacts;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<VectorMapArtifacts> _prepareInternal({
    required File containerFile,
    required String id,
    void Function(double)? onProgress,
  }) async {
    if (!await isInstalled(containerFile: containerFile)) {
      throw const VectorMapInstallException('Map file is missing or empty.');
    }

    final data = await dataDirectory(id);
    final metadataFile = File(p.join(data.path, 'metadata.json'));
    String? sqliteName;
    String? mbtilesName;
    if (await metadataFile.exists()) {
      try {
        final m = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
        sqliteName = m['database'] as String?;
        mbtilesName = m['tile_file'] as String?;
      } catch (_) {}
    }
    final manifestHint = File(p.join(data.path, '.manifest.json'));
    if (await manifestHint.exists()) {
      try {
        final m = jsonDecode(await manifestHint.readAsString()) as Map<String, dynamic>;
        sqliteName = (m['database'] as String?) ?? sqliteName;
        mbtilesName = (m['tiles'] as String?) ?? mbtilesName;
      } catch (_) {}
    }
    // Legacy ABM v6 packages used map.sqlite/map.mbtiles. They are migrated
    // into the province-specific cache directory on first prepare().
    sqliteName ??= 'map.sqlite';
    mbtilesName ??= 'map.mbtiles';
    var sqliteFile = File(p.join(data.path, sqliteName));
    var mbtilesFile = File(p.join(data.path, mbtilesName));
    final marker = File(p.join(data.path, '.abm-source'));
    final stat = await containerFile.stat();
    const extractionRevision = 'abm-builder-v7-province-stores-v1';
    final sourceMarker = '$extractionRevision:${stat.size}:${stat.modified.millisecondsSinceEpoch}';

    final extractedReady = await sqliteFile.exists() &&
        await sqliteFile.length() > 0 &&
        await metadataFile.exists() &&
        await marker.exists() &&
        (await marker.readAsString()) == sourceMarker &&
        (await mbtilesFile.exists() && await mbtilesFile.length() > 0);

    if (!extractedReady) {
      final tmp = Directory(p.join(data.path, '.extract-${DateTime.now().microsecondsSinceEpoch}'));
      await tmp.create(recursive: true);
      try {
        // ABM is the transport container produced by the current Builder v3.
        // Extract exactly the two runtime stores once: province-specific MBTiles for MapLibre
        // cartography and province-specific SQLite for search/POI/routing. The map is never
        // converted into an application-level vector/GeoJSON basemap cache.
        final extractWatch = Stopwatch()..start();
        // The archive's own manifest decides the real file names (IR-ESF.sqlite,
        // IR-ESF.mbtiles, ...). Never trust the cached/default names here: on a
        // first install or a legacy->v7 migration they differ from the archive.
        final storeNames = await Isolate.run(() => _extractRuntimeStores(containerFile.path, tmp.path));
        sqliteName = storeNames[0];
        mbtilesName = storeNames[1];
        extractWatch.stop();

        final extractedSqlite = File(p.join(tmp.path, sqliteName!));
        _validateSqliteFast(extractedSqlite);
        final extractedMetadata = File(p.join(tmp.path, 'metadata.json'));
        final extractedManifest = File(p.join(tmp.path, 'manifest.json'));
        final extractedMbtiles = File(p.join(tmp.path, mbtilesName!));
        if (!await extractedMetadata.exists() || await extractedMetadata.length() == 0) {
          throw const VectorMapInstallException('ABM metadata.json is missing or empty.');
        }
        final hasMbtiles = await extractedMbtiles.exists() && await extractedMbtiles.length() > 0;
        if (!hasMbtiles) {
          throw const VectorMapInstallException('ABM نقشه فاقد province-specific MBTiles است.');
        }
        if (hasMbtiles) {
          _validateMbtilesFast(extractedMbtiles);
        }
        // All extracted files live in the same filesystem as the final cache.
        // Rename instead of copy: for a large country map this removes a
        // second full disk write/read pass over province-specific MBTiles and province-specific SQLite.
        final oldSqlite = sqliteFile;
        final oldMbtiles = mbtilesFile;
        sqliteFile = File(p.join(data.path, sqliteName!));
        mbtilesFile = File(p.join(data.path, mbtilesName!));
        await _replaceFileFast(extractedSqlite, sqliteFile);
        await _replaceFileFast(extractedMetadata, metadataFile);
        if (await extractedManifest.exists()) {
          await _replaceFileFast(extractedManifest, manifestHint);
        }
        await _replaceFileFast(extractedMbtiles, mbtilesFile);
        // Drop stale stores from a previous naming scheme (e.g. legacy map.sqlite)
        // so migration does not double on-disk size; only inside this province dir.
        for (final old in [oldSqlite, oldMbtiles]) {
          if (old.path != sqliteFile.path && old.path != mbtilesFile.path && await old.exists()) {
            await old.delete();
          }
        }
        await marker.writeAsString(sourceMarker, flush: true);
      } catch (error, stack) {
        if (await marker.exists()) {
          final value = await marker.readAsString();
          if (value == sourceMarker) await marker.delete();
        }
        rethrow;
      } finally {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      }
    } else {
      // Existing extraction is reused; this is not a query cache and no
      // database rebuild/copy happens on map viewport refreshes.
    }

    final metadata = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    final hasMbtiles = await mbtilesFile.exists() && await mbtilesFile.length() > 0;
    final mbtilesBytes = hasMbtiles ? await mbtilesFile.length() : 0;
    onProgress?.call(1);
    return VectorMapArtifacts(
      sqliteFile: sqliteFile,
      metadata: metadata,
      mbtilesFile: mbtilesFile,
    );
  }

  static Future<void> _replaceFileFast(File source, File target) async {
    if (!await source.exists()) {
      throw const VectorMapInstallException('ABM archive is missing a required member.');
    }
    if (await target.exists()) await target.delete();
    // source and target are both under ApplicationSupport/AbtinMaps/maps,
    // therefore rename stays on the same filesystem and is effectively an
    // O(1) metadata operation instead of copying hundreds of MB again.
    await source.rename(target.path);
  }

  static List<String> _extractRuntimeStores(String archivePath, String outputDir) {
    final input = InputFileStream(archivePath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      Map<String, dynamic>? metadata;
      Map<String, dynamic>? manifest;
      for (final entry in archive) {
        final n = entry.name.replaceAll('\\', '/');
        if (!entry.isFile || n.split('/').length != 1) continue;
        if (n == 'metadata.json') {
          metadata = jsonDecode(utf8.decode(entry.readBytes()!)) as Map<String, dynamic>;
        } else if (n == 'manifest.json') {
          manifest = jsonDecode(utf8.decode(entry.readBytes()!)) as Map<String, dynamic>;
        }
      }
      if (metadata == null) {
        throw const VectorMapInstallException('ABM metadata.json is missing.');
      }
      final sqliteName = (manifest?['database'] as String?) ?? (metadata['database'] as String?) ?? 'map.sqlite';
      final mbtilesName = (manifest?['tiles'] as String?) ?? (metadata['tile_file'] as String?) ?? 'map.mbtiles';
      String safe(String value, String ext) {
        final normalized = value.replaceAll('\\', '/');
        if (normalized != p.basename(normalized) || !normalized.toLowerCase().endsWith(ext)) {
          throw VectorMapInstallException('Invalid ABM runtime filename: $value');
        }
        return normalized;
      }
      final dbName = safe(sqliteName, '.sqlite');
      final tileName = safe(mbtilesName, '.mbtiles');
      final wanted = {'metadata.json', 'manifest.json', dbName, tileName};
      final found = <String, int>{};
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final normalized = entry.name.replaceAll('\\', '/');
        if (!wanted.contains(normalized) || normalized.split('/').length > 1) continue;
        final output = OutputFileStream(p.join(outputDir, normalized));
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        found[normalized] = entry.size;
      }
      for (final name in {dbName, 'metadata.json', tileName}) {
        final file = File(p.join(outputDir, name));
        if (!file.existsSync() || file.lengthSync() <= 0) {
          throw VectorMapInstallException('ABM extraction incomplete: missing $name');
        }
        final expected = found[name];
        if (expected != null && file.lengthSync() != expected) {
          throw VectorMapInstallException('ABM extraction incomplete: $name expected=$expected actual=${file.lengthSync()}');
        }
      }
      // New ABM packages carry an internal manifest. Legacy v6 packages may
      // omit it, but if present its identity must agree with the metadata.
      final mf = File(p.join(outputDir, 'manifest.json'));
      if (mf.existsSync()) {
        final m = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
        if ((m['database'] as String?) != dbName || (m['tiles'] as String?) != tileName) {
          throw const VectorMapInstallException('ABM manifest and metadata disagree on runtime files.');
        }
      }
      return [dbName, tileName];
    } finally {
      input.closeSync();
    }
  }

  static void _validateMbtilesFast(File file) {
    final db = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    try {
      final tables = db.select("SELECT name FROM sqlite_master WHERE type IN ('table','view')")
          .map((r) => '${r['name']}').toSet();
      if (!tables.contains('metadata') || !tables.contains('map') || !tables.contains('images')) {
        throw const VectorMapInstallException('ABM province-specific MBTiles schema is incomplete.');
      }
      // Do not COUNT the entire tile table during startup. Opening the
      // database and checking the required schema/format is enough here;
      // MapLibre will query the actual tiles on demand.
      final format = db.select("SELECT value FROM metadata WHERE name='format' LIMIT 1");
      if (format.isEmpty || '${format.first['value']}'.toLowerCase() != 'pbf') {
        throw const VectorMapInstallException('ABM province-specific MBTiles is not a PBF vector tile archive.');
      }
    } finally {
      db.dispose();
    }
  }

  static void _validateSqliteFast(File file) {
    final db = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    configureReadOnly(db);
    try {
      db.execute('PRAGMA query_only=ON');
      // Full PRAGMA integrity_check is intentionally not run on the first
      // frame of map startup: it can scan a very large country database.
      // Runtime queries still fail safely if the database is actually corrupt.
      // ABM v4 routing/search schema is intentionally compact: text/category
      // values are denormalized into features, while nodes/edges are the
      // disk-backed graph and indexed spatial lookup provide the query path.
      final required = {
        'features', 'search_fts', 'spatial', 'nodes', 'edges', 'turn_restrictions',
      };
      final have = db.select("SELECT name FROM sqlite_master WHERE type IN ('table','view')")
          .map((r) => '${r['name']}').toSet();
      final missing = required.difference(have);
      if (missing.isNotEmpty) {
        throw VectorMapInstallException('ABM database is missing: ${missing.join(', ')}');
      }
      // Graph cardinality checks are deferred until routing is requested.
      // province-specific SQLite is only required to expose the expected schema here.
    } finally {
      db.dispose();
    }
  }

  // MapLibre's `coalesce` treats '' as a value, so an empty `name` would hide
  // an existing name_fa/name_en label.
  static String _firstNonEmpty(List<dynamic> values) {
    for (final v in values) {
      final t = '${v ?? ''}'.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  /// نام خیابان‌ها برای نقشهٔ آفلاین: هر way با نام، از segmentهای `road_index`
  /// به خطِ پیوسته (LineString) تبدیل می‌شود تا برچسب با `symbol-placement: line`
  /// روی خودِ خیابان بنشیند. `major` برای راه‌های کلاس ۱ تا ۵ (آزادراه..فرعی۲) true است.
  static List<AbmVectorFeature> roadLabelLines(sqlite.Database db, AbmBBox bbox) {
    final result = <AbmVectorFeature>[];
      // Road names are deliberately stored in province-specific SQLite, not in the MVT
      // road tile attributes. Build a lightweight local GeoJSON road-label
      // layer from the spatial road index so every country uses its own OSM
      // local name (name), with language-specific fallbacks when available.
      final roadRows = db.select(
        'SELECT DISTINCT s.id,s.way_id,s.a,s.b,w.class_id,c.name class_name,w.name_id,w.speed_kmh,w.oneway,w.junction,w.surface,'
        'n.name,n.name_fa,n.name_en,na.lat_e7 alat,na.lon_e7 alon,nb.lat_e7 blat,nb.lon_e7 blon '
        'FROM road_index r JOIN segments s ON s.id BETWEEN r.seg_from AND r.seg_to '
        'JOIN way_data w ON w.way_id=s.way_id LEFT JOIN categories c ON c.id=w.class_id LEFT JOIN names n ON n.id=w.name_id '
        'JOIN node_data na ON na.id=s.a JOIN node_data nb ON nb.id=s.b '
        'WHERE r.max_lon>=? AND r.min_lon<=? AND r.max_lat>=? AND r.min_lat<=? '
        // Was LIMIT 2500, ORDER BY s.way_id,s.id. In a dense residential
        // grid (many short named ways -- exactly the لاله/یاس/نیلوفر streets
        // in the sample viewport) that cap silently cut off whichever ways
        // happened to sort after it, so entire streets had zero segments
        // and never got a label. 20000 rows is still a single indexed
        // range scan (road_index -> segments), done once per viewport
        // refresh in an isolate, not per frame.
        'ORDER BY s.way_id,s.id LIMIT 20000',
        [bbox.minLon, bbox.maxLon, bbox.minLat, bbox.maxLat],
      );
      // Stitch each way's segments back into polylines by node-id adjacency
      // instead of by row order. The previous version only chained a row
      // onto the *end* of the line built so far (`line.last == a/b`); since
      // `ORDER BY s.id` has no guaranteed relationship to a segment's
      // position along the way, any segment that happened to arrive
      // out of geometric order broke the chain into its own disconnected
      // 2-point piece. A short, isolated 2-point line frequently has no
      // room for MapLibre to place a `symbol-placement: line` label at all
      // -- which is what "most street names don't render offline" was:
      // most ways were silently fragmented this way, not actually unnamed.
      final wayNodeA = <int, List<int>>{};
      final wayNodeB = <int, List<int>>{};
      final wayCoordA = <int, List<List<double>>>{};
      final wayCoordB = <int, List<List<double>>>{};
      final wayProps = <int, Map<String, dynamic>>{};
      for (final r in roadRows) {
        final wayId = (r['way_id'] as num).toInt();
        wayNodeA.putIfAbsent(wayId, () => <int>[]).add((r['a'] as num).toInt());
        wayNodeB.putIfAbsent(wayId, () => <int>[]).add((r['b'] as num).toInt());
        wayCoordA.putIfAbsent(wayId, () => <List<double>>[]).add(
          <double>[(r['alon'] as num).toDouble() * 1e-7, (r['alat'] as num).toDouble() * 1e-7],
        );
        wayCoordB.putIfAbsent(wayId, () => <List<double>>[]).add(
          <double>[(r['blon'] as num).toDouble() * 1e-7, (r['blat'] as num).toDouble() * 1e-7],
        );
        wayProps.putIfAbsent(wayId, () => <String, dynamic>{
          'name': _firstNonEmpty([r['name'], r['name_fa'], r['name_en']]),
          'name_fa': '${r['name_fa'] ?? ''}',
          'name_en': '${r['name_en'] ?? ''}',
          'class': '${r['class_name'] ?? r['class_id'] ?? ''}',
          'klass': (r['class_id'] as num?)?.toInt() ?? 0,
          'major': (() {
            final k = (r['class_id'] as num?)?.toInt() ?? 0;
            return k >= 1 && k <= 5;
          })(),
          'oneway': (r['oneway'] as num?)?.toInt() == 1 ||
              const ['roundabout', 'circular'].contains('${r['junction'] ?? ''}'.trim().toLowerCase()),
          'speed_kmh': (r['speed_kmh'] as num?)?.toInt(),
          'surface': '${r['surface'] ?? ''}',
        });
      }
      var roadId = -1;
      for (final wayId in wayProps.keys) {
        final name = '${wayProps[wayId]?['name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        final nodesA = wayNodeA[wayId]!;
        final nodesB = wayNodeB[wayId]!;
        final coordsA = wayCoordA[wayId]!;
        final coordsB = wayCoordB[wayId]!;
        final segCount = nodesA.length;
        final byNode = <int, List<int>>{};
        for (var i = 0; i < segCount; i++) {
          byNode.putIfAbsent(nodesA[i], () => <int>[]).add(i);
          byNode.putIfAbsent(nodesB[i], () => <int>[]).add(i);
        }
        final used = List<bool>.filled(segCount, false);
        for (var i = 0; i < segCount; i++) {
          if (used[i]) continue;
          used[i] = true;
          final chain = <List<double>>[coordsA[i], coordsB[i]];
          var frontNode = nodesA[i];
          var backNode = nodesB[i];
          var extended = true;
          while (extended) {
            extended = false;
            for (final j in byNode[backNode] ?? const <int>[]) {
              if (used[j]) continue;
              if (nodesA[j] == backNode) {
                chain.add(coordsB[j]);
                backNode = nodesB[j];
                used[j] = true;
                extended = true;
                break;
              } else if (nodesB[j] == backNode) {
                chain.add(coordsA[j]);
                backNode = nodesA[j];
                used[j] = true;
                extended = true;
                break;
              }
            }
          }
          extended = true;
          while (extended) {
            extended = false;
            for (final j in byNode[frontNode] ?? const <int>[]) {
              if (used[j]) continue;
              if (nodesA[j] == frontNode) {
                chain.insert(0, coordsB[j]);
                frontNode = nodesB[j];
                used[j] = true;
                extended = true;
                break;
              } else if (nodesB[j] == frontNode) {
                chain.insert(0, coordsA[j]);
                frontNode = nodesA[j];
                used[j] = true;
                extended = true;
                break;
              }
            }
          }
          if (chain.length < 2) continue;
          final minLon = chain.map((p) => p[0]).reduce((a, b) => a < b ? a : b);
          final maxLon = chain.map((p) => p[0]).reduce((a, b) => a > b ? a : b);
          final minLat = chain.map((p) => p[1]).reduce((a, b) => a < b ? a : b);
          final maxLat = chain.map((p) => p[1]).reduce((a, b) => a > b ? a : b);
          result.add(AbmVectorFeature(
            id: roadId--,
            layer: 'roads',
            geometry: chain,
            bbox: AbmBBox(minLon, minLat, maxLon, maxLat),
            properties: wayProps[wayId]!,
            minZoom: 11,
          ));
        }
      }
    return result;
  }
}
