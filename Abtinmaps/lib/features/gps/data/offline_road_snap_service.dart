import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'gps_math.dart';
import 'location_service.dart';
import 'road_snapper.dart';

/// Loads the road graph around the vehicle from the offline ABM map file and
/// feeds it to [RoadSnapper]. Matching itself happens in the position pipeline
/// (NavigationPositionController), so [snap] returns null once roads are live.
class OfflineRoadSnapService {
  String? _path;
  double _cLat = 0, _cLng = 0;
  bool _loaded = false;
  bool _loading = false;

  static const double _radiusM = 1100;
  static const double _reloadM = 450;

  Future<VehiclePosition?> snap(VehiclePosition position, File? mapFile) async {
    if (mapFile == null) return null;
    final path = mapFile.path;
    final needLoad = !_loaded ||
        _path != path ||
        distanceM(_cLat, _cLng, position.lat, position.lng) > _reloadM;
    if (needLoad && !_loading) {
      _loading = true;
      try {
        final mLat = mPerDegLat(position.lat);
        final mLng = mPerDegLng(position.lat);
        final dLat = _radiusM / mLat;
        final dLng = _radiusM / mLng;
        final q = (
          path: path,
          minLat: position.lat - dLat,
          maxLat: position.lat + dLat,
          minLon: position.lng - dLng,
          maxLon: position.lng + dLng,
        );
        List<SnapRoad> roads;
        try {
          roads = await Isolate.run(() => _loadRoads(q));
        } catch (_) {
          roads = _loadRoads(q);
        }
        RoadSnapper.instance.updateRoads(roads);
        RoadSnapper.instance.enabled = roads.isNotEmpty;
        _path = path;
        _cLat = position.lat;
        _cLng = position.lng;
        _loaded = true;
      } catch (_) {
        // keep whatever was loaded before
      } finally {
        _loading = false;
      }
    }
    return null;
  }

  Future<void> dispose() async {}
}

int _parseOneway(Object? v, Object? junction) {
  int mode = 0;
  if (v is num) {
    final n = v.toInt();
    mode = n == 1 ? 1 : (n == -1 ? -1 : 0);
  } else {
    final x = '${v ?? ''}'.trim().toLowerCase();
    final n = num.tryParse(x);
    if (n != null) {
      mode = n == 1 ? 1 : (n == -1 ? -1 : 0);
    } else if (x == 'reverse' || x == 'backward') {
      mode = -1;
    } else if (x == 'true' || x == 'yes' || x == 'y' || x == 'forward') {
      mode = 1;
    }
  }
  if (mode == 0) {
    final j = '${junction ?? ''}'.trim().toLowerCase();
    if (j == 'roundabout' || j == 'circular') return 1;
  }
  return mode;
}

List<SnapRoad> _loadRoads(
  ({String path, double minLat, double maxLat, double minLon, double maxLon}) q,
) {
  final db = sqlite.sqlite3.open(q.path, mode: sqlite.OpenMode.readOnly);
  try {
    final rows = db.select(
      'SELECT DISTINCT s.id AS sid, s.way_id AS way_id, w.oneway AS oneway, '
      "COALESCE(w.junction,'') AS junction, c.name AS road_class, "
      'na.lat_e7 AS alat, na.lon_e7 AS alon, nb.lat_e7 AS blat, nb.lon_e7 AS blon '
      'FROM road_index r JOIN segments s ON s.id BETWEEN r.seg_from AND r.seg_to '
      'JOIN way_data w ON w.way_id=s.way_id JOIN categories c ON c.id=w.class_id '
      'JOIN node_data na ON na.id=s.a JOIN node_data nb ON nb.id=s.b '
      'WHERE r.max_lat>=? AND r.min_lat<=? AND r.max_lon>=? AND r.min_lon<=? '
      'LIMIT 60000',
      [q.maxLat, q.minLat, q.maxLon, q.minLon],
    );
    final out = <SnapRoad>[];
    for (final r in rows) {
      final alat = (r['alat'] as num).toDouble() * 1e-7;
      final alon = (r['alon'] as num).toDouble() * 1e-7;
      final blat = (r['blat'] as num).toDouble() * 1e-7;
      final blon = (r['blon'] as num).toDouble() * 1e-7;
      if (math.max(alat, blat) < q.minLat ||
          math.min(alat, blat) > q.maxLat ||
          math.max(alon, blon) < q.minLon ||
          math.min(alon, blon) > q.maxLon) {
        continue;
      }
      out.add(SnapRoad(
        key: (r['way_id'] as num).toInt(),
        roadClass: '${r['road_class'] ?? ''}',
        oneway: _parseOneway(r['oneway'], r['junction']),
        lats: [alat, blat],
        lngs: [alon, blon],
      ));
    }
    return out;
  } finally {
    db.dispose();
  }
}
