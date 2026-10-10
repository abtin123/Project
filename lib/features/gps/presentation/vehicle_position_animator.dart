import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/geo/geo_types.dart';

import '../data/location_service.dart';
import '../data/road_snapper.dart';
import 'gps_providers.dart';

class VehiclePositionAnimator {
  static const double _maxAccelerationKmhPerSec = 18.0;
  static const double _maxBrakingKmhPerSec = 28.0;
  static const double _maxSpeedKmh = 240.0;

  static const double _progressCorrectionGain = 0.55;
  static const double _maxForwardCorrectionMps = 14.0;
  static const double _maxBackwardHoldM = 3.0;
  static const double _ignoreProgressErrorM = 2.5;
  static const double _hardForwardErrorM = 90.0;

  static const double _realCorrectionMps = 4.5;
  static const double _estimatedCorrectionMps = 1.5;
  static const double _maxCorrectionPerFixM = 12.0;

  double? _lat;
  double? _lng;
  double _headingDeg = 0;
  double _targetHeadingDeg = 0;
  double _renderedSpeedKmh = 0;
  double _targetSpeedKmh = 0;
  double _accuracyM = 50;

  double _correctionEastM = 0;
  double _correctionNorthM = 0;
  bool _correctionIsEstimated = false;

  List<({double lat, double lng})>? _routePoints;
  List<double>? _routeCumulativeM;
  double? _routeProgressM;
  double _routeCorrectionM = 0;
  bool _routeDriven = false;
  DateTime? _routeEndReachedAt;

  DateTime? _lastTick;
  DateTime? _lastFixAt;

  bool _roadLocked = false;
  static const double _roadPullMps = 14.0;

  final _controller = StreamController<VehiclePosition>.broadcast();
  Ticker? _ticker;
  Duration? _lastTickerElapsed;
  bool _disposed = false;

  Stream<VehiclePosition> get stream => _controller.stream;

  bool get isRouteDriven => _routeDriven;

  void setRoute(List<LatLng> geometry, {VehiclePosition? anchor}) {
    if (_disposed || geometry.length < 2) {
      _routeDriven = false;
      _routePoints = null;
      _routeCumulativeM = null;
      _routeProgressM = null;
      _routeCorrectionM = 0;
      return;
    }
    _routePoints = [
      for (final p in geometry) (lat: p.latitude, lng: p.longitude),
    ];
    _routeCumulativeM = _buildRouteCumulative(_routePoints!);
    _routeDriven = true;
    _routeEndReachedAt = null;

    final anchorLat = anchor?.lat ?? _lat;
    final anchorLng = anchor?.lng ?? _lng;
    if (anchorLat != null && anchorLng != null) {
      final nearest = _nearestRouteProgressNearStart(
            anchorLat,
            anchorLng,
            _routePoints!,
            _routeCumulativeM!,
          ) ??
          _nearestRouteProgress(
            anchorLat,
            anchorLng,
            _routePoints!,
            _routeCumulativeM!,
          );
      if (nearest != null) {
        _routeProgressM = nearest;
        final sample = _sampleRoute(_routePoints!, _routeCumulativeM!, nearest);
        if (sample != null) {
          _targetHeadingDeg = sample.$3;
          if (_headingDeg.isNaN || !_headingDeg.isFinite) {
            _headingDeg = sample.$3;
          }
        }
      } else {
        _routeProgressM = 0;
      }
    } else {
      _routeProgressM = 0;
    }
    _correctionEastM = 0;
    _correctionNorthM = 0;
    _correctionIsEstimated = false;
    _routeCorrectionM = 0;
    _lastTickerElapsed = null;
    _startTicker();
  }

