import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:abtin_maps/core/geo/geo_types.dart';

/// شکلِ واقعیِ یک مانور (پیچ، میدان، دوربرگردان…) که از خودِ هندسهٔ مسیر بریده
/// می‌شود. همین شکل هم روی نقشه به‌صورت فلش رسم می‌شود و هم داخل کارت مسیر
/// به‌عنوان راهنما نشان داده می‌شود؛ پس دو جا همیشه یکسان‌اند.
class ManeuverShape {
  const ManeuverShape({
    required this.points,
    required this.local,
    required this.center,
    required this.originLat,
    required this.originLon,
    required this.entryBearingDeg,
  });

  /// نقاط هموارشدهٔ فلش روی نقشه.
  final List<LatLng> points;

  /// همان نقاط به متر (x = شرق، y = شمال) نسبت به نقطهٔ اول.
  final List<Offset> local;

  /// نقطهٔ مانور (گوشهٔ پیچ / ورودی میدان) به متر.
  final Offset center;

  final double originLat;
  final double originLon;

  /// جهتِ حرکت در ابتدای شکل (درجه از شمال، ساعتگرد).
  final double entryBearingDeg;

  /// خط بدنه (کوتاه‌شده تا ابتدای نوک) + چندضلعی نوک فلش، هر دو به‌صورت
  /// مختصات جغرافیایی. اندازه‌ها به متر هستند.
  ({List<LatLng> line, List<LatLng> head}) arrowParts({
    required double headLengthM,
    required double headWidthM,
  }) {
    if (local.length < 2) {
      return (line: points, head: const <LatLng>[]);
    }
    final tip = local.last;
    // جهتِ انتهایی: میانگینِ حدود ۶ متر آخر تا نوک روی خمِ تیز نلرزد.
    var back = local.length - 2;
    var acc = 0.0;
    while (back > 0 && acc < 6.0) {
      acc += (local[back + 1] - local[back]).distance;
      back--;
    }
    var dir = tip - local[back];
    final len = dir.distance;
    if (len < 0.01) return (line: points, head: const <LatLng>[]);
    dir = Offset(dir.dx / len, dir.dy / len);
    final normal = Offset(-dir.dy, dir.dx);

    final hl = math.min(headLengthM, math.max(2.0, _pathLength(local) * 0.45));
    final baseCenter = tip - dir * hl;
    final left = baseCenter + normal * (headWidthM / 2);
    final right = baseCenter - normal * (headWidthM / 2);

    // خط را کمی داخل نوک نگه می‌داریم تا بین بدنه و نوک شکاف نیفتد.
    final trimmed = _trimEnd(local, hl * 0.7);
    return (
      line: [for (final o in trimmed) _toLatLng(o)],
      head: [_toLatLng(left), _toLatLng(tip), _toLatLng(right), _toLatLng(left)],
    );
  }

  LatLng _toLatLng(Offset o) {
    final cosLat = math.cos(originLat * math.pi / 180.0);
    return LatLng(
      originLat + o.dy / _mPerDegLat,
      originLon + o.dx / (_mPerDegLat * (cosLat.abs() < 1e-6 ? 1e-6 : cosLat)),
    );
  }
}

const double _mPerDegLat = 111320.0;

double _pathLength(List<Offset> pts) {
  var t = 0.0;
  for (var i = 1; i < pts.length; i++) {
    t += (pts[i] - pts[i - 1]).distance;
  }
  return t;
}

List<Offset> _trimEnd(List<Offset> pts, double meters) {
  if (pts.length < 2 || meters <= 0) return pts;
  final out = List<Offset>.of(pts);
  var remaining = meters;
  while (out.length > 2) {
    final seg = (out.last - out[out.length - 2]).distance;
    if (seg > remaining) break;
    remaining -= seg;
    out.removeLast();
  }
  final a = out[out.length - 2];
  final b = out.last;
  final seg = (b - a).distance;
  if (seg > 0.001 && remaining < seg) {
    final t = (seg - remaining) / seg;
    out[out.length - 1] = a + (b - a) * t;
  }
  return out;
}

