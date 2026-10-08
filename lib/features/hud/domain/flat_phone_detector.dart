import 'dart:math' as math;

/// NOT_FLAT → CANDIDATE → STABLE → HUD_ACTIVE
enum FlatPhoneState { notFlat, candidate, stable, hudActive }

class FlatPhoneConfig {
  const FlatPhoneConfig({
    this.activationTiltDeg = 30,
    this.deactivationTiltDeg = 40,
    this.stableDuration = const Duration(milliseconds: 500),
    this.gyroActivateRadPerSec = 0.5,
    this.gyroDeactivateRadPerSec = 0.90,
    this.gyroDeactivateHold = const Duration(milliseconds: 300),
    this.gravityToleranceActivate = 3.5,
    this.gravityToleranceKeep = 5.0,
    this.accelTauSec = 0.06,
    this.gyroTauSec = 0.04,
    this.maxSampleGap = const Duration(milliseconds: 600),
    this.gyroStaleAfter = const Duration(milliseconds: 500),
  });

  final double activationTiltDeg;
  final double deactivationTiltDeg;
  final Duration stableDuration;

  /// آستانهٔ سرعت زاویه‌ای برای شروع/ادامهٔ CANDIDATE (rad/s).
  final double gyroActivateRadPerSec;

  /// در HUD_ACTIVE لرزش/دست‌انداز تا این حد تحمل می‌شود (rad/s).
  final double gyroDeactivateRadPerSec;
  final Duration gyroDeactivateHold;

  /// |‖a‖ − g| مجاز (m/s²)؛ ضربهٔ قرار دادن/شتاب شدید را رد می‌کند.
  final double gravityToleranceActivate;
  final double gravityToleranceKeep;
  final double accelTauSec;
  final double gyroTauSec;
  final Duration maxSampleGap;
  final Duration gyroStaleAfter;
}

class FlatPhoneSnapshot {
  const FlatPhoneSnapshot({
    required this.state,
    required this.tiltDeg,
    required this.flat,
    required this.faceUp,
    required this.stable,
  });

  static const idle = FlatPhoneSnapshot(
    state: FlatPhoneState.notFlat,
    tiltDeg: 90,
    flat: false,
    faceUp: false,
    stable: false,
  );

  final FlatPhoneState state;

  /// زاویهٔ بین عمود صفحه و «بالا» (۰ = تخت و رو به بالا، ۱۸۰ = رو به پایین).
  final double tiltDeg;
  final bool flat;
  final bool faceUp;
  final bool stable;

  /// تنها شرطی که اجازهٔ تلاش برای باز کردن HUD می‌دهد.
  bool get canAttemptOpenHud => flat && faceUp && stable;

  bool sameFlags(FlatPhoneSnapshot o) =>
      state == o.state &&
      flat == o.flat &&
      faceUp == o.faceUp &&
      stable == o.stable;
}

/// تشخیص «گوشی واقعاً تخت، رو به بالا و پایدار». مستقل از پلتفرم و سنسور
/// (نمونه‌ها از بیرون تزریق می‌شوند)، پس قابل تست است.
///
/// چارچوب Android: شتاب‌سنج در حالت سکون بردار واکنش گرانش را می‌دهد، یعنی
/// **به سمت بالا**. محور Z عمود بر صفحه و به سمت بیرون صفحه است. پس
/// `up = a/‖a‖` و `cosθ = up·n` با `n = (0,0,1)`؛ رو به بالا ⇔ cosθ > 0.
/// علامت Z هاردکد نشده؛ از ضرب داخلی با نرمال صفحه محاسبه می‌شود.
class FlatPhoneDetector {
  FlatPhoneDetector({
    this.config = const FlatPhoneConfig(),
    this.onCanAttemptOpenHud,
  });

  final FlatPhoneConfig config;

  /// دقیقاً یک بار در لحظهٔ ورود به STABLE صدا زده می‌شود؛ تنها Trigger مجاز.
  final void Function()? onCanAttemptOpenHud;

  static const _g = 9.80665;
  static const _screenNormal = [0.0, 0.0, 1.0];

  FlatPhoneSnapshot _snap = FlatPhoneSnapshot.idle;
  FlatPhoneSnapshot get snapshot => _snap;
  FlatPhoneState get state => _snap.state;

  List<double>? _a;
  DateTime? _aAt;
  double _gyro = 0;
  DateTime? _gyroAt;
  double _fallbackRate = 0;
  List<double>? _prevUp;
  DateTime? _candidateSince;
  DateTime? _motionSince;

  void reset() {
    _a = null;
    _aAt = null;
    _prevUp = null;
    _candidateSince = null;
    _motionSince = null;
    _snap = FlatPhoneSnapshot.idle;
  }

