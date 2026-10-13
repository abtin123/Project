
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'vehicle_provider.dart';

const _yawCorrectionDegrees = <double>[0.0, 0.0, 0.0, 0.0];

double vehicleModelYawCorrectionDegrees(int modelIndex) {
  return _yawCorrectionDegrees[modelIndex.clamp(0, vehicleModels.length - 1)];
}

double vehicleScreenRotationDegrees(double headingDeg) {
  final normalized = headingDeg.isFinite ? headingDeg : 0.0;
  final value = normalized % 360.0;
  return value < 0 ? value + 360.0 : value;
}

double _orbitTheta(double screenHeadingDeg) =>
    (vehicleScreenRotationDegrees(screenHeadingDeg) + 180.0) % 360.0;

double _orbitPhi(double tiltDegrees) =>
    (tiltDegrees.isFinite ? tiltDegrees : 0.0).clamp(2.0, 78.0).toDouble();

const _carJs = r'''
window.__carApply = function () {
  var m = document.querySelector('model-viewer');
  if (!m || !window.__carLast) return false;
  m.cameraOrbit = window.__carLast;
  if (m.jumpCameraToGoal) m.jumpCameraToGoal();
  return true;
};
window.__carSet = function (theta, phi) {
  window.__carLast = theta + 'deg ' + phi + 'deg auto';
  return window.__carApply();
};
''';



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
  WebViewController? _controller;
  String? _lastSent;
  late String _initialOrbit;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initialOrbit = _orbit();
  }

  String _orbit() =>
      '${_orbitTheta(widget.headingDeg).toStringAsFixed(1)}deg '
      '${_orbitPhi(widget.cameraAngleDegrees).toStringAsFixed(1)}deg auto';

  void _push() {
    final c = _controller;
    if (c == null) return;
    final theta = _orbitTheta(widget.headingDeg).toStringAsFixed(1);
    final phi = _orbitPhi(widget.cameraAngleDegrees).toStringAsFixed(1);
    final sig = '$theta/$phi';
    if (sig != _lastSent) {
      _lastSent = sig;
      c.runJavaScript(
        "if(window.__carSet)window.__carSet('$theta','$phi');",
      ).catchError((_) {});
    }
  }

  @override
  void didUpdateWidget(CarMarker3D old) {
    super.didUpdateWidget(old);
    if (old.modelIndex != widget.modelIndex) {
      _controller = null;
      _lastSent = null;
      _generation++;
    }
    _push();
  }

  @override
  Widget build(BuildContext context) {
    final safeIndex = widget.modelIndex.clamp(0, vehicleModels.length - 1);
    final key = ValueKey<String>('car-$safeIndex-$_generation');
    final viewer = ModelViewer(
      key: key,
      src: vehicleModels[safeIndex],
      alt: 'Vehicle',
      backgroundColor: Colors.transparent,
      cameraOrbit: _initialOrbit,
      minCameraOrbit: 'auto 0deg auto',
      maxCameraOrbit: 'auto 180deg auto',
      cameraControls: widget.interactive,
      disableZoom: !widget.interactive,
      disablePan: true,
      autoRotate: false,
      ar: false,
      loading: Loading.lazy,
      reveal: Reveal.auto,
      shadowIntensity: 0.6,
      shadowSoftness: 1,
      exposure: 1.1,
      interactionPrompt: InteractionPrompt.none,
      relatedJs: _carJs,
      onWebViewCreated: (c) {
        _controller = c;
        _lastSent = null;
        _push();
      },
    );

    final visualScale = (widget.sizePercent.clamp(45.0, 150.0) / 100.0);
    return SizedBox.square(
      dimension: widget.size,
      child: IgnorePointer(
        ignoring: !widget.interactive,
        child: Transform.scale(
          scale: visualScale,
          alignment: Alignment.center,
          child: viewer,
        ),
      ),
    );
  }
}
