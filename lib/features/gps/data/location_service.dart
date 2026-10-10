import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'joint_kalman_filter_2d.dart';
import 'kalman_1d_filter.dart';
import 'speed_fusion.dart';

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
  static const int _rebaselineAfterRejected = 4;
  static const double _poorAccuracyM = 80.0;
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
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Timer? _noFixWatchdog;

  Timer? _stallWatchdog;
  DateTime? _lastStallRestartAt;
  static const Duration _stallTimeout = Duration(seconds: 12);
  static const Duration _stallRestartCooldown = Duration(seconds: 20);

  void _armStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_disposed) return;
      final last = _lastRawCallbackAt ?? _lastGpsFixAt;
      if (last == null) return;
      final now = DateTime.now();
      if (now.difference(last) < _stallTimeout) return;
      final lastRestart = _lastStallRestartAt;
      if (lastRestart != null &&
          now.difference(lastRestart) < _stallRestartCooldown) {
        return;
      }
      _lastStallRestartAt = now;
      start();
    });
  }

  void ensureAlive({Duration maxAge = const Duration(seconds: 6)}) {
    final last = _lastGpsFixAt;
    final started = _startedAt;
    if (_disposed) {
      start();
      return;
    }
    if (last == null) {
      if (started == null ||
          DateTime.now().difference(started) > const Duration(seconds: 15)) {
        start();
      }
      return;
    }
    if (DateTime.now().difference(last) > maxAge) start();
  }

  static const Duration _fusedNoFixTimeout = Duration(seconds: 12);
  static const Duration _rawManagerNoFixTimeout = Duration(seconds: 45);

  Duration get _noFixTimeout =>
      _useRawLocationManager ? _rawManagerNoFixTimeout : _fusedNoFixTimeout;

  void _armNoFixWatchdog() {
    _noFixWatchdog?.cancel();
    final timeout = _noFixTimeout;
    final provider = _useRawLocationManager ? 'LocationManager خام' : 'Fused';
    _noFixWatchdog = Timer(timeout, () {
      if (_disposed || _gotFirstFix) return;
      
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
    _navigationMode = value;
    if (!_disposed && _sub != null) start();
  }

  void start() {
    _disposed = false;
    final runId = ++_runId;
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
    _consecutiveRejected = 0;
    _rejLat = _rejLng = null;
    _rejTsMs = null;
    _lastRawCallbackAt = null;
    _lastNetworkAssistAt = null;
    _networkAssistInFlight = false;
    _isPredictingGpsGap = false;
    _lastPipelineSpeedKmh = 0;
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

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (position) => _onPosition(position, runId),
      onError: (Object error, StackTrace stackTrace) =>
          _onStreamError(error, runId: runId),
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
      const Duration(milliseconds: 500),
      (_) => _predictGpsGap(),
    );
    _networkAssistTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _requestNetworkAssistIfNeeded(),
    );
    _armNoFixWatchdog();
    _armStallWatchdog();
  }

  Future<void> _logRuntimeProbe(int runId) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      final permission = await Geolocator.checkPermission();
      if (_disposed || runId != _runId) return;
      
    } catch (error) {
      if (_disposed || runId != _runId) return;
      
    }
  }


  Future<void> _emitLastKnownPosition(int runId) async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null || _disposed || runId != _runId || _gotFirstFix) return;

      final age = DateTime.now().difference(last.timestamp).inSeconds;
      if (age > 90 || !_isValidCoordinate(last.latitude, last.longitude))
        return;

      

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
        return;
      }
      final accuracy = quick.accuracy.isFinite && quick.accuracy > 0
          ? quick.accuracy
          : 100.0;
      if (accuracy > 1000) return;
      
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
      
    }
  }

  static const int _fallbackToRawManagerAfterAttempts = 1;
  bool _useRawLocationManager = false;

  void _onStreamError(
    Object error, {
    int? runId,
    bool isNoFixTimeout = false,
  }) {
    if (runId != null && runId != _runId) return;
    
    if (_disposed) return;
    _restartAttempts++;
    if (!_useRawLocationManager &&
        _restartAttempts >= _fallbackToRawManagerAfterAttempts) {
      _useRawLocationManager = true;
      
    }
    if (!_gotFirstFix &&
        !isNoFixTimeout &&
        _restartAttempts >= _unavailableAfterAttempts) {
      _setState(LocationState.unavailable);
    }
    final delaySec = math.min(1 << math.min(_restartAttempts, 4), 10);
    _restartTimer?.cancel();
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
    if (_disposed || runId != _runId) return;
    if (!_isValidCoordinate(p.latitude, p.longitude)) {
      
      return;
    }
    _lastRawCallbackAt = DateTime.now();
    final tsMs = p.timestamp.millisecondsSinceEpoch;
    if (_lastGpsMeasurementTsMs != null && tsMs <= _lastGpsMeasurementTsMs!) {
      final sinceAccepted = _lastGpsFixAt == null
          ? Duration.zero
          : DateTime.now().difference(_lastGpsFixAt!);
      if (sinceAccepted < const Duration(seconds: 4)) return;
      _lastGpsMeasurementTsMs = null;
      _lastAcceptedRawTsMs = null;
    }
    final previousLat = _lastAcceptedRawLat;
    final previousLng = _lastAcceptedRawLng;
    final previousTs = _lastAcceptedRawTsMs;
    if (_gotFirstFix &&
        p.accuracy.isFinite &&
        p.accuracy > _poorAccuracyM &&
        _lastGpsFixAt != null &&
        DateTime.now().difference(_lastGpsFixAt!) < _poorAccuracyGrace) {
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
        final speedForGate = math.max(previousSpeed, currentSpeed);
        final physicallyExpected = speedForGate * dtSec;
        final allowedJump = math.min(
          120.0,
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
          if (_consecutiveRejected < _rebaselineAfterRejected) return;
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
    _lastGpsFixAt = DateTime.now();
    if (_isPredictingGpsGap) {
      _isPredictingGpsGap = false;
      
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
    if (gap < _gpsGapBeforePrediction || gap > _maxGpsPredictionGap) return;
    final predicted = _jointKalman.predictOnly(now.millisecondsSinceEpoch);
    if (predicted == null || predicted.speedMs < 0.35) return;
    if (!_isPredictingGpsGap) {
      _isPredictingGpsGap = true;
      
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
        _networkAssistInFlight) {
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

  void stop() {
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
    _useRawLocationManager = false;
    _setState(LocationState.waiting);
  }

  void dispose() {
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