  void adoptGpsAnchor(VehiclePosition pos) {
    if (_disposed || !pos.lat.isFinite || !pos.lng.isFinite) return;
    _routeDriven = false;
    _routeEndReachedAt = null;
    _routePoints = null;
    _routeCumulativeM = null;
    _routeProgressM = null;
    _routeCorrectionM = 0;
    _roadLocked = false;

    _targetSpeedKmh = _sanitizeSpeed(pos.speedKmh);
    _accuracyM = _safeAccuracy(pos.accuracyM);
    if (_validHeading(pos.headingDeg)) {
      _targetHeadingDeg = pos.headingDeg;
    }
    _lastFixAt = DateTime.now();
    _lastTick = DateTime.now();

    if (_lat == null || _lng == null) {
      _lat = pos.lat;
      _lng = pos.lng;
      if (_validHeading(pos.headingDeg)) _headingDeg = pos.headingDeg;
      _correctionEastM = 0;
      _correctionNorthM = 0;
      _correctionIsEstimated = false;
    } else {
      final eastNorth = _toLocalMeters(_lat!, _lng!, pos.lat, pos.lng);
      var east = eastNorth.$1;
      var north = eastNorth.$2;
      const maxDriftM = 45.0;
      final magnitude = math.sqrt(east * east + north * north);
      if (magnitude > maxDriftM) {
        final scale = maxDriftM / magnitude;
        east *= scale;
        north *= scale;
      }
      _correctionEastM = east;
      _correctionNorthM = north;
      _correctionIsEstimated = pos.isEstimated;
    }

    _lastTickerElapsed = null;
    _startTicker();
    _emit(VehiclePosition(
      lat: _lat!,
      lng: _lng!,
      headingDeg: _headingDeg,
      speedKmh: _renderedSpeedKmh,
      accuracyM: _accuracyM,
      isEstimated: pos.isEstimated,
    ));
  }

  void resetToFreeDrive(VehiclePosition pos) {
    if (_disposed || !pos.lat.isFinite || !pos.lng.isFinite) return;

    _routeDriven = false;
    _routeEndReachedAt = null;
    _routePoints = null;
    _routeCumulativeM = null;
    _routeProgressM = null;
    _routeCorrectionM = 0;
    _correctionEastM = 0;
    _correctionNorthM = 0;
    _correctionIsEstimated = false;
    _roadLocked = false;

    final accuracy = _safeAccuracy(pos.accuracyM);
    final snapped = RoadSnapper.instance.snap(
      pos.lat,
      pos.lng,
      headingDeg: pos.headingDeg,
      speedKmh: pos.speedKmh,
      accuracyM: accuracy,
      referenceHeadingDeg: _validHeading(pos.headingDeg)
          ? pos.headingDeg
          : _headingDeg,
    );

    final lat = snapped?.lat ?? pos.lat;
    final lng = snapped?.lng ?? pos.lng;
    final heading = snapped?.bearingDeg ??
        (_validHeading(pos.headingDeg) ? pos.headingDeg : _headingDeg);

    _lat = lat;
    _lng = lng;
    _headingDeg = heading;
    _targetHeadingDeg = heading;
    _targetSpeedKmh = _sanitizeSpeed(pos.speedKmh);
    _renderedSpeedKmh = math.min(_renderedSpeedKmh, _targetSpeedKmh);
    _accuracyM = accuracy;
    _roadLocked = snapped != null;
    _lastFixAt = DateTime.now();
    _lastTick = DateTime.now();
    _lastTickerElapsed = null;

    _startTicker();
    _emit(VehiclePosition(
      lat: lat,
      lng: lng,
      headingDeg: heading,
      speedKmh: _renderedSpeedKmh,
      accuracyM: accuracy,
      isEstimated: pos.isEstimated,
    ));
  }

  void clearRoute() {
    _routeDriven = false;
    _routeEndReachedAt = null;
    _routePoints = null;
    _routeCumulativeM = null;
    _routeProgressM = null;
    _routeCorrectionM = 0;
    _correctionEastM = 0;
    _correctionNorthM = 0;
  }

