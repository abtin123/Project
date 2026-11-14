import 'dart:math' as math;

import 'gps_fix.dart';
import 'gps_math.dart';

class KalmanEstimate {
  const KalmanEstimate({
    required this.lat,
    required this.lng,
    required this.speedMs,
    required this.headingDeg,
    required this.accuracyM,
    required this.stationary,
    required this.estimated,
  });

  final double lat;
  final double lng;
  final double speedMs;
  final double headingDeg;

  /// 68 % horizontal radius derived from the filter covariance.
  final double accuracyM;
  final bool stationary;

  /// True when the last accepted measurement was not a fresh GNSS fix.
  final bool estimated;
}

/// Joint 4-state Kalman filter [east, north, vEast, vNorth] in a local tangent
/// plane, with full covariance, Joseph-form updates, robust (Mahalanobis)
/// gating, innovation-adaptive process noise and zero-velocity updates.
class GpsKalmanFilter {
  GpsKalmanFilter();

  static const double _chi2Soft = 9.21; // 99 % for 2 dof
  static const double _chi2Hard = 40.0;

  bool navigationMode = false;

  double _lat0 = 0, _lng0 = 0, _mLat = 111000, _mLng = 111000;
  final List<double> _x = List<double>.filled(4, 0);
  final List<double> _p = List<double>.filled(16, 0);
  bool _init = false;
  int _lastMs = 0;
  double _qScale = 1.0;
  double _nis = 1.0;
  int _gnssRejects = 0;
  int _lowSpeedCount = 0;
  bool _stationary = false;
  double _anchorE = 0, _anchorN = 0;
  int _anchorMoves = 0;
  double _heading = 0;
  bool _estimated = false;

  // Last GNSS Doppler speed (independent of position quality). Used to pin the
  // velocity state and to cap the speed that is shown to the user.
  double? _dopplerMs;
  int _dopplerAtMs = 0;

  bool get initialized => _init;
  bool get stationary => _stationary;

  void reset() {
    _init = false;
    _qScale = 1.0;
    _nis = 1.0;
    _gnssRejects = 0;
    _lowSpeedCount = 0;
    _stationary = false;
    _anchorMoves = 0;
    _dopplerMs = null;
  }

  void _setOrigin(double lat, double lng) {
    _lat0 = lat;
    _lng0 = lng;
    _mLat = mPerDegLat(lat);
    _mLng = mPerDegLng(lat);
  }

  double _e(double lng) => (lng - _lng0) * _mLng;
  double _n(double lat) => (lat - _lat0) * _mLat;

  KalmanEstimate? get estimate {
    if (!_init) return null;
    var speed = math.sqrt(_x[2] * _x[2] + _x[3] * _x[3]);
    // A fresh GNSS Doppler reading is far more reliable than the velocity the
    // filter infers from jittery positions (phantom speed while standing still
    // with poor accuracy). Never show much more than Doppler says.
    final d = _dopplerMs;
    if (d != null && (_lastMs - _dopplerAtMs) <= 3000) {
      speed = math.min(speed, d * 1.2 + 0.4);
    }
    final sig = math.sqrt(math.max(_p[0] + _p[5], 0.01) / 2);
    return KalmanEstimate(
      lat: _lat0 + _x[1] / _mLat,
      lng: _lng0 + _x[0] / _mLng,
      speedMs: _stationary || speed < 0.5 ? 0.0 : speed,
      headingDeg: _heading,
      accuracyM: math.max(1.0, 1.51 * sig),
      stationary: _stationary,
      estimated: _estimated,
    );
  }

  void _initAt(RawFix f) {
    _setOrigin(f.lat, f.lng);
    final acc = math.max(f.accuracyM, 1.0);
    final sig = _posSigma(f);
    _x[0] = 0;
    _x[1] = 0;
    final s = f.speedMs;
    final b = f.bearingDeg;
    if (s != null && b != null && s >= 1.0 && f.isGnssQuality) {
      _x[2] = s * math.sin(b * kDegToRad);
      _x[3] = s * math.cos(b * kDegToRad);
      _heading = b;
    } else {
      _x[2] = 0;
      _x[3] = 0;
      if (b != null) _heading = b;
    }
    for (var i = 0; i < 16; i++) {
      _p[i] = 0;
    }
    _p[0] = sig * sig;
    _p[5] = sig * sig;
    final v0 = (s != null && f.isGnssQuality) ? 2.5 : 12.0;
    _p[10] = v0 * v0;
    _p[15] = v0 * v0;
    _init = true;
    _lastMs = f.elapsedMs;
    _dopplerMs = (s != null && f.isGnssQuality) ? s : null;
    _dopplerAtMs = f.elapsedMs;
    _qScale = 1.0;
    _nis = 1.0;
    _gnssRejects = 0;
    _lowSpeedCount = 0;
    _stationary = false;
    _anchorE = 0;
    _anchorN = 0;
    _anchorMoves = 0;
    _estimated = !f.isGnssQuality || acc > 60;
  }

