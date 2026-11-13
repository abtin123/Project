import 'dart:math' as math;

import 'package:abtin_maps/core/geo/geo_types.dart';

/// A stretch of road the driver reported as closed. Routing must not use it.
class RoadBlock {
  const RoadBlock(this.polyline, {required this.lengthM});

  final List<LatLng> polyline;
  final double lengthM;

  /// A road closer than this to the blocked line counts as part of the block.
  static const double radiusM = 14.0;

  /// A route has to run along the blocked line for at least this long to be
  /// considered "using" it (a crossing street only touches it for a few metres).
  static const double minOverlapM = 30.0;

  /// Gap kept free right in front of the car so the current road can still be left.
  static const double gapAheadM = 12.0;

  static const double _mLat = 110540.0;

  static double _mLon(double lat) =>
      111320.0 * math.cos(lat * math.pi / 180.0).abs().clamp(0.2, 1.0);

  static double meters(LatLng a, LatLng b) {
    final dLat = (b.latitude - a.latitude) * _mLat;
    final dLon =
        (b.longitude - a.longitude) * _mLon((a.latitude + b.latitude) / 2);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  /// Cuts [lengthM] metres of [geometry] starting [fromM] metres from its start
  /// (plus [gapAheadM]).
  static RoadBlock? alongRoute(
    List<LatLng> geometry, {
    required double fromM,
    required double lengthM,
  }) {
    if (geometry.length < 2 || lengthM <= 0) return null;
    final start = fromM + gapAheadM;
    final end = start + lengthM;
    final out = <LatLng>[];
    var travelled = 0.0;
    for (var i = 1; i < geometry.length; i++) {
      final a = geometry[i - 1], b = geometry[i];
      final seg = meters(a, b);
      if (seg < 0.01) continue;
      final segStart = travelled, segEnd = travelled + seg;
      travelled = segEnd;
      if (segEnd <= start) continue;
      if (segStart >= end) break;
      LatLng at(double d) {
        final t = ((d - segStart) / seg).clamp(0.0, 1.0).toDouble();
        return LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
      }

      if (out.isEmpty) out.add(at(math.max(start, segStart)));
      out.add(at(math.min(end, segEnd)));
    }
    if (out.length < 2) return null;
    final covered = _length(out);
    return RoadBlock(List<LatLng>.unmodifiable(out), lengthM: covered);
  }

  static double _length(List<LatLng> line) {
    var m = 0.0;
    for (var i = 1; i < line.length; i++) {
      m += meters(line[i - 1], line[i]);
    }
    return m;
  }

  /// Metres of [line] that run within [radiusM] of [block].
  static double overlapMeters(List<LatLng> line, List<LatLng> block) {
    if (line.length < 2 || block.length < 2) return 0;
    final lat0 = block[block.length ~/ 2].latitude;
    final lon0 = block[block.length ~/ 2].longitude;
    final mLon = _mLon(lat0);
    double x(LatLng p) => (p.longitude - lon0) * mLon;
    double y(LatLng p) => (p.latitude - lat0) * _mLat;

    final bx = <double>[for (final p in block) x(p)];
    final by = <double>[for (final p in block) y(p)];
    var minX = bx.first, maxX = bx.first, minY = by.first, maxY = by.first;
    for (var i = 1; i < bx.length; i++) {
      minX = math.min(minX, bx[i]);
      maxX = math.max(maxX, bx[i]);
      minY = math.min(minY, by[i]);
      maxY = math.max(maxY, by[i]);
    }
    minX -= radiusM;
    maxX += radiusM;
    minY -= radiusM;
    maxY += radiusM;

    double distToBlock(double px, double py) {
      var best = double.infinity;
      for (var i = 1; i < bx.length; i++) {
        final ax = bx[i - 1], ay = by[i - 1];
        final dx = bx[i] - ax, dy = by[i] - ay;
        final len2 = dx * dx + dy * dy;
        var t = len2 < 1e-9 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
        t = t.clamp(0.0, 1.0).toDouble();
        final qx = ax + dx * t - px, qy = ay + dy * t - py;
        final d2 = qx * qx + qy * qy;
        if (d2 < best) best = d2;
      }
      return math.sqrt(best);
    }

    const step = 6.0;
    var overlap = 0.0;
    for (var i = 1; i < line.length; i++) {
      final ax = x(line[i - 1]), ay = y(line[i - 1]);
      final cx = x(line[i]), cy = y(line[i]);
      if (math.max(ax, cx) < minX ||
          math.min(ax, cx) > maxX ||
          math.max(ay, cy) < minY ||
          math.min(ay, cy) > maxY) {
        continue;
      }
      final len = math.sqrt((cx - ax) * (cx - ax) + (cy - ay) * (cy - ay));
      final n = math.max(1, (len / step).ceil());
      for (var k = 0; k < n; k++) {
        final t = (k + 0.5) / n;
        final px = ax + (cx - ax) * t, py = ay + (cy - ay) * t;
        if (px < minX || px > maxX || py < minY || py > maxY) continue;
        if (distToBlock(px, py) <= radiusM) overlap += len / n;
      }
    }
    return overlap;
  }

  /// True when [route] drives along any of [blocks].
  static bool hits(List<LatLng> route, List<RoadBlock> blocks) {
    for (final b in blocks) {
      if (overlapMeters(route, b.polyline) >= minOverlapM) return true;
    }
    return false;
  }

  /// Via-point candidates on both sides of the blocked stretch, nearest first.
  /// Used by routers that cannot avoid an area themselves (public OSRM).
  static List<LatLng> detourCandidates(RoadBlock block) {
    final line = block.polyline;
    if (line.length < 2) return const [];
    final a = line.first, b = line.last;
    final mid = LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
    final mLon = _mLon(mid.latitude);
    final dx = (b.longitude - a.longitude) * mLon;
    final dy = (b.latitude - a.latitude) * _mLat;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return const [];
    // Unit vector perpendicular to the blocked chord.
    final px = -dy / len, py = dx / len;
    LatLng offset(LatLng from, double metres) => LatLng(
          from.latitude + py * metres / _mLat,
          from.longitude + px * metres / mLon,
        );
    final extent = math.max(len * 0.6, 250.0);
    final out = <LatLng>[];
    for (final w in <double>[extent, extent * 2, extent * 4]) {
      out
        ..add(offset(mid, w))
        ..add(offset(mid, -w));
    }
    out
      ..add(offset(a, extent * 1.5))
      ..add(offset(a, -extent * 1.5))
      ..add(offset(b, extent * 1.5))
      ..add(offset(b, -extent * 1.5));
    return out;
  }
}