  void onRawFix(VehiclePosition pos) {
    if (_disposed) return;
    if (!pos.accuracyM.isFinite ||
        pos.accuracyM <= 0 ||
        pos.accuracyM > (pos.isEstimated ? 100.0 : 120.0)) {
      return;
    }
    final now = DateTime.now();

    final lat = pos.lat;
    final lng = pos.lng;
    if (!lat.isFinite || !lng.isFinite) return;

    if (_lat == null || _lng == null) {
      _lat = lat;
      _lng = lng;
      _headingDeg = _validHeading(pos.headingDeg) ? pos.headingDeg : 0;
      _targetHeadingDeg = _headingDeg;
      _targetSpeedKmh = _sanitizeSpeed(pos.speedKmh);
      _renderedSpeedKmh = 0;
      _accuracyM = _safeAccuracy(pos.accuracyM);
      _lastFixAt = now;
      _lastTick = now;
      _startTicker();
      return;
    }

    final endedAt = _routeEndReachedAt;
    if (_routeDriven &&
        endedAt != null &&
        now.difference(endedAt) > const Duration(seconds: 4) &&
        !pos.isEstimated &&
        pos.accuracyM <= 50.0 &&
        _distanceM(_lat!, _lng!, pos.lat, pos.lng) > 40.0) {
      adoptGpsAnchor(pos);
    }

    _targetSpeedKmh = _sanitizeSpeed(pos.speedKmh);
    _accuracyM = _safeAccuracy(pos.accuracyM);

    var fixLat = lat;
    var fixLng = lng;
    var roadHeading = false;
    if (!_routeDriven) {
      final snapped = RoadSnapper.instance.snap(
        lat,
        lng,
        headingDeg: pos.headingDeg,
        speedKmh: pos.speedKmh,
        accuracyM: pos.accuracyM,
        referenceHeadingDeg: _headingDeg,
      );
      _roadLocked = snapped != null;
      if (snapped != null) {
        fixLat = snapped.lat;
        fixLng = snapped.lng;
        _targetHeadingDeg = snapped.bearingDeg;
        roadHeading = true;
      }
    } else {
      _roadLocked = false;
    }
    if (!roadHeading && _validHeading(pos.headingDeg) && pos.speedKmh >= 6.0) {
      _targetHeadingDeg = pos.headingDeg;
    }

    if (_routeDriven &&
        _routePoints != null &&
        _routeCumulativeM != null &&
        _routeProgressM != null &&
        !pos.isEstimated &&
        pos.accuracyM <= 35.0) {
      final projected = _nearestRouteProgressNear(
        pos.lat,
        pos.lng,
        _routePoints!,
        _routeCumulativeM!,
        _routeProgressM!,
      );
      if (projected == null) {
        _accuracyM = math.max(_accuracyM, pos.accuracyM);
        _routeCorrectionM = 0;
      } else {
        final errorM = projected - _routeProgressM!;
        if (errorM.abs() <= _ignoreProgressErrorM) {
          _routeCorrectionM *= 0.72;
        } else if (errorM > 0) {
          _routeCorrectionM = (errorM * _progressCorrectionGain)
              .clamp(0.0, _maxForwardCorrectionMps);
        } else {
          _routeCorrectionM =
              (errorM * _progressCorrectionGain).clamp(-_maxBackwardHoldM, 0.0);
        }
        if (errorM > _hardForwardErrorM) {
          _routeCorrectionM = _maxForwardCorrectionMps;
        }
      }
    }

    if (!_routeDriven) {
      final eastNorth = _toLocalMeters(_lat!, _lng!, fixLat, fixLng);
      var east = eastNorth.$1;
      var north = eastNorth.$2;
      final error = math.sqrt(east * east + north * north);
      if (error < 0.75) {
        east = 0;
        north = 0;
      }
      final cap = _roadLocked
          ? _maxCorrectionPerFixM * 3.0
          : (pos.isEstimated
              ? _maxCorrectionPerFixM * 0.5
              : _maxCorrectionPerFixM);
      final scale = error > cap && error > 0 ? cap / error : 1.0;
      final newEast = east * scale;
      final newNorth = north * scale;
      final blend = pos.isEstimated ? 0.20 : 0.35;
      _correctionEastM = _correctionEastM * (1 - blend) + newEast * blend;
      _correctionNorthM = _correctionNorthM * (1 - blend) + newNorth * blend;
      _correctionIsEstimated = pos.isEstimated;
    } else {
      _correctionEastM = 0;
      _correctionNorthM = 0;
    }
    _lastFixAt = now;
    _startTicker();
  }

