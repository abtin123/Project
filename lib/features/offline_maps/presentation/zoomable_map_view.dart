import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

/// نمای زوم‌پذیر مشترک برای همهٔ نقشه‌های صفحهٔ دانلود (ایران و سایر کشورها).
///
/// عمداً از InteractiveViewer استفاده نشده: ماتریس تبدیل (جابه‌جایی + مقیاس)
/// همین‌جا نگهداری می‌شود، پس دکمه‌های + / − / مرکز، pinch و کشیدن همگی یک
/// منبع حقیقت دارند و تبدیل مختصات لمس به مختصات نقشه دقیق است.
class ZoomableMapView extends StatefulWidget {
  const ZoomableMapView({
    super.key,
    required this.builder,
    this.onTapScene,
    this.maxZoom = 14,
  });

  /// محتوای نقشه؛ همیشه به اندازهٔ کادر ساخته می‌شود و خودِ این ویجت آن را
  /// scale/translate می‌کند. [zoom] برای ثابت‌نگه‌داشتن ضخامت خط و فونت است.
  final Widget Function(BuildContext context, Size size, double zoom) builder;

  /// نقطهٔ لمس‌شده در مختصات نقشه (قبل از زوم).
  final void Function(Offset scenePoint, Size size)? onTapScene;
  final double maxZoom;

  @override
  State<ZoomableMapView> createState() => _ZoomableMapViewState();
}

class _ZoomableMapViewState extends State<ZoomableMapView> {
  double _scale = 1;
  Offset _pan = Offset.zero;
  Size _size = Size.zero;

  double _startScale = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;

  Offset _clampPan(Offset p, double s) {
    final minX = _size.width - _size.width * s;
    final minY = _size.height - _size.height * s;
    return Offset(
      p.dx.clamp(math.min(minX, 0.0), 0.0).toDouble(),
      p.dy.clamp(math.min(minY, 0.0), 0.0).toDouble(),
    );
  }

  void _apply(double s, Offset pan) {
    setState(() {
      _scale = s;
      _pan = _clampPan(pan, s);
    });
  }

  void _zoomBy(double factor) {
    if (_size.isEmpty) return;
    final next = (_scale * factor).clamp(1.0, widget.maxZoom).toDouble();
    if ((next - _scale).abs() < 1e-6) return;
    final c = Offset(_size.width / 2, _size.height / 2);
    final scenePoint = (c - _pan) / _scale;
    _apply(next, c - scenePoint * next);
  }

  void _reset() => _apply(1, Offset.zero);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        final m = Matrix4.identity()
          ..translate(_pan.dx, _pan.dy)
          ..scale(_scale, _scale, 1.0);
        return Stack(
          children: [
            const Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: RadarBackdropPainter()),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (d) {
                  _startScale = _scale;
                  _startPan = _pan;
                  _startFocal = d.localFocalPoint;
                },
                onScaleUpdate: (d) {
                  final s = (_startScale * d.scale)
                      .clamp(1.0, widget.maxZoom)
                      .toDouble();
                  final sceneFocal = (_startFocal - _startPan) / _startScale;
                  _apply(s, d.localFocalPoint - sceneFocal * s);
                },
                onTapUp: widget.onTapScene == null
                    ? null
                    : (d) => widget.onTapScene!(
                          (d.localPosition - _pan) / _scale,
                          _size,
                        ),
                child: ClipRect(
                  child: Transform(
                    transform: m,
                    child: SizedBox(
                      width: _size.width,
                      height: _size.height,
                      child: widget.builder(context, _size, _scale),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 34,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ZoomButton(
                      icon: Icons.add_rounded, onTap: () => _zoomBy(1.6)),
                  const SizedBox(height: 8),
                  _ZoomButton(
                      icon: Icons.remove_rounded,
                      onTap: () => _zoomBy(1 / 1.6)),
                  const SizedBox(height: 8),
                  _ZoomButton(
                      icon: Icons.center_focus_strong_outlined, onTap: _reset),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF020D1D).withOpacity(.85),
          border: Border.all(color: const Color(0xFF2F5BFF), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF2F5BFF).withOpacity(.35), blurRadius: 10),
          ],
        ),
        child: AppIcon(icon, size: 24, color: Colors.white),
      ),
    );
  }
}

/// حلقه‌های رادار پشت نقشه (مطابق طرح).
class RadarBackdropPainter extends CustomPainter {
  const RadarBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .50, size.height * .52);
    const radii = <double>[.15, .305, .458, .605];
    const alphas = <double>[.55, .50, .45, .38];
    for (var i = 0; i < radii.length; i++) {
      canvas.drawCircle(
        center,
        size.width * radii[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = const Color(0xFF1F4FE0).withOpacity(alphas[i]),
      );
    }
  }

  @override
  bool shouldRepaint(covariant RadarBackdropPainter oldDelegate) => false;
}