  void onGyroscope(double x, double y, double z, DateTime t) {
    final mag = math.sqrt(x * x + y * y + z * z);
    final dt = _gyroAt == null
        ? 0.0
        : t.difference(_gyroAt!).inMicroseconds / 1e6;
    final k = dt <= 0 ? 1.0 : dt / (config.gyroTauSec + dt);
    // نمونهٔ بزرگ فوراً دیده شود (بدون تأخیر فیلتر)؛ فقط افت ملایم است.
    _gyro = mag > _gyro ? mag : _gyro + (mag - _gyro) * k;
    _gyroAt = t;
  }

  void onAccelerometer(double x, double y, double z, DateTime t) {
    if (!(x.isFinite && y.isFinite && z.isFinite)) return;
    final prev = _a;
    final prevAt = _aAt;
    if (prev == null || prevAt == null) {
      _a = [x, y, z];
      _aAt = t;
      return;
    }
    final dt = t.difference(prevAt).inMicroseconds / 1e6;
    if (dt <= 0) return;
    if (t.difference(prevAt) > config.maxSampleGap) {
      _a = [x, y, z];
      _aAt = t;
      _prevUp = null;
      _drop();
      return;
    }
    final k = dt / (config.accelTauSec + dt);
    final f = [
      prev[0] + (x - prev[0]) * k,
      prev[1] + (y - prev[1]) * k,
      prev[2] + (z - prev[2]) * k,
    ];
    _a = f;
    _aAt = t;
    _step(f, dt, t);
  }

  void _drop() {
    _candidateSince = null;
    _motionSince = null;
    _set(FlatPhoneState.notFlat, _snap.tiltDeg, false, false, false);
  }

  void _set(FlatPhoneState s, double tilt, bool flat, bool up, bool stable) {
    _snap = FlatPhoneSnapshot(
        state: s, tiltDeg: tilt, flat: flat, faceUp: up, stable: stable);
  }

  void _step(List<double> f, double dt, DateTime t) {
    final mag = math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    if (mag < 1.0) {
      _drop(); // سقوط آزاد/داده نامعتبر
      return;
    }
    final up = [f[0] / mag, f[1] / mag, f[2] / mag];
    final dot = (up[0] * _screenNormal[0] +
            up[1] * _screenNormal[1] +
            up[2] * _screenNormal[2])
        .clamp(-1.0, 1.0);
    final tilt = math.acos(dot) * 180 / math.pi;
    final faceUp = dot > 0;

    // اگر ژیروسکوپ نیامد، نرخ تغییر بردار گرانش جایگزین می‌شود.
    final pu = _prevUp;
    _prevUp = up;
    if (pu != null) {
      final d = (pu[0] * up[0] + pu[1] * up[1] + pu[2] * up[2]).clamp(-1.0, 1.0);
      _fallbackRate = math.acos(d) / dt;
    }
    final gyroFresh = _gyroAt != null &&
        t.difference(_gyroAt!) <= config.gyroStaleAfter;
    final rate = gyroFresh ? _gyro : _fallbackRate;
    final gravErr = (mag - _g).abs();

    final inSession = _snap.state != FlatPhoneState.notFlat;
    final tiltLimit =
        inSession ? config.deactivationTiltDeg : config.activationTiltDeg;
    final flat = tilt <= tiltLimit; // رو به پایین هرگز FLAT+FACE_UP نیست

    switch (_snap.state) {
      case FlatPhoneState.notFlat:
        final ok = flat &&
            faceUp &&
            rate <= config.gyroActivateRadPerSec &&
            gravErr <= config.gravityToleranceActivate;
        if (ok) {
          _candidateSince = t;
          _set(FlatPhoneState.candidate, tilt, true, true, false);
        } else {
          _set(FlatPhoneState.notFlat, tilt, flat, faceUp, false);
        }
        break;

      case FlatPhoneState.candidate:
        final ok = flat &&
            faceUp &&
            rate <= config.gyroActivateRadPerSec &&
            gravErr <= config.gravityToleranceKeep;
        if (!ok) {
          _candidateSince = null;
          _set(FlatPhoneState.notFlat, tilt, flat, faceUp, false);
        } else if (t.difference(_candidateSince!) >= config.stableDuration) {
          _set(FlatPhoneState.stable, tilt, true, true, true);
          onCanAttemptOpenHud?.call();
        } else {
          _set(FlatPhoneState.candidate, tilt, true, true, false);
        }
        break;

      case FlatPhoneState.stable:
      case FlatPhoneState.hudActive:
        final tooMoving = rate > config.gyroDeactivateRadPerSec ||
            gravErr > config.gravityToleranceKeep * 2;
        if (tooMoving) {
          _motionSince ??= t;
        } else {
          _motionSince = null;
        }
        final motionLost = _motionSince != null &&
            t.difference(_motionSince!) >= config.gyroDeactivateHold;
        if (!flat || !faceUp || motionLost) {
          _motionSince = null;
          _candidateSince = null;
          _set(FlatPhoneState.notFlat, tilt, flat, faceUp, false);
        } else {
          _set(FlatPhoneState.hudActive, tilt, true, true, true);
        }
        break;
    }
  }
}