  void _startTicker() {
    final ticker = _ticker ??= Ticker((elapsed) => _tick(elapsed));
    if (!ticker.isActive) {
      _lastTickerElapsed = null;
      ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    if (_disposed || _lat == null || _lng == null) return;
    final now = DateTime.now();
    final previousElapsed = _lastTickerElapsed ?? elapsed;
    final dt =
        ((elapsed - previousElapsed).inMicroseconds / 1e6).clamp(0.001, 0.050);
    _lastTickerElapsed = elapsed;

    final speedDelta = _targetSpeedKmh - _renderedSpeedKmh;
    final maxSpeedStep =
        (speedDelta >= 0 ? _maxAccelerationKmhPerSec : _maxBrakingKmhPerSec) *
            dt;
    if (speedDelta.abs() <= maxSpeedStep) {
      _renderedSpeedKmh = _targetSpeedKmh;
    } else {
      _renderedSpeedKmh += speedDelta.sign * maxSpeedStep;
    }

    if (_routeDriven &&
        _routePoints != null &&
        _routeCumulativeM != null &&
        _routeProgressM != null) {
      final sample =
          _sampleRoute(_routePoints!, _routeCumulativeM!, _routeProgressM!);
      if (sample != null) _targetHeadingDeg = sample.$3;
    }

    final headingDiff = _shortAngle(_targetHeadingDeg - _headingDeg);
    final maxHeadingStep = (45.0 + _renderedSpeedKmh * 1.2) * dt;
    if (headingDiff.abs() <= maxHeadingStep) {
      _headingDeg = _targetHeadingDeg;
    } else {
      _headingDeg = (_headingDeg + headingDiff.sign * maxHeadingStep) % 360;
      if (_headingDeg < 0) _headingDeg += 360;
    }

    final distanceM = (_renderedSpeedKmh / 3.6) * dt;
    if (_routeDriven &&
        _routePoints != null &&
        _routeCumulativeM != null &&
        _routeProgressM != null) {
      final total = _routeCumulativeM!.last;
      final correctedDistance = math.max(
        0.0,
        distanceM + _routeCorrectionM * dt,
      );
      _routeProgressM = math.min(total, _routeProgressM! + correctedDistance);
      if (_routeProgressM! >= total - 0.5) {
        _routeEndReachedAt ??= now;
      } else {
        _routeEndReachedAt = null;
      }
      _routeCorrectionM *= math.pow(0.42, dt).toDouble();

      final sample = _sampleRoute(
        _routePoints!,
        _routeCumulativeM!,
        _routeProgressM!,
      );
      if (sample != null) {
        _lat = sample.$1;
        _lng = sample.$2;
        _targetHeadingDeg = sample.$3;
      }
    } else {
      final move = _offsetFromHeading(_lat!, _lng!, _headingDeg, distanceM);
      _lat = move.$1;
      _lng = move.$2;

      final correctionSpeed = (_correctionIsEstimated
          ? _estimatedCorrectionMps
          : _realCorrectionMps);
      final correctionStep = correctionSpeed * dt;
      final correctionMagnitude = math.sqrt(
        _correctionEastM * _correctionEastM +
            _correctionNorthM * _correctionNorthM,
      );
      if (correctionMagnitude > 0.001) {
        final amount = math.min(correctionStep, correctionMagnitude);
        final ratio = amount / correctionMagnitude;
        final corrected = _offsetFromMeters(
          _lat!,
          _lng!,
          _correctionEastM * ratio,
          _correctionNorthM * ratio,
        );
        _lat = corrected.$1;
        _lng = corrected.$2;
        _correctionEastM -= _correctionEastM * ratio;
        _correctionNorthM -= _correctionNorthM * ratio;
      }

      if (_roadLocked) {
        final f = RoadSnapper.instance.follow(
          _lat!,
          _lng!,
          referenceHeadingDeg: _headingDeg,
        );
        if (f == null) {
          _roadLocked = false;
        } else {
          final off = _toLocalMeters(_lat!, _lng!, f.lat, f.lng);
          final dist = math.sqrt(off.$1 * off.$1 + off.$2 * off.$2);
          final step = _roadPullMps * dt;
          if (dist <= step || dist < 0.05) {
            _lat = f.lat;
            _lng = f.lng;
          } else {
            final r = step / dist;
            final moved = _offsetFromMeters(_lat!, _lng!, off.$1 * r, off.$2 * r);
            _lat = moved.$1;
            _lng = moved.$2;
          }
          if (_renderedSpeedKmh >= 2.0 || _targetSpeedKmh >= 2.0) {
            _targetHeadingDeg = f.bearingDeg;
          }
        }
      }
    }

    final gap = _lastFixAt == null
        ? 0.0
        : now.difference(_lastFixAt!).inMilliseconds / 1000.0;
    if (gap > 1.2) {
      final coastTarget = math.max(0.0, _targetSpeedKmh - (gap - 1.2) * 10.0);
      if (_targetSpeedKmh > coastTarget) _targetSpeedKmh = coastTarget;
    }

    _emit(VehiclePosition(
      lat: _lat!,
      lng: _lng!,
      headingDeg: _headingDeg,
      speedKmh: _renderedSpeedKmh.clamp(0.0, _maxSpeedKmh).toDouble(),
      accuracyM: _accuracyM,
      isEstimated: true,
    ));

    final settled = !_routeDriven &&
        _renderedSpeedKmh < 0.05 &&
        _targetSpeedKmh < 0.05 &&
        _correctionEastM.abs() < 0.01 &&
        _correctionNorthM.abs() < 0.01 &&
        headingDiff.abs() < 0.5;
    if (settled) _ticker?.stop();
  }

  List<double> _buildRouteCumulative(List<({double lat, double lng})> points) {
    final cumulative = <double>[0];
    for (var i = 1; i < points.length; i++) {
      cumulative.add(cumulative.last +
          _distanceM(
            points[i - 1].lat,
            points[i - 1].lng,
            points[i].lat,
            points[i].lng,
          ));
    }
    return cumulative;
  }

  double? _nearestRouteProgress(
    double lat,
    double lng,
    List<({double lat, double lng})> points,
    List<double> cumulative,
  ) {
    var best = double.infinity;
    double? progress;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final latRad = ((a.lat + b.lat) * 0.5) * math.pi / 180.0;
      final mx = 111320.0 * math.cos(latRad);
      final my = 110540.0;
      final ax = a.lng * mx, ay = a.lat * my;
      final bx = b.lng * mx, by = b.lat * my;
      final px = lng * mx, py = lat * my;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 <= 1e-6 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
      final clamped = t.clamp(0.0, 1.0).toDouble();
      final qx = ax + dx * clamped, qy = ay + dy * clamped;
      final d = math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
      if (d < best) {
        best = d;
        progress = cumulative[i] + math.sqrt(len2) * clamped;
      }
    }
    return progress;
  }