class ManeuverGeometry {
  ManeuverGeometry._();

  /// نقطهٔ مسیر در فاصلهٔ [meters] از ابتدا (با درون‌یابی).
  static LatLng? pointAt(List<LatLng> g, List<double> cum, double meters) {
    if (g.length < 2) return null;
    final m = meters.clamp(0.0, cum.last).toDouble();
    var lo = 0;
    var hi = g.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg <= 0.0001 ? 0.0 : ((m - cum[lo]) / seg).clamp(0.0, 1.0);
    return LatLng(
      g[lo].latitude + (g[hi].latitude - g[lo].latitude) * t,
      g[lo].longitude + (g[hi].longitude - g[lo].longitude) * t,
    );
  }

  static List<double> cumulative(List<LatLng> g) {
    final out = List<double>.filled(g.length, 0);
    for (var i = 1; i < g.length; i++) {
      out[i] = out[i - 1] + _meters(g[i - 1], g[i]);
    }
    return out;
  }

  static double _meters(LatLng a, LatLng b) {
    final latRad = ((a.latitude + b.latitude) / 2) * math.pi / 180.0;
    final dx = (b.longitude - a.longitude) * _mPerDegLat * math.cos(latRad);
    final dy = (b.latitude - a.latitude) * 110540.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// شکل مانور را از مسیر می‌برد.
  ///
  /// [startProgressM]..[endProgressM]: بازهٔ مانور روی مسیر (برای پیچ ساده هر دو
  /// برابرند؛ برای میدان از ورودی تا خروجی). [beforeM] و [afterM] مسیرِ قبل و
  /// بعد از مانور را اضافه می‌کنند.
  static ManeuverShape? build(
    List<LatLng> geometry,
    List<double> cum, {
    required double startProgressM,
    double? endProgressM,
    double beforeM = 48,
    double afterM = 42,
    double maxLengthM = 220,
  }) {
    if (geometry.length < 2 || cum.length != geometry.length) return null;
    final total = cum.last;
    if (total < 3) return null;
    final endP = math.max(startProgressM, endProgressM ?? startProgressM);
    var from = math.max(0.0, startProgressM - beforeM);
    var to = math.min(total, endP + afterM);
    if (to - from > maxLengthM) {
      // میدان‌های خیلی بزرگ: ابتدا و انتها را حفظ نکن، به اطراف مانور محدود کن.
      to = from + maxLengthM;
    }
    if (to - from < 4) return null;

    final raw = <LatLng>[];
    final start = pointAt(geometry, cum, from);
    final end = pointAt(geometry, cum, to);
    if (start == null || end == null) return null;
    raw.add(start);
    for (var i = 0; i < geometry.length; i++) {
      if (cum[i] > from + 0.5 && cum[i] < to - 0.5) raw.add(geometry[i]);
    }
    raw.add(end);
    final center = pointAt(geometry, cum, startProgressM) ?? start;

    final lat0 = raw.first.latitude;
    final lon0 = raw.first.longitude;
    final cosLat = math.cos(lat0 * math.pi / 180.0);
    Offset toLocal(LatLng p) => Offset(
          (p.longitude - lon0) * _mPerDegLat * cosLat,
          (p.latitude - lat0) * _mPerDegLat,
        );

    var local = <Offset>[for (final p in raw) toLocal(p)];
    local = _dedupe(local);
    if (local.length < 2) return null;
    final centerLocal = toLocal(center);

    final shape = ManeuverShape(
      points: const <LatLng>[],
      local: local,
      center: centerLocal,
      originLat: lat0,
      originLon: lon0,
      entryBearingDeg: _bearingLocal(local, fromStart: true),
    );
    return ManeuverShape(
      points: [for (final o in local) shape._toLatLng(o)],
      local: local,
      center: centerLocal,
      originLat: lat0,
      originLon: lon0,
      entryBearingDeg: shape.entryBearingDeg,
    );
  }

  static List<Offset> _dedupe(List<Offset> pts) {
    final out = <Offset>[];
    for (final p in pts) {
      if (out.isEmpty || (p - out.last).distance > 0.4) out.add(p);
    }
    return out;
  }

  static double _bearingLocal(List<Offset> pts, {required bool fromStart}) {
    if (pts.length < 2) return 0;
    var i = 1;
    var acc = 0.0;
    while (i < pts.length - 1 && acc < 8.0) {
      acc += (pts[i] - pts[i - 1]).distance;
      i++;
    }
    final d = pts[i] - pts.first;
    return (math.atan2(d.dx, d.dy) * 180 / math.pi + 360) % 360;
  }

  /// گوشه‌های تیز را گرد می‌کند (برش گوشه، شبیه Chaikin) بدون اینکه نقطه‌های
  /// خطِ مستقیم زیاد شوند. فقط رأس‌هایی که زاویهٔ چرخششان ≥ [minTurnDeg] است
  /// جایگزین می‌شوند و فاصلهٔ برش از [maxCutM] بیشتر نمی‌شود.
  static List<Offset> smoothLocal(
    List<Offset> input, {
    double minTurnDeg = 8,
    int iterations = 2,
    double cutFraction = 0.30,
    double maxCutM = 12,
  }) {
    var pts = input;
    for (var it = 0; it < iterations; it++) {
      if (pts.length < 3) return pts;
      final out = <Offset>[pts.first];
      for (var i = 1; i < pts.length - 1; i++) {
        final a = pts[i - 1];
        final v = pts[i];
        final b = pts[i + 1];
        final d1 = v - a;
        final d2 = b - v;
        final l1 = d1.distance;
        final l2 = d2.distance;
        if (l1 < 0.01 || l2 < 0.01) {
          out.add(v);
          continue;
        }
        final cross = d1.dx * d2.dy - d1.dy * d2.dx;
        final dot = d1.dx * d2.dx + d1.dy * d2.dy;
        final turn = (math.atan2(cross, dot) * 180 / math.pi).abs();
        if (turn < minTurnDeg) {
          out.add(v);
          continue;
        }
        final c1 = math.min(cutFraction * l1, maxCutM);
        final c2 = math.min(cutFraction * l2, maxCutM);
        final f1 = math.min(0.45, c1 / l1);
        final f2 = math.min(0.45, c2 / l2);
        out.add(v - d1 * f1);
        out.add(v + d2 * f2);
      }
      out.add(pts.last);
      pts = out;
    }
    return pts;
  }

  /// هموارسازیِ هندسهٔ کل مسیر (فقط روی گوشه‌ها). برای مسیرهای آفلاین که در
  /// میدان‌ها و پیچ‌ها چندضلعیِ تیز دارند. تعداد نقطه‌ها فقط در گوشه‌ها بیشتر
  /// می‌شود و انحراف از مسیر اصلی چند متر بیشتر نیست.
  static List<LatLng> smoothRoute(List<LatLng> g) {
    if (g.length < 3) return g;
    final lat0 = g.first.latitude;
    final lon0 = g.first.longitude;
    final cosLat = math.cos(lat0 * math.pi / 180.0);
    final kx = _mPerDegLat * (cosLat.abs() < 1e-6 ? 1e-6 : cosLat);
    final local = <Offset>[
      for (final p in g)
        Offset((p.longitude - lon0) * kx, (p.latitude - lat0) * _mPerDegLat),
    ];
    final smooth = smoothLocal(
      local,
      minTurnDeg: 10,
      iterations: 2,
      cutFraction: 0.28,
      maxCutM: 8,
    );
    if (identical(smooth, local)) return g;
    return List<LatLng>.unmodifiable([
      for (final o in smooth) LatLng(lat0 + o.dy / _mPerDegLat, lon0 + o.dx / kx),
    ]);
  }
}
