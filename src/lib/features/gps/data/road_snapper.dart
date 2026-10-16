import 'dart:math' as math;

class SnapRoad {
  SnapRoad({
    required this.key,
    required this.roadClass,
    required this.oneway,
    required this.lats,
    required this.lngs,
  }) {
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (var i = 0; i < lats.length; i++) {
      if (lats[i] < minLat) minLat = lats[i];
      if (lats[i] > maxLat) maxLat = lats[i];
      if (lngs[i] < minLng) minLng = lngs[i];
      if (lngs[i] > maxLng) maxLng = lngs[i];
    }
    this.minLat = minLat;
    this.maxLat = maxLat;
    this.minLng = minLng;
    this.maxLng = maxLng;
  }

  final int key;
  final String roadClass;

  final int oneway;
  final List<double> lats;
  final List<double> lngs;
  late final double minLat, maxLat, minLng, maxLng;
}

class _SnapCand {
  _SnapCand({
    required this.result,
    required this.score,
    required this.oneway,
    required this.px,
    required this.py,
  });
  final RoadSnapResult result;
  double score;
  final int oneway;
  // Projection point of the GPS fix on the road, in metres east/north of the fix.
  final double px, py;
}

class RoadSnapResult {
  const RoadSnapResult({
    required this.lat,
    required this.lng,
    required this.bearingDeg,
    required this.distanceM,
    required this.roadKey,
    required this.roadClass,
  });

  final double lat;
  final double lng;

  final double bearingDeg;

  final double distanceM;
  final int roadKey;
  final String roadClass;
}

/// Result of moving along the locked road: [leftoverM] is the distance that could
/// not be travelled because the road geometry ended with no continuation.
class RoadAdvance {
  const RoadAdvance(this.result, this.leftoverM);
  final RoadSnapResult result;
  final double leftoverM;
}

class RoadSnapper {
  RoadSnapper._();
  static final RoadSnapper instance = RoadSnapper._();

  bool enabled = true;

  /// Set to true for left-hand-traffic countries (GB, IN, JP, TH, ID, PK...).
  bool leftHandTraffic = false;

  List<SnapRoad> _roads = const [];
  final Map<int, List<SnapRoad>> _byKey = {};

  int? _lockKey;
  double? _lockBearing;
  int _missCount = 0;

  bool get hasRoads => _roads.isNotEmpty;

  void updateRoads(List<SnapRoad> roads) {
    _roads = roads;
    _byKey.clear();
    for (final r in roads) {
      (_byKey[r.key] ??= <SnapRoad>[]).add(r);
    }
  }

  void reset() {
    _roads = const [];
    _byKey.clear();
    _lockKey = null;
    _lockBearing = null;
    _missCount = 0;
  }

  static double _angDiff(double a, double b) {
    final d = ((a - b + 540) % 360) - 180;
    return d.abs();
  }

  static double _classPenalty(String c) {
    switch (c) {
      case 'motorway':
      case 'trunk':
      case 'primary':
      case 'secondary':
      case 'tertiary':
      case 'motorway_link':
      case 'trunk_link':
      case 'primary_link':
      case 'secondary_link':
      case 'tertiary_link':
        return 0.0;
      case 'service':
      case 'track':
        return 4.0;
      default:
        return 1.0;
    }
  }