  double? _nearestRouteProgressNearStart(
    double lat,
    double lng,
    List<({double lat, double lng})> points,
    List<double> cumulative,
  ) {
    if (points.length < 2) return null;
    const startWindowM = 1000.0;
    final hi = math.min(cumulative.last, startWindowM);
    final latRad = lat * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    var best = double.infinity;
    double? progress;
    for (var i = 0; i < points.length - 1; i++) {
      if (cumulative[i] > hi) break;
      final a = points[i], b = points[i + 1];
      final ax = a.lng * mx, ay = a.lat * my;
      final bx = b.lng * mx, by = b.lat * my;
      final px = lng * mx, py = lat * my;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      if (len2 <= 1e-6) continue;
      final t =
          (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0).toDouble();
      final qx = ax + dx * t, qy = ay + dy * t;
      final d = math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
      final candidate = cumulative[i] + math.sqrt(len2) * t;
      if (candidate > hi + 1.0) continue;
      if (d < best) {
        best = d;
        progress = candidate;
      }
    }
    return best <= 40.0 ? progress : null;
  }

  double? _nearestRouteProgressNear(
    double lat,
    double lng,
    List<({double lat, double lng})> points,
    List<double> cumulative,
    double currentProgress,
  ) {
    if (points.length < 2) return null;
    const backWindowM = 35.0;
    const aheadWindowM = 500.0;
    final lo = math.max(0.0, currentProgress - backWindowM);
    final hi = math.min(cumulative.last, currentProgress + aheadWindowM);
    var start = 0;
    while (start < cumulative.length - 2 && cumulative[start + 1] < lo) {
      start++;
    }
    var end = start;
    while (end < points.length - 2 && cumulative[end] < hi) {
      end++;
    }

    final latRad = lat * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    var bestDistance = double.infinity;
    double? bestProgress;
    for (var i = start; i <= end; i++) {
      final a = points[i];
      final b = points[i + 1];
      final ax = a.lng * mx, ay = a.lat * my;
      final bx = b.lng * mx, by = b.lat * my;
      final px = lng * mx, py = lat * my;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      if (len2 <= 1e-6) continue;
      final t =
          (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0).toDouble();
      final qx = ax + dx * t, qy = ay + dy * t;
      final ex = px - qx, ey = py - qy;
      final distance = math.sqrt(ex * ex + ey * ey);
      final progress = cumulative[i] + math.sqrt(len2) * t;
      if (progress < lo - 1.0 || progress > hi + 1.0) continue;
      if (distance < bestDistance) {
        bestDistance = distance;
        bestProgress = progress;
      }
    }
    return bestDistance <= 35.0 ? bestProgress : null;
  }

