import 'dart:async';
import 'dart:math' as math;

import '../../../core/geo/geo_types.dart';
import '../data/gps_math.dart';
import '../data/location_service.dart';
import '../data/road_snapper.dart';

/// Turns filtered GPS fixes into the position shown on the map:
///  * free drive  -> road snapping ([RoadSnapper]) + smooth animation
///  * route drive -> projection onto the active route + smooth animation
class NavigationPositionController {
  NavigationPositionController();

  final StreamController<VehiclePosition> _controller =
      StreamController<VehiclePosition>.broadcast();
  StreamSubscription<VehiclePosition>? _sub;
  Timer? _ticker;
  final Stopwatch _clock = Stopwatch()..start();

  VehiclePosition? _target;
  int _targetAtMs = 0;
  int _lastFixMs = 0;
  VehiclePosition? _lastEmit;
  double _dLat = 0, _dLng = 0, _dHead = 0;
  bool _hasDisp = false;
  int _lastTickMs = 0;

  // ---- route state ----
  List<double>? _rx, _ry, _cum;
  double _refLat = 0, _refLng = 0, _mLat = 111000, _mLng = 111000;
  double _progress = 0;
  bool _routeActive = false;
  bool _routeDriven = false;
  bool _needFullSearch = true;
  int _offRouteSinceMs = 0;

  Stream<VehiclePosition> get positionStream async* {
    final l = _lastEmit;
    if (l != null) yield l;
    yield* _controller.stream;
  }

  bool get isRouteDriven => _routeActive && _routeDriven;

  // ------------------------------------------------------------------ API --

  void attach(Stream<VehiclePosition> rawFiltered) {
    _sub?.cancel();
    _sub = rawFiltered.listen(_onFix, onError: (_) {});
  }

  void seed(VehiclePosition pos) {
    _target = pos;
    _targetAtMs = _clock.elapsedMilliseconds;
    _dLat = pos.lat;
    _dLng = pos.lng;
    _dHead = pos.headingDeg;
    _hasDisp = true;
    _emitDisplay(pos);
  }