  RoadSnapResult? snap(
    double lat,
    double lng, {
    required double headingDeg,
    required double speedKmh,
    required double accuracyM,
    required double referenceHeadingDeg,
  }) {
    if (!enabled || _roads.isEmpty || !lat.isFinite || !lng.isFinite) {
      return null;
    }
    final moving = speedKmh >= 6.0;
    final headingOk = moving && headingDeg.isFinite;
    final acc = accuracyM.isFinite ? accuracyM : 20.0;
    final locked = _lockKey != null;
    var maxD = (acc * 1.5 + 15.0).clamp(25.0, 50.0).toDouble();
    if (!moving && !locked) maxD = math.min(maxD, 25.0);
    if (locked) maxD = math.max(maxD, 30.0);

    final mLat = 110540.0;
    final mLng = 111320.0 * math.cos(lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final padLat = maxD / mLat;
    final padLng = maxD / mLng;

    // Best candidate per road piece (not just one global best) so that parallel
    // carriageways can be compared with each other afterwards.
    final cands = <_SnapCand>[];

    for (final road in _roads) {
      if (lat < road.minLat - padLat ||
          lat > road.maxLat + padLat ||
          lng < road.minLng - padLng ||
          lng > road.maxLng + padLng) {
        continue;
      }
      _SnapCand? roadBest;
      final n = road.lats.length;
      for (var i = 0; i + 1 < n; i++) {
        final ax = (road.lngs[i] - lng) * mLng;
        final ay = (road.lats[i] - lat) * mLat;
        final bx = (road.lngs[i + 1] - lng) * mLng;
        final by = (road.lats[i + 1] - lat) * mLat;
        final dx = bx - ax;
        final dy = by - ay;
        final len2 = dx * dx + dy * dy;
        if (len2 < 1e-6) continue;
        var t = -(ax * dx + ay * dy) / len2;
        t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final px = ax + dx * t;
        final py = ay + dy * t;
        final d = math.sqrt(px * px + py * py);
        if (d > maxD) continue;

        final fwd = (math.atan2(dx, dy) * 180.0 / math.pi + 360.0) % 360.0;
        final rev = (fwd + 180.0) % 360.0;
        double bearing;
        var score = d + _classPenalty(road.roadClass);

        if (headingOk) {
          double diffFwd = _angDiff(headingDeg, fwd);
          double diffRev = _angDiff(headingDeg, rev);
          if (road.oneway == 1) {
            diffRev = 999;
          } else if (road.oneway == -1) {
            diffFwd = 999;
          }
          var useFwd = diffFwd <= diffRev;
          if (_lockKey == road.key && _lockBearing != null && road.oneway == 0) {
            final lockFwd = _angDiff(_lockBearing!, fwd) <= _angDiff(_lockBearing!, rev);
            if (lockFwd != useFwd) {
              final clear = speedKmh >= 15.0 && math.min(diffFwd, diffRev) < 50.0;
              if (!clear) useFwd = lockFwd;
            }
          }
          bearing = useFwd ? fwd : rev;
          final diff = math.min(diffFwd, diffRev);
          score += diff.clamp(0.0, 180.0) * 0.22;
        } else {
          final ref = (_lockKey == road.key && _lockBearing != null)
              ? _lockBearing!
              : referenceHeadingDeg;
          if (road.oneway == 1) {
            bearing = fwd;
          } else if (road.oneway == -1) {
            bearing = rev;
          } else {
            bearing = _angDiff(ref, fwd) <= _angDiff(ref, rev) ? fwd : rev;
          }
        }

        // Weak "stay on the road we were on" bias. It used to be 7 m, which
        // was enough to keep the car glued to the wrong carriageway of a
        // divided road when the GPS was closer to the right one.
        if (road.key == _lockKey) score -= 3.0;

        if (roadBest == null || score < roadBest.score) {
          roadBest = _SnapCand(
            result: RoadSnapResult(
              lat: lat + (py / mLat),
              lng: lng + (px / mLng),
              bearingDeg: bearing,
              distanceM: d,
              roadKey: road.key,
              roadClass: road.roadClass,
            ),
            score: score,
            oneway: road.oneway,
            px: px,
            py: py,
          );
        }
      }
      if (roadBest != null) cands.add(roadBest);
    }

    // Divided roads: the two carriageways are often both tagged as plain
    // two-way roads, so direction data cannot tell them apart and the nearest
    // one (often the opposite lane) wins. With right-hand traffic the correct
    // carriageway is the one on the right of the direction of travel, so a
    // two-way candidate with a parallel, same-class, two-way partner a few
    // metres to its right is penalised. Roads that DO carry oneway data are
    // never touched: the data decides there.
    if (!leftHandTraffic && cands.length >= 2 && (headingOk || locked)) {
      for (final a in cands) {
        if (a.oneway != 0) continue;
        for (final b in cands) {
          if (identical(a, b) || b.oneway != 0) continue;
          if (a.result.roadClass != b.result.roadClass) continue;
          final bd = _angDiff(a.result.bearingDeg, b.result.bearingDeg);
          if (bd > 30.0 && bd < 150.0) continue; // not parallel
          final sepX = b.px - a.px, sepY = b.py - a.py;
          final sep = math.sqrt(sepX * sepX + sepY * sepY);
          if (sep < 4.0 || sep > 25.0) continue;
          final h = a.result.bearingDeg * math.pi / 180.0;
          // Signed offset of b relative to a along the travel direction's right.
          final rightOfA = sepX * math.cos(h) - sepY * math.sin(h);
          if (rightOfA > 3.0) a.score += 8.0;
        }
      }
    }

    RoadSnapResult? best;
    var bestScore = double.infinity;
    for (final c in cands) {
      if (c.score < bestScore) {
        bestScore = c.score;
        best = c.result;
      }
    }

    if (best == null) {
      if (++_missCount >= 3) {
        _lockKey = null;
        _lockBearing = null;
      }
      return null;
    }
    _missCount = 0;
    _lockKey = best.roadKey;
    _lockBearing = best.bearingDeg;
    return best;
  }

  static double _segBearing(SnapRoad r, int seg, bool forward, double mLat, double mLng) {
    final dx = (r.lngs[seg + 1] - r.lngs[seg]) * mLng;
    final dy = (r.lats[seg + 1] - r.lats[seg]) * mLat;
    final b = (math.atan2(dx, dy) * 180.0 / math.pi + 360.0) % 360.0;
    return forward ? b : (b + 180.0) % 360.0;
  }

  /// Map-matched dead reckoning: advances [distanceM] along the locked road,
  /// following its curvature (and hopping to a connected road piece at its end)
  /// instead of stepping along a straight heading, which cuts every bend and
  /// leaves the road in sharp turns.
  RoadAdvance? advance(
    double lat,
    double lng,
    double distanceM, {
    required double referenceHeadingDeg,
  }) {
    final key = _lockKey;
    if (!enabled || key == null || !(distanceM > 0)) return null;
    final roads = _byKey[key];
    if (roads == null) return null;

    final mLat = 110540.0;
    final mLng = 111320.0 * math.cos(lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    double vx(SnapRoad r, int i) => (r.lngs[i] - lng) * mLng;
    double vy(SnapRoad r, int i) => (r.lats[i] - lat) * mLat;

    SnapRoad? road;
    var seg = -1;
    var tt = 0.0;
    var bestD = 35.0;
    for (final r in roads) {
      for (var i = 0; i + 1 < r.lats.length; i++) {
        final ax = vx(r, i), ay = vy(r, i);
        final dx = vx(r, i + 1) - ax, dy = vy(r, i + 1) - ay;
        final len2 = dx * dx + dy * dy;
        if (len2 < 1e-6) continue;
        var t = -(ax * dx + ay * dy) / len2;
        t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final px = ax + dx * t, py = ay + dy * t;
        final d = math.sqrt(px * px + py * py);
        if (d < bestD) {
          bestD = d;
          road = r;
          seg = i;
          tt = t;
        }
      }
    }
    if (road == null) return null;

    var curRoad = road;
    var curSeg = seg;
    final fwd0 = _segBearing(curRoad, curSeg, true, mLat, mLng);
    bool curForward;
    if (curRoad.oneway == 1) {
      curForward = true;
    } else if (curRoad.oneway == -1) {
      curForward = false;
    } else {
      curForward = _angDiff(referenceHeadingDeg, fwd0) <=
          _angDiff(referenceHeadingDeg, (fwd0 + 180.0) % 360.0);
    }
    var cx = vx(curRoad, curSeg) + (vx(curRoad, curSeg + 1) - vx(curRoad, curSeg)) * tt;
    var cy = vy(curRoad, curSeg) + (vy(curRoad, curSeg + 1) - vy(curRoad, curSeg)) * tt;
    var remaining = distanceM;
    var steps = 0;
    while (remaining > 1e-6 && steps++ < 60) {
      final endIdx = curForward ? curSeg + 1 : curSeg;
      final ex = vx(curRoad, endIdx), ey = vy(curRoad, endIdx);
      final segLen = math.sqrt((ex - cx) * (ex - cx) + (ey - cy) * (ey - cy));
      if (remaining <= segLen) {
        final f = segLen <= 1e-9 ? 0.0 : remaining / segLen;
        cx += (ex - cx) * f;
        cy += (ey - cy) * f;
        remaining = 0;
        break;
      }
      cx = ex;
      cy = ey;
      remaining -= segLen;
      final nextSeg = curForward ? curSeg + 1 : curSeg - 1;
      if (nextSeg >= 0 && nextSeg + 1 < curRoad.lats.length) {
        curSeg = nextSeg;
        continue;
      }
      // End of this road piece: continue on a connected piece going the same way.
      final travel = _segBearing(curRoad, curSeg, curForward, mLat, mLng);
      SnapRoad? nextRoad;
      var nextSegIdx = 0;
      var nextForward = true;
      var nextScore = double.infinity;
      for (final r in _roads) {
        if (identical(r, curRoad) || r.lats.length < 2) continue;
        final last = r.lats.length - 1;
        // Start of r reached -> travel forward along r.
        if (r.oneway != -1) {
          final d = math.sqrt(math.pow(vx(r, 0) - cx, 2) + math.pow(vy(r, 0) - cy, 2));
          if (d <= 3.0) {
            final diff = _angDiff(travel, _segBearing(r, 0, true, mLat, mLng));
            final score = d + diff * 0.1 - (r.key == curRoad.key ? 1.0 : 0.0);
            if (diff <= 55.0 && score < nextScore) {
              nextScore = score;
              nextRoad = r;
              nextSegIdx = 0;
              nextForward = true;
            }
          }
        }
        // End of r reached -> travel backwards along r.
        if (r.oneway != 1) {
          final d = math.sqrt(math.pow(vx(r, last) - cx, 2) + math.pow(vy(r, last) - cy, 2));
          if (d <= 3.0) {
            final diff = _angDiff(travel, _segBearing(r, last - 1, false, mLat, mLng));
            final score = d + diff * 0.1 - (r.key == curRoad.key ? 1.0 : 0.0);
            if (diff <= 55.0 && score < nextScore) {
              nextScore = score;
              nextRoad = r;
              nextSegIdx = last - 1;
              nextForward = false;
            }
          }
        }
      }
      if (nextRoad == null) break;
      curRoad = nextRoad;
      curSeg = nextSegIdx;
      curForward = nextForward;
    }

    final bearing = _segBearing(curRoad, curSeg, curForward, mLat, mLng);
    _lockKey = curRoad.key;
    _lockBearing = bearing;
    return RoadAdvance(
      RoadSnapResult(
        lat: lat + cy / mLat,
        lng: lng + cx / mLng,
        bearingDeg: bearing,
        distanceM: 0,
        roadKey: curRoad.key,
        roadClass: curRoad.roadClass,
      ),
      remaining,
    );
  }

  RoadSnapResult? follow(
    double lat,
    double lng, {
    required double referenceHeadingDeg,
  }) {
    final key = _lockKey;
    if (!enabled || key == null) return null;
    final roads = _byKey[key];
    if (roads == null) return null;

    final mLat = 110540.0;
    final mLng = 111320.0 * math.cos(lat * math.pi / 180.0).abs().clamp(0.2, 1.0);

    RoadSnapResult? best;
    var bestD = 35.0;
    for (final road in roads) {
      final n = road.lats.length;
      for (var i = 0; i + 1 < n; i++) {
        final ax = (road.lngs[i] - lng) * mLng;
        final ay = (road.lats[i] - lat) * mLat;
        final bx = (road.lngs[i + 1] - lng) * mLng;
        final by = (road.lats[i + 1] - lat) * mLat;
        final dx = bx - ax;
        final dy = by - ay;
        final len2 = dx * dx + dy * dy;
        if (len2 < 1e-6) continue;
        var t = -(ax * dx + ay * dy) / len2;
        t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final px = ax + dx * t;
        final py = ay + dy * t;
        final d = math.sqrt(px * px + py * py);
        if (d >= bestD) continue;
        bestD = d;
        final fwd = (math.atan2(dx, dy) * 180.0 / math.pi + 360.0) % 360.0;
        final rev = (fwd + 180.0) % 360.0;
        double bearing;
        if (road.oneway == 1) {
          bearing = fwd;
        } else if (road.oneway == -1) {
          bearing = rev;
        } else {
          bearing = _angDiff(referenceHeadingDeg, fwd) <=
                  _angDiff(referenceHeadingDeg, rev)
              ? fwd
              : rev;
        }
        best = RoadSnapResult(
          lat: lat + (py / mLat),
          lng: lng + (px / mLng),
          bearingDeg: bearing,
          distanceM: d,
          roadKey: road.key,
          roadClass: road.roadClass,
        );
      }
    }
    if (best != null) _lockBearing = best.bearingDeg;
    return best;
  }
}