  (double, double, double)? _sampleRoute(
    List<({double lat, double lng})> points,
    List<double> cumulative,
    double progress,
  ) {
    if (points.length < 2) return null;
    final target = progress.clamp(0.0, cumulative.last).toDouble();
    var i = 0;
    while (i < cumulative.length - 2 && cumulative[i + 1] < target) i++;
    final a = points[i], b = points[i + 1];
    final len = cumulative[i + 1] - cumulative[i];
    final t =
        len <= 0.001 ? 0.0 : ((target - cumulative[i]) / len).clamp(0.0, 1.0);
    final lat = a.lat + (b.lat - a.lat) * t;
    final lng = a.lng + (b.lng - a.lng) * t;

    final lookBack = math.max(0.0, target - 2.5);
    final lookAhead = math.min(cumulative.last, target + 7.0);
    final back =
        _pointAtProgress(points, cumulative, lookBack) ?? (lat: lat, lng: lng);
    final ahead = _pointAtProgress(points, cumulative, lookAhead) ??
        (lat: b.lat, lng: b.lng);
    final heading = _bearingBetween(back.lat, back.lng, ahead.lat, ahead.lng);
    return (lat, lng, heading);
  }

  ({double lat, double lng})? _pointAtProgress(
    List<({double lat, double lng})> points,
    List<double> cumulative,
    double progress,
  ) {
    if (points.isEmpty || cumulative.isEmpty) return null;
    final target = progress.clamp(0.0, cumulative.last).toDouble();
    var i = 0;
    while (i < cumulative.length - 2 && cumulative[i + 1] < target) i++;
    final a = points[i];
    final b = points[i + 1];
    final len = cumulative[i + 1] - cumulative[i];
    final t = len <= 0.001
        ? 0.0
        : ((target - cumulative[i]) / len).clamp(0.0, 1.0).toDouble();
    return (
      lat: a.lat + (b.lat - a.lat) * t,
      lng: a.lng + (b.lng - a.lng) * t,
    );
  }

  double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final y = (lng2 - lng1) * math.cos((lat1 + lat2) * math.pi / 360.0);
    final x = lat2 - lat1;
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  double _distanceM(double lat1, double lng1, double lat2, double lng2) {
    final latRad = ((lat1 + lat2) * 0.5) * math.pi / 180.0;
    final mx = 111320.0 * math.cos(latRad);
    const my = 110540.0;
    final dx = (lng2 - lng1) * mx;
    final dy = (lat2 - lat1) * my;
    return math.sqrt(dx * dx + dy * dy);
  }

  (double, double) _toLocalMeters(
      double fromLat, double fromLng, double toLat, double toLng) {
    final cosLat = math.cos(fromLat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final east = (toLng - fromLng) * 111320.0 * cosLat;
    final north = (toLat - fromLat) * 111320.0;
    return (east, north);
  }

  (double, double) _offsetFromHeading(
      double lat, double lng, double headingDeg, double meters) {
    final rad = headingDeg * math.pi / 180.0;
    return _offsetFromMeters(
        lat, lng, math.sin(rad) * meters, math.cos(rad) * meters);
  }

  (double, double) _offsetFromMeters(
      double lat, double lng, double eastM, double northM) {
    final dLat = northM / 111320.0;
    final cosLat = math.cos(lat * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final dLng = eastM / (111320.0 * cosLat);
    return (lat + dLat, lng + dLng);
  }

  double _sanitizeSpeed(double value) {
    if (!value.isFinite) return 0;
    return value.clamp(0.0, _maxSpeedKmh).toDouble();
  }

  double _safeAccuracy(double value) {
    if (!value.isFinite || value <= 0) return 50;
    return value.clamp(1.0, 500.0).toDouble();
  }

  bool _validHeading(double value) =>
      value.isFinite && value >= 0 && value < 360;

  double _shortAngle(double value) => (value + 540) % 360 - 180;

  void _emit(VehiclePosition value) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _controller.close();
  }
}

final animatedVehiclePositionProvider = StreamProvider<VehiclePosition>((ref) {
  final animator = VehiclePositionAnimator();
  ref.onDispose(animator.dispose);

  final sub = ref.watch(vehiclePositionProvider.stream).listen(
        animator.onRawFix,
        onError: (_, __) {},
      );
  ref.onDispose(sub.cancel);

  return animator.stream;
});
