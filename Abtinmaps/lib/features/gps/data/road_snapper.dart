import 'dart:math' as math;

import 'gps_math.dart';
import 'vehicle_position.dart';

/// One road polyline. [oneway]: 0 = both directions, 1 = only along the order
/// of [lats]/[lngs], -1 = only against it.
class SnapRoad {
  SnapRoad({
    required this.key,
    required this.roadClass,
    required this.oneway,
    required this.lats,
    required this.lngs,
    this.widthM,
  });

  final int key;
  final String roadClass;
  final int oneway;
  final List<double> lats;
  final List<double> lngs;
  final double? widthM;
}

class SnapResult {
  const SnapResult({
    required this.lat,
    required this.lng,
    required this.headingDeg,
    required this.roadKey,
    required this.distanceM,
    required this.confidence,
  });

  final double lat;
  final double lng;
  final double headingDeg;
  final int roadKey;

  /// Distance between the filtered fix and the road centreline.
  final double distanceM;

  /// 0..1 – how strongly the position was pulled onto the road.
  final double confidence;
}

class _Profile {
  const _Profile(this.prior, this.maxKmh, this.width,
      {this.vehicle = true, this.service = false});
  final double prior;
  final double maxKmh;
  final double width;
  final bool vehicle;

  /// Campus / parking / hospital internal road (`service`, `track`).
  final bool service;
}

class _Seg {
  _Seg(this.road, this.idx, this.ax, this.ay, this.bx, this.by, this.len,
      this.bearing, this.oneway, this.profile, this.width);
  final int road;
  final int idx;
  final double ax, ay, bx, by, len, bearing;
  final int oneway;
  final _Profile profile;
  final double width;
}

class _Cand {
  _Cand(this.seg, this.dist, this.t, this.px, this.py, this.dirFwd, this.dAng,
      this.score);
  final _Seg seg;
  final double dist;
  final double t;
  final double px, py;
  final bool dirFwd;
  final double dAng;
  double score;
}

/// Online map-matcher for free driving (no active route).
///
/// Scores every nearby segment by distance, travel-direction agreement
/// (respecting one-way streets), speed plausibility for the road class, road
/// class prior and continuity with the previous match, then applies hysteresis
/// so the car does not hop between parallel roads. The result is blended onto
/// the road with a confidence weight, shifted to the correct side of two-way
/// roads, and the heading follows the road geometry.
class RoadSnapper {
  RoadSnapper._();
  static final RoadSnapper instance = RoadSnapper._();

  bool enabled = false;
  bool leftHandTraffic = false;

  bool get hasRoads => _segs.isNotEmpty;
  bool get hasLock => _lockCount >= 2;

  // ---- road store -------------------------------------------------------
  double _refLat = 0, _refLng = 0, _mLat = 111000, _mLng = 111000;
  final List<_Seg> _segs = [];
  final Map<int, List<int>> _grid = {};
  static const double _cell = 60.0;

  // ---- match state ------------------------------------------------------
  int? _curRoad;
  int _curSeg = -1;
  int _switchVotes = 0;
  int? _challengerRoad;
  int _lockCount = 0;

  /// 0..6 – how long the car has been matched to internal (service) roads.
  /// While high, we are inside a campus/lot and must not jump to the outer
  /// main road running alongside it.
  int _svcCtx = 0;
  bool _curIsService = false;
  double? _lastHeading;
  double _lastRawX = 0, _lastRawY = 0;
  bool _hasLastRaw = false;
  SnapResult? _lastResult;

  static _Profile _profileFor(String cls) {
    var c = cls.toLowerCase();
    final isLink = c.endsWith('_link');
    if (isLink) c = c.substring(0, c.length - 5);
    switch (c) {
      case 'motorway':
        return const _Profile(0.4, 160, 14);
      case 'trunk':
        return const _Profile(0.3, 130, 11);
      case 'primary':
        return const _Profile(0.2, 110, 9);
      case 'secondary':
        return const _Profile(0.1, 100, 7.5);
      case 'tertiary':
        return const _Profile(0.0, 90, 6.5);
      case 'residential':
      case 'unclassified':
      case 'living_street':
        return const _Profile(0.0, 70, 5.5);
      case 'service':
        return const _Profile(-0.8, 40, 3.5, service: true);
      case 'track':
        return const _Profile(-1.6, 40, 2.5, service: true);
      case 'footway':
      case 'path':
      case 'pedestrian':
      case 'cycleway':
      case 'steps':
        return const _Profile(-4.0, 8, 2, vehicle: false);
      default:
        return const _Profile(-0.3, 90, 6);
    }
  }