  void setActiveRoute(List<LatLng> geometry, {VehiclePosition? anchor}) {
    if (geometry.length < 2) {
      clearActiveRoute();
      return;
    }
    _refLat = geometry.first.latitude;
    _refLng = geometry.first.longitude;
    _mLat = mPerDegLat(_refLat);
    _mLng = mPerDegLng(_refLat);
    final n = geometry.length;
    final xs = List<double>.filled(n, 0);
    final ys = List<double>.filled(n, 0);
    final cum = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      xs[i] = (geometry[i].longitude - _refLng) * _mLng;
      ys[i] = (geometry[i].latitude - _refLat) * _mLat;
      if (i > 0) {
        cum[i] = cum[i - 1] +
            math.sqrt(math.pow(xs[i] - xs[i - 1], 2) + math.pow(ys[i] - ys[i - 1], 2));
      }
    }
    _rx = xs;
    _ry = ys;
    _cum = cum;
    _progress = 0;
    _routeActive = true;
    _routeDriven = false;
    _needFullSearch = true;
    _offRouteSinceMs = 0;
    RoadSnapper.instance.reset();
    final a = anchor ?? _target;
    if (a != null) _onFix(a);
  }

  void clearActiveRoute() {
    _routeActive = false;
    _routeDriven = false;
    _rx = _ry = _cum = null;
    _progress = 0;
  }

  void resetToFreeDrive(VehiclePosition position) {
    clearActiveRoute();
    RoadSnapper.instance.reset();
    seed(position);
  }

  /// Re-anchors route progress to the real GPS position (after reroute / skip).
  void adoptGpsAnchor(VehiclePosition position) {
    _needFullSearch = true;
    _onFix(position);
  }

  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _controller.close();
  }

  // ------------------------------------------------------------- pipeline --

  void _onFix(VehiclePosition fix) {
    final nowMs = _clock.elapsedMilliseconds;
    final dt = _lastFixMs == 0
        ? 1.0
        : ((nowMs - _lastFixMs) / 1000.0).clamp(0.2, 5.0).toDouble();
    _lastFixMs = nowMs;

    final target = _routeActive ? _routeTarget(fix, nowMs) : _freeTarget(fix, dt);
    _target = target;
    _targetAtMs = nowMs;

    if (!_hasDisp ||
        distanceM(_dLat, _dLng, target.lat, target.lng) > 120) {
      _dLat = target.lat;
      _dLng = target.lng;
      _dHead = target.headingDeg;
      _hasDisp = true;
    }
    _ensureTicker();
    _tick();
  }

  VehiclePosition _freeTarget(VehiclePosition fix, double dt) {
    final s = RoadSnapper.instance.snap(fix, dtSec: dt);
    if (s == null) return fix;
    return VehiclePosition(
      lat: s.lat,
      lng: s.lng,
      headingDeg: s.headingDeg,
      speedKmh: fix.speedKmh,
      accuracyM: fix.accuracyM,
      isEstimated: fix.isEstimated,
    );
  }

  VehiclePosition _routeTarget(VehiclePosition fix, int nowMs) {
    final xs = _rx!, ys = _ry!, cum = _cum!;
    final px = (fix.lng - _refLng) * _mLng;
    final py = (fix.lat - _refLat) * _mLat;
    final n = xs.length;

    var lo = 0, hi = n - 2;
    if (!_needFullSearch) {
      // window: 120 m behind .. 600 m ahead of current progress
      lo = _segmentAt(_progress - 120);
      hi = _segmentAt(_progress + 600);
    }
    double bestD = double.infinity, bestProg = _progress, bx = px, by = py;
    int bestSeg = lo;
    for (var i = lo; i <= hi && i < n - 1; i++) {
      final ax = xs[i], ay = ys[i];
      final dx = xs[i + 1] - ax, dy = ys[i + 1] - ay;
      final l2 = dx * dx + dy * dy;
      final t = l2 < 1e-9
          ? 0.0
          : (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0).toDouble();
      final qx = ax + dx * t, qy = ay + dy * t;
      final d = math.sqrt(math.pow(px - qx, 2) + math.pow(py - qy, 2));
      // prefer forward-most among near ties so loops/roundabouts advance
      if (d < bestD - 1.5 || (d <= bestD + 1.5 && cum[i] + t * math.sqrt(l2) > bestProg)) {
        if (d < bestD || d <= bestD + 1.5) {
          bestD = math.min(bestD, d);
          bestProg = cum[i] + t * math.sqrt(l2);
          bx = qx;
          by = qy;
          bestSeg = i;
        }
      }
    }
    final gate = math.max(30.0, 2.5 * fix.accuracyM);
    if (bestD <= gate) {
      _needFullSearch = false;
      _routeDriven = true;
      _offRouteSinceMs = 0;
      if (bestProg >= _progress - 15) _progress = math.max(_progress, bestProg);
      final seg = math.min(bestSeg, n - 2);
      final hd = normDeg(math.atan2(xs[seg + 1] - xs[seg], ys[seg + 1] - ys[seg]) * kRadToDeg);
      final heading = fix.speedKmh >= 3.0
          ? hd
          : (_target?.headingDeg ?? fix.headingDeg);
      return VehiclePosition(
        lat: _refLat + by / _mLat,
        lng: _refLng + bx / _mLng,
        headingDeg: heading,
        speedKmh: fix.speedKmh,
        accuracyM: fix.accuracyM,
        isEstimated: fix.isEstimated,
      );
    }
    // off route: show the real position so reroute logic sees the deviation
    _routeDriven = false;
    if (_offRouteSinceMs == 0) _offRouteSinceMs = nowMs;
    if (nowMs - _offRouteSinceMs > 4000) _needFullSearch = true;
    return fix;
  }

  int _segmentAt(double progress) {
    final cum = _cum!;
    if (progress <= 0) return 0;
    var lo = 0, hi = cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cum[mid] <= progress) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return math.min(lo, cum.length - 2);
  }

  // ------------------------------------------------------------ animation --

  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    _lastTickMs = _clock.elapsedMilliseconds;
  }

  void _tick() {
    final t = _target;
    if (t == null) return;
    final now = _clock.elapsedMilliseconds;
    final dt = math.max(0.001, (now - _lastTickMs) / 1000.0);
    _lastTickMs = now;

    // dead-reckon the target forward (GPS arrives ~1 Hz)
    final age = math.min((now - _targetAtMs) / 1000.0, 2.0);
    var pLat = t.lat, pLng = t.lng;
    final v = t.speedKmh / 3.6;
    if (v > 0.7 && age > 0) {
      final o = offsetLatLng(t.lat, t.lng, t.headingDeg, v * age);
      pLat = o.lat;
      pLng = o.lng;
    }
    final a = 1 - math.exp(-dt / 0.30);
    _dLat += (pLat - _dLat) * a;
    _dLng += (pLng - _dLng) * a;
    _dHead = lerpAngleDeg(_dHead, t.headingDeg, 1 - math.exp(-dt / 0.25));

    final converged = distanceM(_dLat, _dLng, pLat, pLng) < 0.25 &&
        absAngleDiffDeg(_dHead, t.headingDeg) < 1.0;
    if (v < 0.3 && converged) {
      _dLat = pLat;
      _dLng = pLng;
      _dHead = t.headingDeg;
      _ticker?.cancel();
      _ticker = null;
    }
    _emitDisplay(t);
  }

  void _emitDisplay(VehiclePosition t) {
    final out = VehiclePosition(
      lat: _dLat,
      lng: _dLng,
      headingDeg: _dHead,
      speedKmh: t.speedKmh,
      accuracyM: t.accuracyM,
      isEstimated: t.isEstimated,
    );
    _lastEmit = out;
    if (!_controller.isClosed) _controller.add(out);
  }
}
