import 'dart:async';
import 'dart:math' as math;

import 'gps_fix.dart';
import 'kalman_filter.dart';
import 'native_location_source.dart';
import 'vehicle_position.dart';

export 'vehicle_position.dart';

enum LocationState { waiting, active, unavailable }

/// GPS-first location pipeline:
///  * GNSS fixes are the primary measurement (speed/bearing fused too).
///  * Network (Wi-Fi / cell tower) fixes seed the first position, bridge GNSS
///    outages and add weak information when GNSS accuracy is poor.
///  * Everything passes through [GpsKalmanFilter].
class LocationService {
  LocationService({NativeLocationSource? source})
      : _source = source ?? NativeLocationSource();

  final NativeLocationSource _source;
  final GpsKalmanFilter _kf = GpsKalmanFilter();
  final StreamController<VehiclePosition> _out =
      StreamController<VehiclePosition>.broadcast();
  final StreamController<LocationState> _stateCtl =
      StreamController<LocationState>.broadcast();

  LocationState _state = LocationState.waiting;
  StreamSubscription<dynamic>? _sub;
  Timer? _watchdog;
  bool _running = false;
  bool _navigation = false;
  bool _gpsProviderOn = true;
  bool _netProviderOn = true;

  DateTime? _lastAnyAt;
  DateTime? _lastGpsAt;
  DateTime _lastRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastGpsAcc = 9999;
  int _satUsed = 0;
  int _satVisible = 0;

  VehiclePosition? last;

  LocationState get state => _state;
  Stream<LocationState> get stateStream => _stateCtl.stream;
  Stream<VehiclePosition> get stream => _out.stream;
  int get satellitesUsed => _satUsed;
  int get satellitesVisible => _satVisible;

  void _setState(LocationState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  void start() {
    _running = true;
    _kf.navigationMode = _navigation;
    _sub ??= _source.events().listen(_onEvent, onError: (_) {});
    _watchdog ??= Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    unawaited(_begin());
  }

  Future<void> _begin() async {
    _lastRestartAt = DateTime.now();
    final ok = await _source.start(navigation: _navigation);
    if (!ok) {
      _setState(LocationState.unavailable);
    } else if (_state == LocationState.unavailable) {
      _setState(LocationState.waiting);
    }
  }

  void stop() {
    _running = false;
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_source.stop());
  }

  void ensureAlive({Duration maxAge = const Duration(seconds: 6)}) {
    if (!_running) {
      start();
      return;
    }
    final at = _lastAnyAt;
    if (at == null || DateTime.now().difference(at) > maxAge) {
      if (DateTime.now().difference(_lastRestartAt) > const Duration(seconds: 3)) {
        unawaited(_begin());
      }
    }
  }

  void setNavigationMode(bool value) {
    if (_navigation == value) return;
    _navigation = value;
    _kf.navigationMode = value;
    unawaited(_source.setNavigation(value));
  }

  void _tick() {
    if (!_running) return;
    final now = DateTime.now();
    final at = _lastAnyAt;
    if (at == null) return;
    final age = now.difference(at);
    if (age > const Duration(seconds: 15) && _state == LocationState.active) {
      _setState(LocationState.waiting);
    }
    final limit = _navigation ? const Duration(seconds: 10) : const Duration(seconds: 25);
    if (age > limit &&
        now.difference(_lastRestartAt) > const Duration(seconds: 10)) {
      unawaited(_begin());
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'fix':
        final f = RawFix.fromMap(event);
        if (f != null) _onFix(f);
        break;
      case 'gnss':
        _satUsed = (event['used'] as num?)?.toInt() ?? 0;
        _satVisible = (event['visible'] as num?)?.toInt() ?? 0;
        break;
      case 'provider':
        _gpsProviderOn = event['gps'] != false;
        _netProviderOn = event['network'] != false;
        if (!_gpsProviderOn && !_netProviderOn) {
          _setState(LocationState.unavailable);
        } else if (_state == LocationState.unavailable) {
          _setState(LocationState.waiting);
        }
        break;
    }
  }

  void _onFix(RawFix f) {
    if (f.accuracyM < 0) return;
    final now = DateTime.now();

    if (f.cached) {
      // System last-known position: only a coarse seed for the very first frame.
      if (_kf.initialized) return;
      final seed = RawFix(
        lat: f.lat,
        lng: f.lng,
        accuracyM: math.max(f.accuracyM, 100.0),
        elapsedMs: f.elapsedMs,
        source: FixSource.network,
      );
      _kf.update(seed);
      _emit(now, forceEstimated: true);
      return;
    }

    if (f.source == FixSource.network) {
      final gpsAge = _lastGpsAt == null ? null : now.difference(_lastGpsAt!);
      final gpsFresh = gpsAge != null &&
          gpsAge < (_navigation ? const Duration(seconds: 3) : const Duration(seconds: 5));
      if (gpsFresh && _lastGpsAcc <= 30) return; // GNSS is better
      if (gpsFresh && f.accuracyM >= _lastGpsAcc) return; // would not help
      if (_kf.initialized && f.accuracyM > 300) return;
      if (!_kf.initialized && f.accuracyM > 3000) return;
    } else {
      _lastGpsAt = now;
      _lastGpsAcc = f.accuracyM;
    }

    final accepted = _kf.update(f);
    _lastAnyAt = now;
    if (accepted) _emit(now);
  }

  void _emit(DateTime now, {bool forceEstimated = false}) {
    final e = _kf.estimate;
    if (e == null) return;
    final gpsAge = _lastGpsAt == null ? null : now.difference(_lastGpsAt!);
    final stale = gpsAge == null || gpsAge > const Duration(seconds: 3);
    final pos = VehiclePosition(
      lat: e.lat,
      lng: e.lng,
      headingDeg: e.headingDeg,
      speedKmh: e.speedMs * 3.6,
      accuracyM: e.accuracyM,
      isEstimated: forceEstimated || e.estimated || stale,
    );
    last = pos;
    _lastAnyAt = now;
    _setState(LocationState.active);
    if (!_out.isClosed) _out.add(pos);
  }

  void dispose() {
    _running = false;
    _watchdog?.cancel();
    _sub?.cancel();
    _sub = null;
    unawaited(_source.stop());
    _out.close();
    _stateCtl.close();
  }
}
