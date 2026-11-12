import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'joint_kalman_filter_2d.dart';
import 'kalman_1d_filter.dart';
import 'speed_fusion.dart';
import 'gps_debug.dart';

enum LocationState { waiting, active, unavailable }

class VehiclePosition {
  final double lat;
  final double lng;
  final double headingDeg;
  final double speedKmh;
  final double accuracyM;

  final bool isEstimated;

  const VehiclePosition({
    required this.lat,
    required this.lng,
    required this.headingDeg,
    required this.speedKmh,
    required this.accuracyM,
    this.isEstimated = false,
  });
}

class JointKalmanDiagnostics {
  final bool enabled;
  final KalmanLocationSample? raw;
  final KalmanLocationSample? filtered;
  final double totalJitterReducedMeters;
  final double processNoiseQ;
  final double measurementNoiseMultiplier;

  const JointKalmanDiagnostics({
    required this.enabled,
    required this.raw,
    required this.filtered,
    required this.totalJitterReducedMeters,
    required this.processNoiseQ,
    required this.measurementNoiseMultiplier,
  });

  JointKalmanDiagnostics copyWith({
    bool? enabled,
    KalmanLocationSample? raw,
    KalmanLocationSample? filtered,
    double? totalJitterReducedMeters,
    double? processNoiseQ,
    double? measurementNoiseMultiplier,
  }) {
    return JointKalmanDiagnostics(
      enabled: enabled ?? this.enabled,
      raw: raw ?? this.raw,
      filtered: filtered ?? this.filtered,
      totalJitterReducedMeters:
          totalJitterReducedMeters ?? this.totalJitterReducedMeters,
      processNoiseQ: processNoiseQ ?? this.processNoiseQ,
      measurementNoiseMultiplier:
          measurementNoiseMultiplier ?? this.measurementNoiseMultiplier,
    );
  }
}

class LocationService {
  final _controller = StreamController<VehiclePosition>.broadcast();
  StreamSubscription<Position>? _sub;
  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  bool _disposed = false;
  int _restartAttempts = 0;
  Timer? _restartTimer;
  DateTime? _startedAt;
  bool _gotFirstFix = false;

  int _runId = 0;
  int? _lastGpsMeasurementTsMs;
  int _consecutiveRejected = 0;
  double? _rejLat;
  double? _rejLng;
  int? _rejTsMs;
  DateTime? _lastRawCallbackAt;
  int get _rebaselineAfterRejected => _navigationMode ? 2 : 4;
  static const double _navMinGateSpeedMs = 12.0;
  static const double _maxGateSpeedMs = 45.0;
  double _avgFixIntervalMs = 1000;
  int _slowCadenceCount = 0;
  DateTime? _prevAcceptedAt;
  static const double _poorAccuracyM = 80.0;
  double? _lastAcceptedAccuracyM;
  static const Duration _poorAccuracyGrace = Duration(seconds: 20);
  double? _lastAcceptedRawLat;
  double? _lastAcceptedRawLng;
  int? _lastAcceptedRawTsMs;
  double? _lastAcceptedRawSpeedMs;

  static const int _unavailableAfterAttempts = 4;

  LocationState _state = LocationState.waiting;
  LocationState get state => _state;
  final _stateController = StreamController<LocationState>.broadcast();
  Stream<LocationState> get stateStream => _stateController.stream;

