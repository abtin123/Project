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

class RoadSnapper {
  RoadSnapper._();
  static final RoadSnapper instance = RoadSnapper._();

  bool enabled = true;

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

    RoadSnapResult? best;
    var bestScore = double.infinity;

    for (final road in _roads) {
      if (lat < road.minLat - padLat ||
          lat > road.maxLat + padLat ||
          lng < road.minLng - padLng ||
          lng > road.maxLng + padLng) {
        continue;
      }
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

        if (road.key == _lockKey) score -= 7.0;

        if (score < bestScore) {
          bestScore = score;
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
