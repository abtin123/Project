import 'dart:math' as math;

class KalmanLocationSample {
  final double latitude;
  final double longitude;
  final double speedMs;
  final double bearingDeg;
  final double accuracyMeters;

  final double speedAccuracyMs;
  final int timestampMs;

  const KalmanLocationSample({
    required this.latitude,
    required this.longitude,
    required this.speedMs,
    required this.bearingDeg,
    required this.accuracyMeters,
    this.speedAccuracyMs = 2.5,
    required this.timestampMs,
  });
}

class JointKalmanFilter2D {
  JointKalmanFilter2D({
    this.processNoiseQ = 2.0,
    this.measurementNoiseMultiplier = 1.0,
  });

  double processNoiseQ;

  double measurementNoiseMultiplier;

  static const double earthRadiusMeters = 6371000.0;

  bool _initialized = false;
  double _refLat = 0;
  double _refLng = 0;
  int _lastTimestampMs = 0;
  double _lastBearingDeg = 0;

  double _x = 0, _y = 0, _vx = 0, _vy = 0;

  final List<List<double>> _p = List.generate(4, (_) => List.filled(4, 0.0));

  double totalJitterReducedMeters = 0;

  void reset() {
    _initialized = false;
    _refLat = 0;
    _refLng = 0;
    _lastTimestampMs = 0;
    _lastBearingDeg = 0;
    _x = _y = _vx = _vy = 0;
    totalJitterReducedMeters = 0;
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        _p[i][j] = (i == j) ? 10.0 : 0.0;
      }
    }
  }

  KalmanLocationSample process(
    KalmanLocationSample raw, {
    bool includeVelocity = true,
    double extraProcessNoise = 0.0,
  }) {
    if (!_initialized) {
      _refLat = raw.latitude;
      _refLng = raw.longitude;
      _x = 0;
      _y = 0;
      final bearingRad = raw.bearingDeg * math.pi / 180.0;
      _vx = raw.speedMs * math.sin(bearingRad);
      _vy = raw.speedMs * math.cos(bearingRad);
      _lastTimestampMs = raw.timestampMs;
      _lastBearingDeg = raw.bearingDeg;
      _initialized = true;

      final acc = math.max(raw.accuracyMeters, 1.0);
      _p[0][0] = acc * acc;
      _p[1][1] = acc * acc;
      _p[2][2] = 2.0;
      _p[3][3] = 2.0;
      return raw;
    }

    final timestampDeltaMs = raw.timestampMs - _lastTimestampMs;
    if (timestampDeltaMs < -250) {
      return _sampleFromState(_lastTimestampMs,
          fallbackBearingDeg: raw.bearingDeg);
    }
    final dt = (timestampDeltaMs / 1000.0).clamp(0.0, 10.0);
    if (dt > 0) {
      _lastTimestampMs = raw.timestampMs;
    }

    _predict(dt, extraProcessNoise: extraProcessNoise);

    final rawX = _lngToMeters(raw.longitude, _refLat, _refLng);
    final rawY = _latToMeters(raw.latitude, _refLat);

    final bearingRad = raw.bearingDeg * math.pi / 180.0;
    final rawVx = raw.speedMs * math.sin(bearingRad);
    final rawVy = raw.speedMs * math.cos(bearingRad);

    final baseAccuracy =
        math.max(raw.accuracyMeters, 1.0) * measurementNoiseMultiplier;
    final rPos = baseAccuracy * baseAccuracy;
    final speedSigma = math.max(
      raw.speedAccuracyMs.isFinite && raw.speedAccuracyMs > 0
          ? raw.speedAccuracyMs
          : 2.5,
      0.75,
    );
    final rVel = includeVelocity ? speedSigma * speedSigma : 1e12;

    final innovX = rawX - _x;
    final innovY = rawY - _y;
    final innovVx = rawVx - _vx;
    final innovVy = rawVy - _vy;

    final positionInnovationM = math.sqrt(innovX * innovX + innovY * innovY);
    final predictedPositionSigmaM = math.sqrt(
      math.max(_p[0][0], 0) + math.max(_p[1][1], 0) + 2 * rPos,
    );
    final positionGateM = math.max(35.0, predictedPositionSigmaM * 4.0);
    final effectiveRPos = _inflateMeasurementNoise(
      rPos,
      innovationMagnitude: positionInnovationM,
      gateMagnitude: positionGateM,
    );

    final velocityInnovationMs =
        math.sqrt(innovVx * innovVx + innovVy * innovVy);
    final velocityGateMs = math.max(8.0, speedSigma * 4.0);
    final effectiveRVel = includeVelocity
        ? _inflateMeasurementNoise(
            rVel,
            innovationMagnitude: velocityInnovationMs,
            gateMagnitude: velocityGateMs,
          )
        : rVel;

    _updateAxisBlock(
      innovPos: innovX,
      innovVel: innovVx,
      rPos: effectiveRPos,
      rVel: effectiveRVel,
      pIndexPos: 0,
      pIndexVel: 2,
      applyState: (dPos, dVel) {
        _x += dPos;
        _vx += dVel;
      },
    );

    _updateAxisBlock(
      innovPos: innovY,
      innovVel: innovVy,
      rPos: effectiveRPos,
      rVel: effectiveRVel,
      pIndexPos: 1,
      pIndexVel: 3,
      applyState: (dPos, dVel) {
        _y += dPos;
        _vy += dVel;
      },
    );

    if (raw.speedMs >= 0.5) _lastBearingDeg = raw.bearingDeg;
    final output = _sampleFromState(
      raw.timestampMs,
      fallbackBearingDeg: raw.bearingDeg,
    );
    final rawDist = math.sqrt(innovX * innovX + innovY * innovY);
    final filterDx = _lngToMeters(output.longitude, _refLat, _refLng) - rawX;
    final filterDy = _latToMeters(output.latitude, _refLat) - rawY;
    final filterDist = math.sqrt(filterDx * filterDx + filterDy * filterDy);
    totalJitterReducedMeters += math.max(0.0, rawDist - filterDist);
    return output;
  }

  KalmanLocationSample processPositionOnly(KalmanLocationSample raw) {
    if (!_initialized) return process(raw, includeVelocity: false);
    final savedVx = _vx;
    final savedVy = _vy;
    process(raw, includeVelocity: false);
    _vx = savedVx;
    _vy = savedVy;
    return _sampleFromState(raw.timestampMs);
  }

  static double _inflateMeasurementNoise(
    double variance, {
    required double innovationMagnitude,
    required double gateMagnitude,
  }) {
    if (!innovationMagnitude.isFinite ||
        !gateMagnitude.isFinite ||
        gateMagnitude <= 0 ||
        innovationMagnitude <= gateMagnitude) {
      return variance;
    }
    final ratio = (innovationMagnitude / gateMagnitude).clamp(1.0, 8.0);
    return variance * ratio * ratio;
  }

  KalmanLocationSample? predictOnly(int timestampMs) {
    if (!_initialized || timestampMs <= _lastTimestampMs) return null;
    final dt = ((timestampMs - _lastTimestampMs) / 1000.0).clamp(0.01, 1.0);
    _lastTimestampMs = timestampMs;
    _predict(dt);
    return _sampleFromState(timestampMs);
  }

  void _predict(double dt, {double extraProcessNoise = 0.0}) {
    _x += _vx * dt;
    _y += _vy * dt;

    final dt2 = dt * dt;
    final dt3 = dt2 * dt;
    final dt4 = dt3 * dt;
    final q = processNoiseQ + math.max(extraProcessNoise, 0.0);

    final q00 = q * dt4 / 4.0;
    final q02 = q * dt3 / 2.0;
    final q22 = q * dt2;

    _p[0][0] += 2 * dt * _p[0][2] + dt2 * _p[2][2] + q00;
    _p[0][2] += dt * _p[2][2] + q02;
    _p[2][0] = _p[0][2];
    _p[2][2] += q22;

    _p[1][1] += 2 * dt * _p[1][3] + dt2 * _p[3][3] + q00;
    _p[1][3] += dt * _p[3][3] + q02;
    _p[3][1] = _p[1][3];
    _p[3][3] += q22;
  }

  KalmanLocationSample _sampleFromState(
    int timestampMs, {
    double? fallbackBearingDeg,
  }) {
    final filteredLat = _metersToLat(_y, _refLat);
    final filteredLng = _metersToLng(_x, _refLat, _refLng);

    var filteredSpeedMs = math.sqrt(_vx * _vx + _vy * _vy);
    var filteredBearing = math.atan2(_vx, _vy) * 180.0 / math.pi;
    if (filteredBearing < 0) filteredBearing += 360;

    final estimatedErr = math.sqrt(_p[0][0] + _p[1][1]);

    return KalmanLocationSample(
      latitude: filteredLat,
      longitude: filteredLng,
      speedMs: filteredSpeedMs < 0.2 ? 0 : filteredSpeedMs,
      bearingDeg: filteredSpeedMs < 0.5
          ? (fallbackBearingDeg ?? _lastBearingDeg)
          : filteredBearing,
      accuracyMeters: math.max(estimatedErr, 1.0),
      timestampMs: timestampMs,
    );
  }

  void _updateAxisBlock({
    required double innovPos,
    required double innovVel,
    required double rPos,
    required double rVel,
    required int pIndexPos,
    required int pIndexVel,
    required void Function(double dPos, double dVel) applyState,
  }) {
    final p00 = _p[pIndexPos][pIndexPos];
    final p01 = _p[pIndexPos][pIndexVel];
    final p10 = _p[pIndexVel][pIndexPos];
    final p11 = _p[pIndexVel][pIndexVel];

    final s00 = p00 + rPos;
    final s01 = p01;
    final s10 = p10;
    final s11 = p11 + rVel;

    final det = s00 * s11 - s01 * s10;
    if (det.abs() < 1e-12) {
      return;
    }
    final invDet = 1.0 / det;
    final sInv00 = s11 * invDet;
    final sInv01 = -s01 * invDet;
    final sInv10 = -s10 * invDet;
    final sInv11 = s00 * invDet;

    final k00 = p00 * sInv00 + p01 * sInv10;
    final k01 = p00 * sInv01 + p01 * sInv11;
    final k10 = p10 * sInv00 + p11 * sInv10;
    final k11 = p10 * sInv01 + p11 * sInv11;

    final dPos = k00 * innovPos + k01 * innovVel;
    final dVel = k10 * innovPos + k11 * innovVel;
    applyState(dPos, dVel);

    final a00 = 1.0 - k00;
    final a01 = -k01;
    final a10 = -k10;
    final a11 = 1.0 - k11;

    final newP00 = a00 * p00 + a01 * p10;
    final newP01 = a00 * p01 + a01 * p11;
    final newP10 = a10 * p00 + a11 * p10;
    final newP11 = a10 * p01 + a11 * p11;

    final symmetricOffDiag = (newP01 + newP10) / 2.0;

    _p[pIndexPos][pIndexPos] = newP00;
    _p[pIndexPos][pIndexVel] = symmetricOffDiag;
    _p[pIndexVel][pIndexPos] = symmetricOffDiag;
    _p[pIndexVel][pIndexVel] = newP11;
  }

  static double _latToMeters(double lat, double refLat) =>
      (lat - refLat) * math.pi / 180.0 * earthRadiusMeters;

  static double _lngToMeters(double lng, double refLat, double refLng) {
    final radLat = refLat * math.pi / 180.0;
    return (lng - refLng) *
        math.pi /
        180.0 *
        earthRadiusMeters *
        math.cos(radLat);
  }

  static double _metersToLat(double metersY, double refLat) =>
      refLat + (metersY / earthRadiusMeters) * 180.0 / math.pi;

  static double _metersToLng(double metersX, double refLat, double refLng) {
    final radLat = refLat * math.pi / 180.0;
    final scale = math.cos(radLat);
    final effectiveScale = scale.abs() < 1e-6 ? 1.0 : scale;
    return refLng +
        (metersX / (earthRadiusMeters * effectiveScale)) * 180.0 / math.pi;
  }
}