  double _posSigma(RawFix f) {
    final acc = f.accuracyM <= 0 ? 50.0 : f.accuracyM;
    if (f.source == FixSource.network) {
      return math.max(15.0, acc * 0.7 * 1.3);
    }
    return math.max(1.5, acc * 0.7);
  }

  /// Feed one fix. Returns false if it was rejected as an outlier / stale.
  bool update(RawFix f) {
    if (!_init) {
      _initAt(f);
      return true;
    }
    final dtMs = f.elapsedMs - _lastMs;
    if (dtMs < 0) return false;
    final dt = dtMs / 1000.0;
    if (dt > 25.0) {
      _initAt(f);
      return true;
    }

    // Rebase local origin so linearisation stays valid on long trips.
    if (_x[0].abs() > 15000 || _x[1].abs() > 15000) {
      final nlat = _lat0 + _x[1] / _mLat;
      final nlng = _lng0 + _x[0] / _mLng;
      _anchorE -= _x[0];
      _anchorN -= _x[1];
      _setOrigin(nlat, nlng);
      _x[0] = 0;
      _x[1] = 0;
    }

    _predict(dt);
    _lastMs = f.elapsedMs;

    final ze = _e(f.lng);
    final zn = _n(f.lat);
    var sig = _posSigma(f);

    // ---- stationary (zero-velocity) detection -------------------------------
    final s = f.speedMs;
    if (f.isGnssQuality && s != null) {
      _dopplerMs = s;
      _dopplerAtMs = f.elapsedMs;
      if (s < 0.35 && f.accuracyM < 100) {
        _lowSpeedCount++;
      } else if (s >= 1.0) {
        _lowSpeedCount = 0;
        _anchorMoves = 0;
        _stationary = false;
      }
    }
    if (!_stationary && _lowSpeedCount >= 3) {
      _stationary = true;
      _anchorE = _x[0];
      _anchorN = _x[1];
      _anchorMoves = 0;
    }
    if (_stationary) {
      final off = math.sqrt(math.pow(ze - _anchorE, 2) + math.pow(zn - _anchorN, 2));
      if (off > math.max(12.0, 3 * f.accuracyM)) {
        _anchorMoves++;
        if (_anchorMoves >= 2) {
          _stationary = false;
          _lowSpeedCount = 0;
        }
      } else {
        _anchorMoves = 0;
      }
    }
    if (_stationary) {
      // Freeze: position barely follows noisy fixes, velocity pinned to zero.
      sig *= 5.0;
    }

    // ---- position update ----------------------------------------------------
    final accepted = _updateBlock(0, ze, zn, sig * sig, 0, sig * sig, gate: true);
    if (!accepted) {
      if (f.isGnssQuality) {
        _gnssRejects++;
        if (_gnssRejects >= 4) {
          _initAt(f);
          return true;
        }
      }
      return false;
    }
    _gnssRejects = 0;
    _estimated = !f.isGnssQuality || f.accuracyM > 60;

    // ---- velocity update ----------------------------------------------------
    if (_stationary) {
      _updateBlock(2, 0, 0, 0.05 * 0.05, 0, 0.05 * 0.05, gate: false);
    } else if (f.isGnssQuality && s != null && s < 0.5) {
      // GNSS says (almost) not moving: pin the velocity instead of letting it
      // wander with position noise. Previously a reported speed below 0.5 m/s
      // was ignored here, so with accuracy worse than the stationary gate the
      // filter invented speeds of 10-20 km/h while standing still.
      final sigV = (f.speedAccMs != null && f.speedAccMs! > 0)
          ? math.max(0.2, f.speedAccMs!)
          : 0.3;
      _updateBlock(2, 0, 0, sigV * sigV, 0, sigV * sigV, gate: false);
    } else if (f.isGnssQuality && s != null && s >= 0.5) {
      final b = f.bearingDeg;
      if (b != null && s >= 1.0) {
        final th = b * kDegToRad;
        final ux = math.sin(th), uy = math.cos(th);
        final sigAlong = (f.speedAccMs != null && f.speedAccMs! > 0)
            ? math.max(0.15, f.speedAccMs!)
            : math.max(0.25, 0.04 * s + 0.15);
        double sigTh;
        if (f.bearingAccDeg != null && f.bearingAccDeg! > 0) {
          sigTh = math.max(2.0, f.bearingAccDeg!) * kDegToRad;
        } else {
          sigTh = math.max(2.0 * kDegToRad, math.atan(0.6 / s));
        }
        final sigCross = s * sigTh;
        final a2 = sigAlong * sigAlong, c2 = sigCross * sigCross;
        // R = a² u uᵀ + c² w wᵀ with w = (uy, -ux)
        final rxx = a2 * ux * ux + c2 * uy * uy;
        final ryy = a2 * uy * uy + c2 * ux * ux;
        final rxy = a2 * ux * uy - c2 * ux * uy;
        _updateBlock(2, s * ux, s * uy, rxx, rxy, ryy, gate: true);
      }
    }

    // ---- heading ------------------------------------------------------------
    final sp = math.sqrt(_x[2] * _x[2] + _x[3] * _x[3]);
    if (!_stationary && sp >= 1.5) {
      _heading = normDeg(math.atan2(_x[2], _x[3]) * kRadToDeg);
    }
    return true;
  }