  /// Replaces the road window. Matching state is kept if the road keys persist.
  void updateRoads(List<SnapRoad> roads) {
    _segs.clear();
    _grid.clear();
    if (roads.isEmpty) return;
    var first = true;
    for (final r in roads) {
      if (r.lats.isEmpty) continue;
      if (first) {
        _refLat = r.lats.first;
        _refLng = r.lngs.first;
        _mLat = mPerDegLat(_refLat);
        _mLng = mPerDegLng(_refLat);
        first = false;
      }
      break;
    }
    if (first) return;
    for (final r in roads) {
      final n = math.min(r.lats.length, r.lngs.length);
      if (n < 2) continue;
      final prof = _profileFor(r.roadClass);
      final width = r.widthM ?? prof.width;
      for (var i = 0; i < n - 1; i++) {
        final ax = (r.lngs[i] - _refLng) * _mLng;
        final ay = (r.lats[i] - _refLat) * _mLat;
        final bx = (r.lngs[i + 1] - _refLng) * _mLng;
        final by = (r.lats[i + 1] - _refLat) * _mLat;
        final dx = bx - ax, dy = by - ay;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len < 0.05) continue;
        final seg = _Seg(r.key, i, ax, ay, bx, by, len,
            normDeg(math.atan2(dx, dy) * kRadToDeg), r.oneway, prof, width);
        final id = _segs.length;
        _segs.add(seg);
        final x0 = (math.min(ax, bx) / _cell).floor();
        final x1 = (math.max(ax, bx) / _cell).floor();
        final y0 = (math.min(ay, by) / _cell).floor();
        final y1 = (math.max(ay, by) / _cell).floor();
        for (var cx = x0; cx <= x1; cx++) {
          for (var cy = y0; cy <= y1; cy++) {
            (_grid[_cellKey(cx, cy)] ??= <int>[]).add(id);
          }
        }
      }
    }
  }

  static int _cellKey(int cx, int cy) => (cx + 0x100000) * 0x200000 + (cy + 0x100000);

  void reset() {
    _curRoad = null;
    _curSeg = -1;
    _switchVotes = 0;
    _challengerRoad = null;
    _lockCount = 0;
    _svcCtx = 0;
    _curIsService = false;
    _lastHeading = null;
    _hasLastRaw = false;
    _lastResult = null;
  }

  /// Match [p] (already Kalman-filtered). [dtSec] is the time since the last call.
  SnapResult? snap(VehiclePosition p, {double dtSec = 1.0}) {
    if (!enabled || _segs.isEmpty) return null;
    final x = (p.lng - _refLng) * _mLng;
    final y = (p.lat - _refLat) * _mLat;
    final speed = p.speedKmh / 3.6;
    final sigma = math.max(p.accuracyM, 4.0);
    final radius = (math.max(30.0, 3 * sigma)).clamp(30.0, 70.0).toDouble();
    final gate = (math.max(18.0, 2.5 * sigma)).clamp(18.0, 45.0).toDouble();

    // ---- parked: hold the previous result so the car does not wander ----
    if (speed < 0.8 && _lastResult != null && _hasLastRaw) {
      final moved = math.sqrt(math.pow(x - _lastRawX, 2) + math.pow(y - _lastRawY, 2));
      if (moved < math.max(6.0, sigma)) return _lastResult;
    }

    final headingValid = speed >= 1.5;
    final headingW = ((speed - 1.0) / 3.0).clamp(0.0, 1.0).toDouble();
    final heading = p.headingDeg;

    final cands = <_Cand>[];
    final cx0 = ((x - radius) / _cell).floor();
    final cx1 = ((x + radius) / _cell).floor();
    final cy0 = ((y - radius) / _cell).floor();
    final cy1 = ((y + radius) / _cell).floor();
    final seen = <int>{};
    for (var cx = cx0; cx <= cx1; cx++) {
      for (var cy = cy0; cy <= cy1; cy++) {
        final ids = _grid[_cellKey(cx, cy)];
        if (ids == null) continue;
        for (final id in ids) {
          if (!seen.add(id)) continue;
          final s = _segs[id];
          final dx = s.bx - s.ax, dy = s.by - s.ay;
          var t = ((x - s.ax) * dx + (y - s.ay) * dy) / (s.len * s.len);
          t = t.clamp(0.0, 1.0).toDouble();
          final px = s.ax + dx * t, py = s.ay + dy * t;
          final d = math.sqrt(math.pow(x - px, 2) + math.pow(y - py, 2));
          if (d > radius) continue;
          final c = _score(s, d, t, px, py, speed, headingValid, headingW,
              heading, sigma);
          if (c != null) cands.add(c);
        }
      }
    }
    if (cands.isEmpty) {
      _lockCount = 0;
      _curRoad = null;
      _curIsService = false;
      return null;
    }

    // ---- service-zone awareness (university / hospital / parking) ----------
    // If the car is clearly nearer to an internal road than to any main road,
    // the -0.8 "service" prior must not make the outer street win. Inside a
    // known campus context (recent service matches) the prior is cancelled
    // and the nearer internal road gets an extra distance-gap bonus.
    var dMain = double.infinity;
    for (final c in cands) {
      if (!c.seg.profile.vehicle) continue;
      if (!c.seg.profile.service && c.dist < dMain) dMain = c.dist;
    }
    final inCampus = _svcCtx >= 2 || _curIsService;
    for (final c in cands) {
      final pr = c.seg.profile;
      if (!pr.service) continue;
      var bonus = 0.0;
      if (inCampus) bonus += -pr.prior + 0.8; // cancel prior, favour internal
      if (dMain.isFinite && c.dist + 5.0 < dMain) {
        bonus += math.min(2.5, (dMain - c.dist) / 5.0);
      } else if (!dMain.isFinite) {
        bonus += -pr.prior * 0.5; // only service roads around: no penalty
      }
      c.score += bonus;
    }

    cands.sort((a, b) => b.score.compareTo(a.score));
    var best = cands.first;

    // ---- hysteresis against the current road ----
    if (_curRoad != null && best.seg.road != _curRoad) {
      _Cand? current;
      for (final c in cands) {
        if (c.seg.road == _curRoad) {
          current = c;
          break;
        }
      }
      if (current != null && current.dist <= gate) {
        // Leaving an internal road for a main road must be convincing; the
        // car really on the outer street is much closer to it than to us.
        final leavingCampus = _curIsService && !best.seg.profile.service;
        final reallyOnMain = leavingCampus &&
            best.dist <= 6.0 &&
            current.dist >= best.dist + 10.0;
        final margin = leavingCampus && !reallyOnMain ? 4.0 : 2.0;
        final instant = leavingCampus && !reallyOnMain ? 10.0 : 6.0;
        final votesNeeded = leavingCampus && !reallyOnMain ? 3 : 2;
        if (best.score > current.score + margin) {
          if (_challengerRoad == best.seg.road) {
            _switchVotes++;
          } else {
            _challengerRoad = best.seg.road;
            _switchVotes = 1;
          }
          // Strongly better (e.g. clear heading mismatch) switches at once.
          if (best.score > current.score + instant ||
              _switchVotes >= votesNeeded) {
            _switchVotes = 0;
            _challengerRoad = null;
          } else {
            best = current;
          }
        } else {
          _switchVotes = 0;
          _challengerRoad = null;
          best = current;
        }
      } else {
        _switchVotes = 0;
        _challengerRoad = null;
      }
    } else {
      _switchVotes = 0;
      _challengerRoad = null;
    }

    if (best.dist > gate) {
      _lockCount = 0;
      _curRoad = null;
      _curIsService = false;
      return null;
    }
    if (speed < 0.8 && !hasLock && best.dist > 6.0) {
      // parked off-road / in a lot: do not drag the car onto the street
      _hasLastRaw = true;
      _lastRawX = x;
      _lastRawY = y;
      return null;
    }

    _curRoad = best.seg.road;
    _curSeg = best.seg.idx;
    _lockCount++;
    if (best.seg.profile.service) {
      if (speed >= 0.8) _svcCtx = math.min(6, _svcCtx + 1);
      _curIsService = true;
    } else {
      _svcCtx = math.max(0, _svcCtx - 2);
      _curIsService = false;
    }

    // ---- blend weight ----
    final inner = 0.35 * gate;
    var wGate = best.dist <= inner
        ? 1.0
        : 1.0 - math.pow((best.dist - inner) / (gate - inner), 2).toDouble();
    wGate = wGate.clamp(0.0, 1.0).toDouble();
    final wSpeed = speed < 1.0 ? 0.0 : (speed < 3.0 ? 0.6 : 1.0);
    final w = wGate * (hasLock ? math.max(wSpeed, speed < 1.0 ? 0.0 : 0.8) : wSpeed);

    var sx = x + (best.px - x) * w;
    var sy = y + (best.py - y) * w;

    // ---- direction of travel along the segment ----
    final travelBearing =
        best.dirFwd ? best.seg.bearing : normDeg(best.seg.bearing + 180.0);
    double outHeading;
    if (headingValid && best.dAng <= 45.0) {
      outHeading = lerpAngleDeg(heading, travelBearing, 0.75);
    } else if (!headingValid && _lastHeading != null && w > 0.5) {
      // slow: keep last heading, but snap to the road axis if it agrees
      final fwdDiff = absAngleDiffDeg(_lastHeading!, best.seg.bearing);
      final bwdDiff = 180.0 - fwdDiff;
      final axis = fwdDiff <= bwdDiff
          ? best.seg.bearing
          : normDeg(best.seg.bearing + 180.0);
      outHeading = math.min(fwdDiff, bwdDiff) < 35 ? axis : _lastHeading!;
    } else {
      outHeading = heading;
    }

    // ---- drive on the correct side of two-way roads ----
    if (best.seg.oneway == 0 &&
        headingValid &&
        speed > 2.5 &&
        best.dAng < 45 &&
        w > 0.8 &&
        best.seg.profile.vehicle) {
      final off = math.min(best.seg.width / 4.0, 1.8);
      final side = leftHandTraffic ? -1.0 : 1.0;
      final th = travelBearing * kDegToRad;
      // right-hand normal of travel direction: (cos, -sin) in (E, N)
      sx += side * off * math.cos(th) * w;
      sy -= side * off * math.sin(th) * w;
    }

    _lastHeading = normDeg(outHeading);
    _lastRawX = x;
    _lastRawY = y;
    _hasLastRaw = true;
    final result = SnapResult(
      lat: _refLat + sy / _mLat,
      lng: _refLng + sx / _mLng,
      headingDeg: _lastHeading!,
      roadKey: best.seg.road,
      distanceM: best.dist,
      confidence: w,
    );
    _lastResult = result;
    return result;
  }

  _Cand? _score(_Seg s, double d, double t, double px, double py, double speed,
      bool headingValid, double headingW, double heading, double sigma) {
    var score = -0.5 * math.pow(d / math.max(sigma, 5.0), 2).toDouble();
    score += s.profile.prior;
    // direction
    var dirFwd = true;
    var dAng = 0.0;
    if (headingValid) {
      final dFwd = absAngleDiffDeg(heading, s.bearing);
      final dBwd = 180.0 - dFwd;
      final sigH = 25.0 + (speed < 4 ? (4 - speed) * 8 : 0);
      if (s.oneway == 1) {
        dirFwd = true;
        dAng = dFwd;
      } else if (s.oneway == -1) {
        dirFwd = false;
        dAng = dBwd;
      } else {
        dirFwd = dFwd <= dBwd;
        dAng = math.min(dFwd, dBwd);
      }
      var pen = 0.5 * math.pow(dAng / sigH, 2).toDouble();
      if (s.oneway != 0) {
        pen = math.min(pen * 1.5, 30.0);
        if (dAng > 135.0) pen += 6.0; // wrong way on a one-way street
      }
      score -= math.min(pen, 30.0) * headingW;
    }
    // speed plausibility for the class
    final kmh = speed * 3.6;
    if (kmh > s.profile.maxKmh * 1.3) {
      score -= math.min(10.0, (kmh - s.profile.maxKmh) / 10.0);
    }
    if (!s.profile.vehicle) {
      score -= kmh > 12 ? 12.0 : 3.0;
    }
    // continuity
    if (_curRoad != null) {
      if (s.road == _curRoad) {
        score += 1.5;
        if ((s.idx - _curSeg).abs() <= 1) score += 0.8;
      } else if (_curRoad != null && _connectedToCurrent(s)) {
        score += 0.8;
      }
    }
    return _Cand(s, d, t, px, py, dirFwd, dAng, score);
  }

  bool _connectedToCurrent(_Seg s) {
    if (_curSeg < 0) return false;
    // Look at the current road's segments touching this candidate's end points.
    final ids = _grid[_cellKey(((s.ax + s.bx) / 2 / _cell).floor(),
        ((s.ay + s.by) / 2 / _cell).floor())];
    if (ids == null) return false;
    for (final id in ids) {
      final o = _segs[id];
      if (o.road != _curRoad) continue;
      if (_close(o.ax, o.ay, s.ax, s.ay) ||
          _close(o.ax, o.ay, s.bx, s.by) ||
          _close(o.bx, o.by, s.ax, s.ay) ||
          _close(o.bx, o.by, s.bx, s.by)) {
        return true;
      }
    }
    return false;
  }

  static bool _close(double ax, double ay, double bx, double by) =>
      (ax - bx).abs() < 3.0 && (ay - by).abs() < 3.0;
}
