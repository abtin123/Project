import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nav_arrow_painter.dart';
import 'vehicle_provider.dart';

/// Used only by the main map. OnlineMapView is re-created (new ValueKey) when the
/// map style / reload key changes; without a GlobalKey that also destroyed the
/// native Filament view of the 3D car and built a new one each time.
/// With it Flutter moves the existing State and native renderer to the new map.
/// Do NOT use it twice at the same time (e.g. in the settings preview).
final GlobalKey mapCarMarkerKey = GlobalKey(debugLabel: 'map-car-marker');

const _yawCorrectionDegrees = <double>[0.0, 0.0, 0.0, 0.0];

double vehicleModelYawCorrectionDegrees(int modelIndex) {
  return _yawCorrectionDegrees[modelIndex.clamp(0, vehicleModels.length - 1)];
}

double vehicleScreenRotationDegrees(double headingDeg) {
  final normalized = headingDeg.isFinite ? headingDeg : 0.0;
  final value = normalized % 360.0;
  return value < 0 ? value + 360.0 : value;
}

// قرارداد دوربین مداری (مثل model-viewer): theta = زاویهٔ افقی، phi = از بالا.
double _orbitTheta(double screenHeadingDeg) =>
    (vehicleScreenRotationDegrees(screenHeadingDeg) + 180.0) % 360.0;

double _orbitPhi(double tiltDegrees) =>
    (tiltDegrees.isFinite ? tiltDegrees : 0.0).clamp(2.0, 78.0).toDouble();

/// پل Dart ↔ Filament بومی: Kotlin + Texture در Android و Objective-C++ + Metal در iOS.
class FilamentCarChannel {
  FilamentCarChannel._();
  static const MethodChannel _ch = MethodChannel('ir.abtin.abtinmaps/filament_car');

  /// رندر بومی Filament روی Android (Kotlin) و iOS (C++/Metal).
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<int?> create({
    required String asset,
    required int width,
    required int height,
    required double theta,
    required double phi,
  }) =>
      _ch.invokeMethod<int>('create', {
        'asset': asset,
        'width': width,
        'height': height,
        'theta': theta,
        'phi': phi,
      });

  static Future<void> update(int id, double theta, double phi) =>
      _ch.invokeMethod<void>('update', {'id': id, 'theta': theta, 'phi': phi});

  static Future<void> resize(int id, int width, int height) =>
      _ch.invokeMethod<void>('resize', {'id': id, 'width': width, 'height': height});

  static Future<void> setModel(int id, String asset) =>
      _ch.invokeMethod<void>('model', {'id': id, 'asset': asset});

  static Future<void> dispose(int id) => _ch.invokeMethod<void>('dispose', {'id': id});

  static Future<String?> status() => _ch.invokeMethod<String>('status');