  void _setState(LocationState next) {
    if (_state == next) return;
    GpsDebug.log('state', '${_state.name} -> ${next.name}');
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Timer? _noFixWatchdog;

  Timer? _stallWatchdog;
  DateTime? _lastStallRestartAt;
  static const Duration _stallTimeout = Duration(seconds: 12);
  static const Duration _stallRestartCooldown = Duration(seconds: 20);
  /// وقتی ساکنیم و فیلتر فاصله ۳ متری کال‌بک نمی‌دهد، استریم مرده را بعد از این مدت هم ری‌استارت کن.
  static const Duration _idleStallTimeout = Duration(seconds: 60);

  /// Free-drive mode uses a 3 m distance filter, so a parked phone legitimately
  /// produces no GPS callbacks. Restarting the stream in that case only burns battery.
  bool get _isIdleWithoutNavigation {
    if (_navigationMode) return false;
    final speed = _lastAcceptedRawSpeedMs;
    return _gotFirstFix && speed != null && speed < 1.0;
  }

  void _armStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_disposed) return;
      final last = _lastRawCallbackAt ?? _lastGpsFixAt;
      if (last == null) return;
      final now = DateTime.now();
      if (_isIdleWithoutNavigation &&
          now.difference(last) < _idleStallTimeout) {
        return;
      }
      if (now.difference(last) < _stallTimeout) return;
      final lastRestart = _lastStallRestartAt;
      if (lastRestart != null &&
          now.difference(lastRestart) < _stallRestartCooldown) {
        return;
      }
      _lastStallRestartAt = now;
      GpsDebug.count('restart.stall');
      GpsDebug.log('watchdog',
          'STALL restart: no raw callback for ${now.difference(last).inSeconds}s idle=$_isIdleWithoutNavigation');
      start();
    });
  }

  void ensureAlive({Duration maxAge = const Duration(seconds: 6)}) {
    final last = _lastGpsFixAt;
    final started = _startedAt;
    GpsDebug.count('ensureAlive');
    if (_disposed) {
      GpsDebug.log('ensureAlive', 'disposed -> start() caller=${GpsDebug.caller()}');
      start();
      return;
    }
    if (_isIdleWithoutNavigation) return;
    if (last == null) {
      if (started == null ||
          DateTime.now().difference(started) > const Duration(seconds: 15)) {
        GpsDebug.log('ensureAlive', 'no fix yet -> start() caller=${GpsDebug.caller()}');
        start();
      }
      return;
    }
    final age = DateTime.now().difference(last);
    if (age > maxAge) {
      GpsDebug.log('ensureAlive',
          'last fix ${age.inSeconds}s old -> start() caller=${GpsDebug.caller()}');
      start();
    }
  }

  static const Duration _fusedNoFixTimeout = Duration(seconds: 12);
  static const Duration _rawManagerNoFixTimeout = Duration(seconds: 40);

  Duration get _noFixTimeout =>
      _useRawLocationManager ? _rawManagerNoFixTimeout : _fusedNoFixTimeout;

  void _armNoFixWatchdog() {
    _noFixWatchdog?.cancel();
    final timeout = _noFixTimeout;
    final provider = _useRawLocationManager ? 'LocationManager خام' : 'Fused';
    _noFixWatchdog = Timer(timeout, () {
      if (_disposed || _gotFirstFix) return;
      
      GpsDebug.log('watchdog', 'NO-FIX after ${timeout.inSeconds}s on $provider');
      _onStreamError('no-fix-timeout', isNoFixTimeout: true);
    });
  }

  double _accelBaseline = 0;
  double _accelJerk = 0;
  double _accelMotionNoise = 0;
  double _gyroAngularRate = 0;
  double _gyroMotionNoise = 0;

  bool useJointKalman = true;
  final _jointKalman = JointKalmanFilter2D();

  Timer? _gpsGapPredictionTimer;
  Timer? _networkAssistTimer;
  DateTime? _lastGpsFixAt;
  DateTime? _lastNetworkAssistAt;
  bool _networkAssistInFlight = false;
  bool _isPredictingGpsGap = false;
  double _lastPipelineSpeedKmh = 0;

  static const Duration _gpsGapBeforePrediction = Duration(milliseconds: 1300);
  static const Duration _maxGpsPredictionGap = Duration(seconds: 15);
  static const Duration _networkAssistAfterGap = Duration(seconds: 3);
  static const Duration _networkAssistInterval = Duration(seconds: 10);

  final _jointKalmanDiagnosticsController =
      StreamController<JointKalmanDiagnostics>.broadcast();

  void setJointKalmanEnabled(bool enabled) {
    useJointKalman = enabled;
    _jointKalman.reset();
  }

  static const double _metersPerDegLat = 111320.0;

  double? _lastSentLat;
  double? _lastSentLng;

  final _xFilter = Kalman1D(processNoisePerSecond: 1.5);
  final _yFilter = Kalman1D(processNoisePerSecond: 1.5);
  final _speedFilter =
      Kalman1D(processNoisePerSecond: 0.8, minMeasurementAccuracy: 2.0);
  final _speedFusion = SpeedFusion();

  double? _smoothHeading;
  int? _lastHeadingTsMs;

  static const double _headingTimeConstantSec = 0.65;
  static const double _headingFreezeSpeedKmh = 2.0;

  VehiclePosition? _latestPosition;
  DateTime? _latestPositionAt;
  bool _latestHooked = false;

  Stream<VehiclePosition> get stream {
    if (!_latestHooked) {
      _latestHooked = true;
      _controller.stream.listen((p) {
        _latestPosition = p;
        _latestPositionAt = DateTime.now();
      });
    }
    return Stream<VehiclePosition>.multi((c) {
      final last = _latestPosition;
      final at = _latestPositionAt;
      if (last != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 10)) {
        c.add(last);
      }
      final sub = _controller.stream.listen(c.add, onError: c.addError);
      c.onCancel = sub.cancel;
    }, isBroadcast: true);
  }

  bool _navigationMode = false;

  void setNavigationMode(bool value) {
    if (_navigationMode == value) return;
    GpsDebug.log('nav', 'setNavigationMode($value) disposed=$_disposed hasSub=${_sub != null}');
    _navigationMode = value;
    if (!_disposed && _sub != null) start();
  }

  void start() {
    final wasDisposed = _disposed;
    _disposed = false;
    final runId = ++_runId;
    GpsDebug.count('start');
    GpsDebug.log('start',
        'runId=$runId nav=$_navigationMode rawMgr=$_useRawLocationManager wasDisposed=$wasDisposed attempts=$_restartAttempts caller=${GpsDebug.caller()}');
    _restartTimer?.cancel();
    _sub?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    final settings = _buildLocationSettings();
    _lastSentLat = null;
    _lastSentLng = null;
    _xFilter.reset();
    _yFilter.reset();
    _speedFilter.reset();
    _speedFusion.reset();
    _jointKalman.reset();
    _lastGpsFixAt = null;
    _lastGpsMeasurementTsMs = null;
    _lastAcceptedRawLat = null;
    _lastAcceptedRawLng = null;
    _lastAcceptedRawTsMs = null;
    _lastAcceptedRawSpeedMs = null;
    _lastAcceptedAccuracyM = null;
    _consecutiveRejected = 0;
    _rejLat = _rejLng = null;
    _rejTsMs = null;
    _lastRawCallbackAt = null;
    _lastNetworkAssistAt = null;
    _networkAssistInFlight = false;
    _isPredictingGpsGap = false;
    _lastPipelineSpeedKmh = 0;
    _prevAcceptedAt = null;
    _slowCadenceCount = 0;
    _avgFixIntervalMs = 1000;
    _gpsGapPredictionTimer?.cancel();
    _networkAssistTimer?.cancel();
    _smoothHeading = null;
    _lastHeadingTsMs = null;
    _accelBaseline = 0;
    _accelJerk = 0;
    _accelMotionNoise = 0;
    _gyroAngularRate = 0;
    _gyroMotionNoise = 0;
    _startedAt = DateTime.now();
    _gotFirstFix = false;
    _setState(LocationState.waiting);
    
    unawaited(_logRuntimeProbe(runId));

    unawaited(_emitLastKnownPosition(runId));
    unawaited(_emitQuickInitialPosition(runId));

    GpsDebug.log('start',
        'subscribe: ${settings.runtimeType} acc=${settings.accuracy} dist=${settings.distanceFilter} forceLM=${settings is AndroidSettings ? settings.forceLocationManager : '-'}');
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (position) => _onPosition(position, runId),
      onError: (Object error, StackTrace stackTrace) {
        GpsDebug.count('stream.error');
        GpsDebug.log('stream', 'ERROR ${error.runtimeType}: $error runId=$runId');
        _onStreamError(error, runId: runId);
      },
      onDone: () => GpsDebug.log('stream',
          'DONE: platform closed the position stream! runId=$runId current=$_runId disposed=$_disposed'),
      cancelOnError: false,
    );
    if (_navigationMode) {
      _accelSub = userAccelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen(_onAccel, onError: (_) {});
      _gyroSub = gyroscopeEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen(_onGyroscope, onError: (_) {});
    }
    _gpsGapPredictionTimer = Timer.periodic(
      Duration(milliseconds: _navigationMode ? 500 : 1000),
      (_) => _predictGpsGap(),
    );
    if (_navigationMode) {
      _networkAssistTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _requestNetworkAssistIfNeeded(),
      );
    }
    _armNoFixWatchdog();
    _armStallWatchdog();
    _armAccuracyUpgradeWatchdog(runId);
  }

  /// اگر روی Fused هستیم و بعد از ۳۰ ثانیه دقت هنوز بدتر از ۶۰ متر است
  /// (یعنی فقط فیکس شبکه‌ای می‌گیریم)، به GPS خام برگرد.
  void _armAccuracyUpgradeWatchdog(int runId) {
    _accuracyUpgradeTimer?.cancel();
    if (!Platform.isAndroid || _useRawLocationManager) return;
    _accuracyUpgradeTimer = Timer(const Duration(seconds: 30), () {
      if (_disposed || runId != _runId || _useRawLocationManager) return;
      final acc = _lastAcceptedAccuracyM;
      if (acc != null && acc <= 60) return;
      GpsDebug.log('watchdog',
          'Fused accuracy still ${acc?.toStringAsFixed(0) ?? 'n/a'}m after 30s -> switching to RAW LocationManager');
      _useRawLocationManager = true;
      start();
    });
  }

  Future<void> _logRuntimeProbe(int runId) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final permission = await Geolocator.checkPermission();
      GpsDebug.log('probe',
          'serviceEnabled=$serviceEnabled permission=${permission.name} stale=${_disposed || runId != _runId}');
    } catch (error) {
      GpsDebug.log('probe', 'probe failed: $error');
    }
  }


  Future<void> _emitLastKnownPosition(int runId) async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null || _disposed || runId != _runId || _gotFirstFix) {
        GpsDebug.log('lastKnown',
            'skip: hasLast=${last != null} disposed=$_disposed staleRun=${runId != _runId} gotFix=$_gotFirstFix');
        return;
      }

      final age = DateTime.now().difference(last.timestamp).inSeconds;
      if (age > 90 || !_isValidCoordinate(last.latitude, last.longitude)) {
        GpsDebug.log('lastKnown', 'skip: age=${age}s too old/invalid');
        return;
      }

      GpsDebug.log('lastKnown',
          'emit estimated age=${age}s acc=${last.accuracy.toStringAsFixed(0)}');
      _controller.add(VehiclePosition(
        lat: last.latitude,
        lng: last.longitude,
        headingDeg:
            last.heading.isFinite && last.heading >= 0 ? last.heading : 0,
        speedKmh: 0,
        accuracyM:
            last.accuracy.isFinite && last.accuracy > 0 ? last.accuracy : 50,
        isEstimated: true,
      ));
    } catch (e) {
      GpsDebug.log('lastKnown', 'failed: $e');
    }
  }

  Future<void> _emitQuickInitialPosition(int runId) async {
    try {
      final quick = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 6),
      );
      if (_disposed ||
          runId != _runId ||
          _gotFirstFix ||
          !_isValidCoordinate(quick.latitude, quick.longitude)) {
        GpsDebug.log('quick',
            'skip: disposed=$_disposed staleRun=${runId != _runId} gotFix=$_gotFirstFix');
        return;
      }
      final accuracy = quick.accuracy.isFinite && quick.accuracy > 0
          ? quick.accuracy
          : 100.0;
      if (accuracy > 1000) {
        GpsDebug.log('quick', 'skip: accuracy=${accuracy.toStringAsFixed(0)}m');
        return;
      }
      GpsDebug.log('quick', 'emit estimated acc=${accuracy.toStringAsFixed(0)}');
      _controller.add(VehiclePosition(
        lat: quick.latitude,
        lng: quick.longitude,
        headingDeg:
            quick.heading.isFinite && quick.heading >= 0 ? quick.heading : 0,
        speedKmh: 0,
        accuracyM: accuracy,
        isEstimated: true,
      ));
    } catch (error) {
      GpsDebug.log('quick', 'failed: ${error.runtimeType} $error');
    }
  }

  static const int _fallbackToRawManagerAfterAttempts = 1;
  // روی اندروید پیش‌فرض LocationManager خام (GPS واقعی)؛ در تست میدانی Fused ماندگار روی
  // فیکس شبکه‌ای ~۱۰۰ متر می‌ماند ولی LocationManager خام در چند ثانیه به ۴۳ متر رسید.
  bool _useRawLocationManager = Platform.isAndroid;
  Timer? _accuracyUpgradeTimer;

  void _onStreamError(
    Object error, {
    int? runId,
    bool isNoFixTimeout = false,
  }) {
    if (runId != null && runId != _runId) {
      GpsDebug.log('error', 'ignored (stale run $runId != $_runId): $error');
      return;
    }
    if (_disposed) {
      GpsDebug.log('error', 'ignored (service stopped/disposed): $error');
      return;
    }
    _restartAttempts++;
    GpsDebug.count('restart.error');
    GpsDebug.log('error',
        'attempt=$_restartAttempts err=$error noFixTimeout=$isNoFixTimeout gotFix=$_gotFirstFix rawMgr=$_useRawLocationManager');
    if (isNoFixTimeout && _restartAttempts >= _fallbackToRawManagerAfterAttempts) {
      // بدون فیکس: بین Fused و GPS خام جابه‌جا شو (Fused به اینترنت/سرویس گوگل نیاز دارد، خام نه)
      _useRawLocationManager = !_useRawLocationManager;
      GpsDebug.log('error', 'no-fix -> toggled provider, rawMgr=$_useRawLocationManager');
    } else if (!_useRawLocationManager &&
        _restartAttempts >= _fallbackToRawManagerAfterAttempts) {
      _useRawLocationManager = true;
      GpsDebug.log('error', 'switching to RAW LocationManager (forceLocationManager=true)');
    }
    if (!_gotFirstFix &&
        !isNoFixTimeout &&
        _restartAttempts >= _unavailableAfterAttempts) {
      _setState(LocationState.unavailable);
    }
    final delaySec = math.min(1 << math.min(_restartAttempts, 4), 10);
    _restartTimer?.cancel();
    GpsDebug.log('error', 'restart in ${delaySec}s');
    _restartTimer = Timer(Duration(seconds: delaySec), () {
      if (!_disposed) start();
    });
  }

  LocationSettings _buildLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: _navigationMode
            ? LocationAccuracy.bestForNavigation
            : LocationAccuracy.high,
        distanceFilter: _navigationMode ? 0 : 3,
        intervalDuration: _navigationMode
            ? const Duration(milliseconds: 1000)
            : const Duration(milliseconds: 2000),
        forceLocationManager: _useRawLocationManager,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'آبتین‌مپ در حال دریافت موقعیت است',
          notificationText: 'مسیریابی و ردیابی موقعیت در پس‌زمینه فعال است',
          enableWakeLock: false,
          notificationIcon: AndroidResource(
            name: 'ic_launcher',
            defType: 'mipmap',
          ),
        ),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: _navigationMode
            ? LocationAccuracy.bestForNavigation
            : LocationAccuracy.best,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: _navigationMode ? 0 : 3,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  void _onAccel(UserAccelerometerEvent e) {
    final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _accelBaseline += (mag - _accelBaseline) * 0.01;
    final instantJerk = (mag - _accelBaseline).abs();
    _accelJerk += (instantJerk - _accelJerk) * 0.25;
    _accelMotionNoise +=
        (math.min(_accelJerk * _accelJerk, 12.0) - _accelMotionNoise) * 0.18;
  }

  void _onGyroscope(GyroscopeEvent event) {
    final angularRate = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    _gyroAngularRate += (angularRate - _gyroAngularRate) * 0.13;
    final turnEvidence = math.min(_gyroAngularRate * _gyroAngularRate, 8.0);
    _gyroMotionNoise += (turnEvidence - _gyroMotionNoise) * 0.16;
  }

  void _onPosition(Position p, int runId) {
    if (_disposed || runId != _runId) {
      GpsDebug.count('drop.disposedOrStaleRun');
      GpsDebug.log('pos', 'DROP disposed=$_disposed runId=$runId current=$_runId');
      return;
    }
    if (!_isValidCoordinate(p.latitude, p.longitude)) {
      GpsDebug.count('drop.invalidCoord');
      GpsDebug.log('pos', 'DROP invalid coordinate ${p.latitude},${p.longitude}');
      return;
    }
    _lastRawCallbackAt = DateTime.now();
    GpsDebug.count('raw');
    final rawN = GpsDebug.c('raw');
    if (rawN <= 5 || rawN % 5 == 0) {
      GpsDebug.log('raw',
          '#$rawN ${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)} acc=${p.accuracy.toStringAsFixed(0)} spd=${p.speed.toStringAsFixed(1)} mock=${p.isMocked} ts=${p.timestamp.toIso8601String()}');
    }
    var tsMs = p.timestamp.millisecondsSinceEpoch;
    if (_lastGpsMeasurementTsMs != null && tsMs <= _lastGpsMeasurementTsMs!) {
      // بعضی دستگاه‌ها/شبیه‌سازها timestamp تکراری یا غیرصعودی می‌دهند.
      // فیکس واقعاً تکراری (همان مختصات) را دور بریز؛ ولی فیکس جدید را دور نینداز
      // و timestamp را با ساعت دیوار به‌صورت صعودی بازسازی کن.
      final sameSpot = _lastAcceptedRawLat == p.latitude &&
          _lastAcceptedRawLng == p.longitude;
      if (sameSpot) {
        GpsDebug.count('drop.duplicate');
        GpsDebug.log('gate',
            'DROP duplicate fix (same coords, ts=$tsMs <= last=$_lastGpsMeasurementTsMs)');
        return;
      }
      final wallMs = _lastGpsFixAt == null
          ? 1000
          : DateTime.now().difference(_lastGpsFixAt!).inMilliseconds;
      final int fixed = _lastGpsMeasurementTsMs! + math.max<int>(wallMs, 200);
      GpsDebug.count('ts.repaired');
      GpsDebug.log('gate',
          'timestamp not increasing (ts=$tsMs last=$_lastGpsMeasurementTsMs) -> repaired to $fixed');
      tsMs = fixed;
    }
    final previousLat = _lastAcceptedRawLat;
    final previousLng = _lastAcceptedRawLng;
    final previousTs = _lastAcceptedRawTsMs;
    if (_gotFirstFix &&
        p.accuracy.isFinite &&
        p.accuracy > _poorAccuracyM &&
        // فیکس شبکه‌ای (~۹۰ متر) وقتی آخرین فیکس هم همین‌قدر دقت داشت رد نشود
        p.accuracy > 1.5 * (_lastAcceptedAccuracyM ?? 0) &&
        _lastGpsFixAt != null &&
        DateTime.now().difference(_lastGpsFixAt!) < _poorAccuracyGrace) {
      GpsDebug.count('drop.poorAccuracy');
      GpsDebug.log('gate', 'DROP poor accuracy ${p.accuracy.toStringAsFixed(0)}m > ${_poorAccuracyM.toStringAsFixed(0)}m');
      return;
    }
    if (previousLat != null && previousLng != null && previousTs != null) {
      final dtSec = (tsMs - previousTs) / 1000.0;
      if (dtSec > 0 && dtSec <= 15) {
        final displacementM = _calculateDistance(
          previousLat, previousLng, p.latitude, p.longitude,
        );
        final reportedAccuracy =
            p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : 20.0;
        final previousSpeed = _lastAcceptedRawSpeedMs ?? 0.0;
        final currentSpeed = p.speed.isFinite && p.speed >= 0 ? p.speed : 0.0;
        final speedForGate = math.min(
          _maxGateSpeedMs,
          math.max(
            math.max(previousSpeed, currentSpeed),
            _navigationMode ? _navMinGateSpeedMs : 0.0,
          ),
        );
        final physicallyExpected = speedForGate * dtSec;
        final allowedJump = math.min(
          math.max(120.0, _maxGateSpeedMs * dtSec),
          math.max(28.0, physicallyExpected + reportedAccuracy * 1.75 + 12.0),
        );
        if (displacementM > allowedJump) {
          final rl = _rejLat, rg = _rejLng, rt = _rejTsMs;
          var consistent = false;
          if (rl != null && rg != null && rt != null) {
            final dt2 = math.max((tsMs - rt) / 1000.0, 0.1);
            final d = _calculateDistance(rl, rg, p.latitude, p.longitude);
            consistent = d <=
                math.min(60.0,
                    math.max(15.0, currentSpeed * dt2 + reportedAccuracy * 2 + 8));
          }
          _consecutiveRejected = consistent ? _consecutiveRejected + 1 : 1;
          _rejLat = p.latitude;
          _rejLng = p.longitude;
          _rejTsMs = tsMs;
          if (_consecutiveRejected < _rebaselineAfterRejected) {
            GpsDebug.count('drop.jump');
            GpsDebug.log('gate',
                'DROP jump ${displacementM.toStringAsFixed(0)}m > allowed ${allowedJump.toStringAsFixed(0)}m dt=${dtSec.toStringAsFixed(1)}s rejected=$_consecutiveRejected/$_rebaselineAfterRejected');
            return;
          }
          GpsDebug.log('gate', 'REBASELINE after $_consecutiveRejected consistent rejects');
          _jointKalman.reset();
          _xFilter.reset();
          _yFilter.reset();
          _speedFilter.reset();
          _speedFusion.reset();
          _lastSentLat = null;
          _lastSentLng = null;
        }
      }
    }
    _consecutiveRejected = 0;
    _rejLat = _rejLng = null;
    _rejTsMs = null;
    _lastGpsMeasurementTsMs = tsMs;
    _lastAcceptedRawLat = p.latitude;
    _lastAcceptedRawLng = p.longitude;
    _lastAcceptedRawTsMs = tsMs;
    _lastAcceptedRawSpeedMs = p.speed.isFinite && p.speed >= 0 ? p.speed : 0.0;
    final acceptedNow = DateTime.now();
    final prevAcc = _prevAcceptedAt;
    _prevAcceptedAt = acceptedNow;
    if (prevAcc != null) {
      final ivMs = acceptedNow.difference(prevAcc).inMilliseconds.toDouble();
      if (ivMs > 0 && ivMs < 20000) {
        _avgFixIntervalMs += (ivMs - _avgFixIntervalMs) * 0.3;
        if (_navigationMode && ivMs > 3000) {
          _slowCadenceCount++;
        } else {
          _slowCadenceCount = 0;
        }
      }
    }
    _lastGpsFixAt = acceptedNow;
    _lastAcceptedAccuracyM = p.accuracy.isFinite ? p.accuracy : null;
    GpsDebug.count('accepted');
    if (_isPredictingGpsGap) {
      _isPredictingGpsGap = false;
      GpsDebug.log('gap', 'prediction ended: real GPS fix is back');
    }
    _restartAttempts = 0;
    _noFixWatchdog?.cancel();
    _noFixWatchdog = null;
    if (!_gotFirstFix) {
      _gotFirstFix = true;
      _setState(LocationState.active);
      final ms = _startedAt == null
          ? null
          : DateTime.now().difference(_startedAt!).inMilliseconds;
      GpsDebug.log('fix', 'FIRST FIX after ${ms}ms');
    }
    final posAccuracy =
        p.accuracy.isFinite && p.accuracy > 0 ? p.accuracy : 15.0;

    final speedEstimate = _speedFusion.measure(
      latitude: p.latitude,
      longitude: p.longitude,
      timestampMs: tsMs,
      gnssSpeedMs: p.speed,
      accuracyMeters: posAccuracy,
    );
    final measuredSpeedMs = speedEstimate.metersPerSecond;
    _lastAcceptedRawSpeedMs = measuredSpeedMs;
    if (Platform.isAndroid &&
        _navigationMode &&
        !_useRawLocationManager &&
        _slowCadenceCount >= 3) {
      GpsDebug.log('watchdog',
          'nav fix cadence ${_avgFixIntervalMs.toStringAsFixed(0)}ms -> switching to RAW LocationManager');
      _useRawLocationManager = true;
      _slowCadenceCount = 0;
      Future.microtask(() {
        if (!_disposed && runId == _runId) start();
      });
    }

    final rawSample = KalmanLocationSample(
      latitude: p.latitude,
      longitude: p.longitude,
      speedMs: measuredSpeedMs,
      bearingDeg: p.heading.isFinite && p.heading >= 0 ? p.heading : 0.0,
      accuracyMeters: posAccuracy,
      speedAccuracyMs: speedEstimate.source == SpeedSource.gnss &&
              p.speedAccuracy.isFinite &&
              p.speedAccuracy > 0
          ? p.speedAccuracy
          : 4.0,
      timestampMs: tsMs,
    );
    final sensorProcessNoise =
        (_accelMotionNoise + _gyroMotionNoise * 0.65).clamp(0.0, 16.0);
    final jointFiltered = _jointKalman.process(
      rawSample,
      extraProcessNoise: sensorProcessNoise,
    );
    if (!_jointKalmanDiagnosticsController.isClosed) {
      _jointKalmanDiagnosticsController.add(JointKalmanDiagnostics(
        enabled: useJointKalman,
        raw: rawSample,
        filtered: jointFiltered,
        totalJitterReducedMeters: _jointKalman.totalJitterReducedMeters,
        processNoiseQ: _jointKalman.processNoiseQ,
        measurementNoiseMultiplier: _jointKalman.measurementNoiseMultiplier,
      ));
    }

    if (useJointKalman) {
      final rawSpeedMs = rawSample.speedMs;
      final jointIsMoving = rawSpeedMs >= 0.8 ||
          (jointFiltered.speedMs > 1.2 && _lastPipelineSpeedKmh > 3.0);
      final locked = _applyStationaryHysteresis(
        lat: jointFiltered.latitude,
        lng: jointFiltered.longitude,
        isMoving: jointIsMoving,
      );
      final speedKmh =
          locked.stationary ? 0.0 : math.max(jointFiltered.speedMs, 0) * 3.6;
      final headingDeg = _smoothedHeading(
        headingDeg: jointFiltered.bearingDeg,
        speedKmh: speedKmh,
        timestampMs: tsMs,
        turningEvidence: _gyroAngularRate,
      );
      _lastPipelineSpeedKmh = speedKmh;
      _controller.add(VehiclePosition(
        lat: locked.lat,
        lng: locked.lng,
        headingDeg: headingDeg,
        speedKmh: speedKmh,
        accuracyM: jointFiltered.accuracyMeters,
      ));
      return;
    }

    final isMoving = measuredSpeedMs >= 0.8;
    final dynamicProcessNoise = isMoving ? 2.5 : 0.2;

    final filteredLatRaw = _yFilter.process(
        p.latitude, posAccuracy / _metersPerDegLat, tsMs,
        extraProcessNoise: dynamicProcessNoise / _metersPerDegLat);
    final filteredLngRaw = _xFilter.process(p.longitude,
        posAccuracy / (_metersPerDegLat * math.cos(degToRad(p.latitude))), tsMs,
        extraProcessNoise: dynamicProcessNoise /
            (_metersPerDegLat * math.cos(degToRad(p.latitude))));

    final locked = _applyStationaryHysteresis(
      lat: filteredLatRaw,
      lng: filteredLngRaw,
      isMoving: isMoving,
    );
    final filteredLat = locked.lat;
    final filteredLng = locked.lng;
    final positionStationary = locked.stationary;

    final rawSpeedMs = p.speed.isFinite && p.speed >= 0 ? p.speed : 0.0;
    final speedAccuracy =
        p.speedAccuracy.isFinite && p.speedAccuracy > 0 ? p.speedAccuracy : 1.5;

    final accelExtraNoise = math.min(_accelJerk * 2.5, 6.0);

    final adaptiveNoise = (_accelJerk > 1.5) ? 2.2 : 0.0;

    final filteredSpeedMs = _speedFilter.process(
      rawSpeedMs,
      speedAccuracy,
      tsMs,
      extraProcessNoise: accelExtraNoise + adaptiveNoise,
    );
    final speedKmh =
        positionStationary ? 0.0 : math.max(filteredSpeedMs, 0) * 3.6;
    _lastPipelineSpeedKmh = speedKmh;

    final headingDeg = _smoothedHeading(
      headingDeg: p.heading,
      speedKmh: speedKmh,
      timestampMs: tsMs,
    );

    final uncertaintyDeg = math.sqrt(
      _xFilter.uncertainty * _xFilter.uncertainty +
          _yFilter.uncertainty * _yFilter.uncertainty,
    );
    final accuracyM = math.max(uncertaintyDeg * _metersPerDegLat, posAccuracy);

    _controller.add(VehiclePosition(
      lat: filteredLat,
      lng: filteredLng,
      headingDeg: headingDeg,
      speedKmh: speedKmh,
      accuracyM: accuracyM,
    ));
  }

  void _predictGpsGap() {
    if (_disposed || !useJointKalman || _lastGpsFixAt == null) return;
    final now = DateTime.now();
    final gap = now.difference(_lastGpsFixAt!);
    final gapBefore = Duration(
        milliseconds: math.max(_gpsGapBeforePrediction.inMilliseconds,
            (_avgFixIntervalMs * 1.5).round().clamp(1300, 4000)));
    if (gap < gapBefore || gap > _maxGpsPredictionGap) return;
    final predicted = _jointKalman.predictOnly(now.millisecondsSinceEpoch);
    if (predicted == null || predicted.speedMs < 0.35) return;
    if (!_isPredictingGpsGap) {
      _isPredictingGpsGap = true;
      GpsDebug.log('gap', 'prediction STARTED: no GPS for ${gap.inMilliseconds}ms');
    }
    final grownAccuracy =
        (predicted.accuracyMeters + gap.inMilliseconds / 1000 * 6)
            .clamp(1.0, 80.0)
            .toDouble();
    _lastPipelineSpeedKmh = predicted.speedMs * 3.6;
    _controller.add(VehiclePosition(
      lat: predicted.latitude,
      lng: predicted.longitude,
      headingDeg: predicted.bearingDeg,
      speedKmh: predicted.speedMs * 3.6,
      accuracyM: grownAccuracy,
      isEstimated: true,
    ));
  }

  void _requestNetworkAssistIfNeeded() {
    if (_disposed ||
        !useJointKalman ||
        !_gotFirstFix ||
        _lastGpsFixAt == null ||
        _networkAssistInFlight ||
        (_lastAcceptedRawSpeedMs ?? 0) < 1.0) {
      return;
    }
    final now = DateTime.now();
    final gap = now.difference(_lastGpsFixAt!);
    if (gap < _networkAssistAfterGap) return;
    if (_lastNetworkAssistAt != null &&
        now.difference(_lastNetworkAssistAt!) < _networkAssistInterval) {
      return;
    }
    _lastNetworkAssistAt = now;
    _networkAssistInFlight = true;
    unawaited(_fetchNetworkAssist());
  }

  Future<void> _fetchNetworkAssist() async {
    try {
      final network = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 3),
      );
      if (_disposed || _lastGpsFixAt == null) return;
      final gap = DateTime.now().difference(_lastGpsFixAt!);
      if (gap < _networkAssistAfterGap) return;
      final accuracy = network.accuracy.isFinite && network.accuracy > 0
          ? network.accuracy
          : 250.0;
      if (accuracy > 1000 ||
          !network.latitude.isFinite ||
          !network.longitude.isFinite) {
        
        return;
      }
      final fused = _jointKalman.processPositionOnly(
        KalmanLocationSample(
          latitude: network.latitude,
          longitude: network.longitude,
          speedMs: 0,
          bearingDeg: 0,
          accuracyMeters: accuracy,
          speedAccuracyMs: 1e6,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      
      _controller.add(VehiclePosition(
        lat: fused.latitude,
        lng: fused.longitude,
        headingDeg: fused.bearingDeg,
        speedKmh: _lastPipelineSpeedKmh,
        accuracyM: math.max(fused.accuracyMeters, accuracy),
        isEstimated: true,
      ));
    } catch (_) {
    } finally {
      _networkAssistInFlight = false;
    }
  }

  double _smoothedHeading({
    required double headingDeg,
    required double speedKmh,
    required int timestampMs,
    double turningEvidence = 0,
  }) {
    if (speedKmh >= _headingFreezeSpeedKmh &&
        headingDeg >= 0 &&
        headingDeg.isFinite) {
      final dtSec = _lastHeadingTsMs == null
          ? 1.0
          : math.max((timestampMs - _lastHeadingTsMs!) / 1000.0, 0.0);
      final baseAlpha = 1 - math.exp(-dtSec / _headingTimeConstantSec);
      final alpha = (baseAlpha + turningEvidence * 0.06).clamp(0.0, 0.72);
      _smoothHeading = _lerpAngle(_smoothHeading, headingDeg, alpha);
      _lastHeadingTsMs = timestampMs;
    } else {
      _smoothHeading ??=
          (headingDeg >= 0 && headingDeg.isFinite) ? headingDeg : 0;
    }
    return _smoothHeading ?? 0;
  }

  bool _isValidCoordinate(double lat, double lng) =>
      lat.isFinite && lng.isFinite && lat.abs() <= 90 && lng.abs() <= 180;

  double _lerpAngle(double? current, double target, double alpha) {
    if (current == null) return target;
    var diff = (target - current + 540) % 360 - 180;
    return (current + diff * alpha + 360) % 360;
  }

  double _calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final dLat = degToRad(lat2 - lat1);
    final dLng = degToRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(degToRad(lat1)) *
            math.cos(degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  ({double lat, double lng, bool stationary}) _applyStationaryHysteresis({
    required double lat,
    required double lng,
    required bool isMoving,
  }) {
    var outLat = lat;
    var outLng = lng;
    var stationary = false;
    if (_lastSentLat != null && _lastSentLng != null) {
      final distMoved =
          _calculateDistance(lat, lng, _lastSentLat!, _lastSentLng!);
      final moveThreshold = isMoving ? 1.0 : 5.0;
      if (distMoved < moveThreshold) {
        outLat = _lastSentLat!;
        outLng = _lastSentLng!;
        stationary = true;
      }
    }
    _lastSentLat = outLat;
    _lastSentLng = outLng;
    return (lat: outLat, lng: outLng, stationary: stationary);
  }

  DateTime? get debugLastRawAt => _lastRawCallbackAt;
  DateTime? get debugLastAcceptedAt => _lastGpsFixAt;

  String debugSummary() => 'state=${_state.name} disposed=$_disposed runId=$_runId '
      'nav=$_navigationMode rawMgr=$_useRawLocationManager gotFirstFix=$_gotFirstFix '
      'attempts=$_restartAttempts subActive=${_sub != null && !_sub!.isPaused} '
      'predicting=$_isPredictingGpsGap idleNoNav=$_isIdleWithoutNavigation '
      'lastRaw=${_lastRawCallbackAt?.toIso8601String()} '
      'lastAccepted=${_lastGpsFixAt?.toIso8601String()}';

  void stop() {
    GpsDebug.count('stop');
    GpsDebug.log('stop', 'stop() caller=${GpsDebug.caller()}');
    _disposed = true;
    _runId++;
    _restartTimer?.cancel();
    _noFixWatchdog?.cancel();
    _stallWatchdog?.cancel();
    _gpsGapPredictionTimer?.cancel();
    _networkAssistTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _accelSub?.cancel();
    _accelSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
    _restartAttempts = 0;
    _useRawLocationManager = Platform.isAndroid;
    _setState(LocationState.waiting);
  }

  void dispose() {
    GpsDebug.log('stop', 'dispose() caller=${GpsDebug.caller()}');
    _disposed = true;
    _runId++;
    _restartTimer?.cancel();
    _noFixWatchdog?.cancel();
    _stallWatchdog?.cancel();
    _gpsGapPredictionTimer?.cancel();
    _networkAssistTimer?.cancel();
    _sub?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _controller.close();
    _jointKalmanDiagnosticsController.close();
    _stateController.close();
  }
}

double degToRad(double deg) => deg * math.pi / 180;