  void _predict(double dt) {
    if (dt <= 0) return;
    final sa = (_stationary ? 0.08 : (navigationMode ? 1.3 : 2.0)) * math.sqrt(_qScale);
    final q = sa * sa;
    final f = <double>[
      1, 0, dt, 0, //
      0, 1, 0, dt,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ];
    // x = F x
    final nx = [
      _x[0] + dt * _x[2],
      _x[1] + dt * _x[3],
      _x[2],
      _x[3],
    ];
    for (var i = 0; i < 4; i++) {
      _x[i] = nx[i];
    }
    // P = F P Fᵀ + Q
    final fp = _mul(f, _p);
    final fpft = _mulT(fp, f);
    final dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt;
    fpft[0] += q * dt4 / 4;
    fpft[5] += q * dt4 / 4;
    fpft[10] += q * dt2;
    fpft[15] += q * dt2;
    fpft[2] += q * dt3 / 2;
    fpft[8] += q * dt3 / 2;
    fpft[7] += q * dt3 / 2;
    fpft[13] += q * dt3 / 2;
    for (var i = 0; i < 16; i++) {
      _p[i] = fpft[i];
    }
    if (_stationary) {
      _x[2] = 0;
      _x[3] = 0;
    }
  }

  /// Sequential 2-D update on state indices [i, i+1].
  bool _updateBlock(
    int i,
    double z0,
    double z1,
    double rxx,
    double rxy,
    double ryy, {
    required bool gate,
  }) {
    final y0 = z0 - _x[i];
    final y1 = z1 - _x[i + 1];
    var sxx = _p[i * 4 + i] + rxx;
    var sxy = _p[i * 4 + i + 1] + rxy;
    var syy = _p[(i + 1) * 4 + i + 1] + ryy;
    var det = sxx * syy - sxy * sxy;
    if (det.abs() < 1e-12) return false;
    var d2 = (y0 * (syy * y0 - sxy * y1) + y1 * (-sxy * y0 + sxx * y1)) / det;
    var rScale = 1.0;
    if (gate) {
      if (d2 > _chi2Hard) return false;
      if (d2 > _chi2Soft) rScale = d2 / _chi2Soft;
    }
    if (rScale != 1.0) {
      rxx *= rScale;
      rxy *= rScale;
      ryy *= rScale;
      sxx = _p[i * 4 + i] + rxx;
      sxy = _p[i * 4 + i + 1] + rxy;
      syy = _p[(i + 1) * 4 + i + 1] + ryy;
      det = sxx * syy - sxy * sxy;
      if (det.abs() < 1e-12) return false;
    }
    final i00 = syy / det, i01 = -sxy / det, i11 = sxx / det;
    // K = P Hᵀ S⁻¹  (4x2)
    final k = List<double>.filled(8, 0);
    for (var r = 0; r < 4; r++) {
      final p0 = _p[r * 4 + i];
      final p1 = _p[r * 4 + i + 1];
      k[r * 2] = p0 * i00 + p1 * i01;
      k[r * 2 + 1] = p0 * i01 + p1 * i11;
    }
    for (var r = 0; r < 4; r++) {
      _x[r] += k[r * 2] * y0 + k[r * 2 + 1] * y1;
    }
    // Joseph form: P = (I-KH) P (I-KH)ᵀ + K R Kᵀ
    final a = List<double>.filled(16, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        a[r * 4 + c] = (r == c ? 1.0 : 0.0);
      }
      a[r * 4 + i] -= k[r * 2];
      a[r * 4 + i + 1] -= k[r * 2 + 1];
    }
    final ap = _mul(a, _p);
    final apat = _mulT(ap, a);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        final kr0 = k[r * 2], kr1 = k[r * 2 + 1];
        final kc0 = k[c * 2], kc1 = k[c * 2 + 1];
        apat[r * 4 + c] +=
            kr0 * (rxx * kc0 + rxy * kc1) + kr1 * (rxy * kc0 + ryy * kc1);
      }
    }
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        _p[r * 4 + c] = (apat[r * 4 + c] + apat[c * 4 + r]) / 2;
      }
    }
    if (i == 0) {
      // innovation-adaptive process noise (uses the un-inflated NIS)
      _nis = 0.9 * _nis + 0.1 * (d2 / 2);
      if (_nis > 1.8) {
        _qScale = math.min(_qScale * 1.25, 25.0);
      } else if (_nis < 0.7) {
        _qScale = math.max(_qScale / 1.08, 1.0);
      }
    }
    return true;
  }

  static List<double> _mul(List<double> a, List<double> b) {
    final o = List<double>.filled(16, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[r * 4 + k] * b[k * 4 + c];
        }
        o[r * 4 + c] = s;
      }
    }
    return o;
  }

  /// a * bᵀ
  static List<double> _mulT(List<double> a, List<double> b) {
    final o = List<double>.filled(16, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[r * 4 + k] * b[c * 4 + k];
        }
        o[r * 4 + c] = s;
      }
    }
    return o;
  }
}