  static Future<bool> viewReady(int id) async {
    try {
      return await _ch.invokeMethod<bool>('viewReady', {'id': id}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<String> viewState(int id) async {
    try {
      return await _ch.invokeMethod<String>('viewState', {'id': id}) ?? 'failed';
    } on PlatformException {
      return 'failed';
    } on MissingPluginException {
      return 'failed';
    }
  }
}

class CarMarker3D extends StatefulWidget {
  const CarMarker3D({
    super.key,
    required this.size,
    required this.modelIndex,
    this.headingDeg = 0,
    this.cameraAngleDegrees = 0,
    this.sizePercent = 80,
    this.interactive = false,
  });

  final double size;
  final int modelIndex;
  final double headingDeg;
  final double cameraAngleDegrees;
  final double sizePercent;
  final bool interactive;

  @override
  State<CarMarker3D> createState() => _CarMarker3DState();
}

class _CarMarker3DState extends State<CarMarker3D> {
  int? _textureId;
  int? _iosViewId;
  String? _iosAssetPath;
  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool _creating = false;
  bool _failed = false;
  bool _disposed = false;
  int _texW = 0;
  double _devicePixelRatio = 1.0;

  // آخرین زاویه‌ای که واقعاً به Filament فرستاده شده.
  double? _sentTheta;
  double? _sentPhi;

  // رندر Filament «به‌ازای تغییر» است؛ برای اینکه جیتر ۱ درجه‌ای GPS فریم الکی نسازد،
  // فقط با تغییر واقعی زاویه و حداکثر ~۱۵ بار در ثانیه می‌فرستیم.
  static const Duration _minPushGap = Duration(milliseconds: 66);
  static const double _minThetaStepDeg = 1.5;
  static const double _minPhiStepDeg = 1.0;
  DateTime _lastPushAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingPush;

  static const int _maxTexturePx = 768;

  double get _visualScale => widget.sizePercent.clamp(45.0, 150.0) / 100.0;

  /// برای اینکه با بزرگ‌نمایی (تا ۱۵۰٪) تصویر کدر نشود، بافت را به اندازهٔ بزرگ‌ترین حالت می‌سازیم.
  double get _renderScale => math.max(1.0, _visualScale);

  int get _wantedPx =>
      (widget.size * _devicePixelRatio * _renderScale).round().clamp(32, _maxTexturePx);

  @override
  void initState() {
    super.initState();
    if (!FilamentCarChannel.supported) _failed = true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    if (!kIsWeb && Platform.isAndroid && _textureId == null && !_creating && !_failed) {
      unawaited(_create());
    } else {
      _maybeResize();
    }
  }

  Future<void> _create() async {
    _creating = true;
    final idx = widget.modelIndex.clamp(0, vehicleModels.length - 1);
    final px = _wantedPx;
    final theta = _orbitTheta(widget.headingDeg);
    final phi = _orbitPhi(widget.cameraAngleDegrees);
    try {
      var selectedAsset = vehicleModels[idx];
      final id = await FilamentCarChannel.create(
        asset: selectedAsset,
        width: px,
        height: px,
        theta: theta,
        phi: phi,
      );
      if (id == null) throw StateError('native create returned null');
      if (_disposed) {
        unawaited(FilamentCarChannel.dispose(id));
        return;
      }
      // The selected model can change while the native surface and engine are being created.
      // Apply the latest choice before exposing the texture, and repeat if it changes mid-call.
      while (!_disposed && mounted) {
        final latest = vehicleModels[widget.modelIndex.clamp(0, vehicleModels.length - 1)];
        if (latest == selectedAsset) break;
        await FilamentCarChannel.setModel(id, latest);
        selectedAsset = latest;
      }
      if (_disposed || !mounted) {
        unawaited(FilamentCarChannel.dispose(id));
        return;
      }
      _texW = px;
      _sentTheta = theta;
      _sentPhi = phi;

setState(() => _textureId = id);
      unawaited(_verifyAndroidRenderer(id));
      _push(); // اگر در حین ساخت چیزی عوض شده بود
    } catch (e) {
      // موتور بالا نیامد (مثلاً GPU/ABI پشتیبانی نمی‌شود): با فلش جهت‌نما ادامه بده.

if (mounted) setState(() => _failed = true);
    } finally {
      _creating = false;
    }
  }

  void _maybeResize() {
    if (_isIOS) return; // UIKit PlatformView resizes its CAMetalLayer in layoutSubviews.
    final id = _textureId;
    if (id == null) return;
    final px = _wantedPx;
    if (px != _texW) {
      _texW = px;
      FilamentCarChannel.resize(id, px, px).catchError((_) {});
    }
  }

  void _push() {
    if (_disposed) return;
    final id = _isIOS ? _iosViewId : _textureId;
    if (id == null) return;
    final theta = _orbitTheta(widget.headingDeg);
    final phi = _orbitPhi(widget.cameraAngleDegrees);
    final lastTheta = _sentTheta;
    final lastPhi = _sentPhi;
    if (lastTheta != null && lastPhi != null) {
      var dTheta = (theta - lastTheta).abs() % 360.0;
      if (dTheta > 180.0) dTheta = 360.0 - dTheta;
      final dPhi = (phi - lastPhi).abs();
      if (dTheta < _minThetaStepDeg && dPhi < _minPhiStepDeg) return;
    }
    final since = DateTime.now().difference(_lastPushAt);
    if (since < _minPushGap) {
      _pendingPush ??= Timer(_minPushGap - since, () {
        _pendingPush = null;
        if (mounted) _push();
      });
      return;
    }
    _lastPushAt = DateTime.now();
    _sentTheta = theta;
    _sentPhi = phi;
    FilamentCarChannel.update(id, theta, phi).catchError((_) {});
  }

  @override
  void didUpdateWidget(CarMarker3D old) {
    super.didUpdateWidget(old);
    final id = _isIOS ? _iosViewId : _textureId;
    if (id != null && old.modelIndex != widget.modelIndex) {
      final idx = widget.modelIndex.clamp(0, vehicleModels.length - 1);
      final nextAsset = vehicleModels[idx];
      if (!_isIOS || _iosAssetPath != nextAsset) {
        FilamentCarChannel.setModel(id, nextAsset).catchError((_) {});
        if (_isIOS) _iosAssetPath = nextAsset;
      }
    }
    _maybeResize();
    _push();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingPush?.cancel();
    _pendingPush = null;
    final id = _isIOS ? _iosViewId : _textureId;
    _textureId = null;
    _iosViewId = null;
    _iosAssetPath = null;
    if (id != null) {
      FilamentCarChannel.dispose(id).catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _verifyAndroidRenderer(int id) async {
    final ready = await FilamentCarChannel.viewReady(id);
    if (_disposed || !mounted || _textureId != id) return;
    if (!ready) {
      _failAndroidRenderer(id, 'Android Filament renderer or bundled GLB failed to initialize');
      return;
    }
    for (var attempt = 0; attempt < 60; attempt++) {
      final state = await FilamentCarChannel.viewState(id);
      if (_disposed || !mounted || _textureId != id) return;
      if (state == 'ready') {

return;
      }
      if (state == 'failed') {
        _failAndroidRenderer(id, 'Android GLB resource loading failed');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _failAndroidRenderer(id, 'Android GLB loading timed out');
  }

  void _failAndroidRenderer(int id, String reason) {
    if (_disposed || !mounted || _textureId != id) return;
    _textureId = null;
    _texW = 0;
    unawaited(FilamentCarChannel.dispose(id));
    setState(() => _failed = true);
  }

  void _onIOSPlatformViewCreated(int id, String initialAsset) {
    if (_disposed) {
      unawaited(FilamentCarChannel.dispose(id));
      return;
    }
    _iosViewId = id;
    _iosAssetPath = initialAsset;
    unawaited(_verifyIOSRenderer(id));
    final currentIndex = widget.modelIndex.clamp(0, vehicleModels.length - 1);
    final currentAsset = vehicleModels[currentIndex];
    if (currentAsset != initialAsset) {
      _iosAssetPath = currentAsset;
      unawaited(FilamentCarChannel.setModel(id, currentAsset));
    }
    // Send the latest state after native creation; widget inputs may have changed
    // while the iOS PlatformView was being constructed.
    _sentTheta = null;
    _sentPhi = null;
    _push();
  }

  Future<void> _verifyIOSRenderer(int id) async {
    final ready = await FilamentCarChannel.viewReady(id);
    if (_disposed || !mounted || _iosViewId != id) return;
    if (!ready) {
      _failIOSRenderer(id, 'Metal renderer or bundled GLB failed to initialize');
      return;
    }

// Follow the asynchronous gltfio load until it is ready or reports a failure.
    for (var attempt = 0; attempt < 60; attempt++) {
      final state = await FilamentCarChannel.viewState(id);
      if (_disposed || !mounted || _iosViewId != id) return;
      if (state == 'ready') {

return;
      }
      if (state == 'failed') {
        _failIOSRenderer(id, 'iOS GLB resource loading failed');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _failIOSRenderer(id, 'iOS GLB loading timed out');
  }

  void _failIOSRenderer(int id, String reason) {
    if (_disposed || !mounted || _iosViewId != id) return;
    _iosViewId = null;
    _iosAssetPath = null;
    unawaited(FilamentCarChannel.dispose(id));
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    if (_isIOS && !_failed) {
      final idx = widget.modelIndex.clamp(0, vehicleModels.length - 1);
      return SizedBox.square(
        dimension: widget.size,
        child: IgnorePointer(
          ignoring: !widget.interactive,
          child: Transform.scale(
            scale: _visualScale,
            child: UiKitView(
              viewType: 'abtin/filament_car',
              creationParams: {
                'asset': vehicleModels[idx],
                'theta': _orbitTheta(widget.headingDeg),
                'phi': _orbitPhi(widget.cameraAngleDegrees),
              },
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: (id) => _onIOSPlatformViewCreated(id, vehicleModels[idx]),
            ),
          ),
        ),
      );
    }
    final Widget content;
    if (_failed) {
      content = Transform.rotate(
        angle: vehicleScreenRotationDegrees(widget.headingDeg) * math.pi / 180,
        child: NavArrow(size: widget.size * 0.8),
      );
    } else if (id == null) {
      content = const SizedBox.shrink();
    } else {
      // بافت به اندازهٔ renderScale ساخته شده؛ نمایش با visualScale/renderScale.
      final shown = widget.size * _renderScale;
      content = Transform.scale(
        scale: _visualScale / _renderScale,
        alignment: Alignment.center,
        child: OverflowBox(
          minWidth: shown,
          maxWidth: shown,
          minHeight: shown,
          maxHeight: shown,
          child: SizedBox.square(
            dimension: shown,
            child: Texture(textureId: id, filterQuality: FilterQuality.medium),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: widget.size,
      child: IgnorePointer(ignoring: !widget.interactive, child: content),
    );
  }
}
