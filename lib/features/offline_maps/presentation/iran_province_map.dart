import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'iran_province_paths.dart';
import 'map_download_providers.dart';
import 'offline_maps_providers.dart';
import 'zoomable_map_view.dart';

class IranProvinceMap extends ConsumerWidget {
  const IranProvinceMap({
    super.key,
    required this.regions,
    required this.isEnglish,
    required this.onProvinceTap,
    this.selectedId,
    this.showUpdates = true,
  });

  final List<MapRegion> regions;
  final bool isEnglish;
  final Future<void> Function(MapRegion region) onProvinceTap;
  final String? selectedId;

  final bool showUpdates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed =
        ref.watch(abmInstalledMapIdsProvider).valueOrNull ?? const <String>{};
    final accent = AppColors.primaryAccent(context);
    final updatableIds =
        ref.watch(updatableMapIdsProvider).valueOrNull ?? const <String>{};
    final regionById = <String, MapRegion>{
      for (final region in regions)
        if (region.id != 'iran') region.id: region,
    };

    final states = <String, IranProvinceVisualState>{};
    final labels = <String, String>{};
    for (final path in kIranProvincePathData) {
      final region = regionById[path.id];
      final downloading = region == null
          ? false
          : ref.watch(regionDownloadControllerProvider(region)).downloading;
      states[path.id] = IranProvinceVisualState(
        installed: installed.contains(path.id),
        updatable: showUpdates && updatableIds.contains(path.id),
        downloading: downloading,
        selected: selectedId == path.id,
        accent: accent,
      );
      labels[path.id] = region != null
          ? region.displayRegionName(isEnglish)
          : path.nameFa;
    }

    return Semantics(
      label: isEnglish ? 'Iran provinces map' : 'نقشه استان‌های ایران',
      child: ZoomableMapView(
        onTapScene: (point, size) async {
          final id = IranProvinceMapPainter.hitTestProvince(point, size);
          if (id == null) return;
          final region = regionById[id];
          if (region == null) return;
          await onProvinceTap(region);
        },
        builder: (context, size, zoom) => CustomPaint(
          size: size,
          painter: IranProvinceMapPainter(
            states: states,
            labels: labels,
            borderColor: const Color(0xFFC7DAFF),
            zoom: zoom,
          ),
        ),
      ),
    );
  }
}

class IranProvinceVisualState {
  const IranProvinceVisualState({
    required this.installed,
    required this.updatable,
    required this.downloading,
    required this.selected,
    required this.accent,
  });

  final bool installed;
  final bool updatable;
  final bool downloading;
  final bool selected;
  final Color accent;
}

class IranProvinceMapPainter extends CustomPainter {
  IranProvinceMapPainter({
    required this.states,
    required this.borderColor,
    this.labels = const <String, String>{},
    this.zoom = 1,
    this.data = kIranProvincePathData,
    this.labelPoints = const <String, Offset>{},
    this.labelMinZoom = 1,
    this.labelTextDirection = TextDirection.rtl,
  });

  final TextDirection labelTextDirection;

  final double labelMinZoom;

  final List<IranProvincePathData> data;

  final Map<String, Offset> labelPoints;

  final Map<String, String> labels;

  final double zoom;

  final Map<String, IranProvinceVisualState> states;
  final Color borderColor;

  static final Map<List<IranProvincePathData>, _Geometry> _geoCache =
      Map<List<IranProvincePathData>, _Geometry>.identity();
  static _Geometry _geometry(List<IranProvincePathData> data) =>
      _geoCache.putIfAbsent(data, () {
        final paths = <String, Path>{
          for (final d in data) d.id: parseSvgPath(d.d),
        };
        Rect? r;
        for (final path in paths.values) {
          final b = path.getBounds();
          r = r == null ? b : r.expandToInclude(b);
        }
        return _Geometry(paths, r!.inflate(3));
      });

  static Path parseSvgPath(String d) {
    final path = Path();
    final tokens =
        RegExp(r'[MmLlHhVvCcSsZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
            .allMatches(d)
            .map((m) => m.group(0)!)
            .toList();
    var i = 0;
    var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
    double? lcx, lcy; // last cubic control point (for S)
    var cmd = '';
    double n() => double.parse(tokens[i++]);
    bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);

    while (i < tokens.length) {
      if (isCmd(tokens[i])) cmd = tokens[i++];
      switch (cmd) {
        case 'M':
        case 'm':
          var x = n(), y = n();
          if (cmd == 'm') {
            x += cx;
            y += cy;
          }
          path.moveTo(x, y);
          cx = sx = x;
          cy = sy = y;
          lcx = lcy = null;
          cmd = cmd == 'M' ? 'L' : 'l';
          break;
        case 'L':
        case 'l':
          var x = n(), y = n();
          if (cmd == 'l') {
            x += cx;
            y += cy;
          }
          path.lineTo(x, y);
          cx = x;
          cy = y;
          lcx = lcy = null;
          break;
        case 'H':
        case 'h':
          var x = n();
          if (cmd == 'h') x += cx;
          path.lineTo(x, cy);
          cx = x;
          lcx = lcy = null;
          break;
        case 'V':
        case 'v':
          var y = n();
          if (cmd == 'v') y += cy;
          path.lineTo(cx, y);
          cy = y;
          lcx = lcy = null;
          break;
        case 'C':
        case 'c':
          var x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n();
          if (cmd == 'c') {
            x1 += cx;
            y1 += cy;
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          path.cubicTo(x1, y1, x2, y2, x, y);
          lcx = x2;
          lcy = y2;
          cx = x;
          cy = y;
          break;
        case 'S':
        case 's':
          var x2 = n(), y2 = n(), x = n(), y = n();
          if (cmd == 's') {
            x2 += cx;
            y2 += cy;
            x += cx;
            y += cy;
          }
          final x1 = lcx == null ? cx : 2 * cx - lcx;
          final y1 = lcy == null ? cy : 2 * cy - lcy;
          path.cubicTo(x1, y1, x2, y2, x, y);
          lcx = x2;
          lcy = y2;
          cx = x;
          cy = y;
          break;
        case 'Z':
        case 'z':
          path.close();
          cx = sx;
          cy = sy;
          lcx = lcy = null;
          break;
        default:
          return path;
      }
    }
    return path;
  }

  static _MapTransform _transformFor(Size size, Rect viewBox) {
    final scale =
        math.min(size.width / viewBox.width, size.height / viewBox.height);
    return _MapTransform(
      scale: scale,
      dx: (size.width - viewBox.width * scale) / 2 - viewBox.left * scale,
      dy: (size.height - viewBox.height * scale) / 2 - viewBox.top * scale,
    );
  }

  static String? hitTestProvince(
    Offset point,
    Size size, {
    List<IranProvincePathData> data = kIranProvincePathData,
  }) {
    final geo = _geometry(data);
    final t = _transformFor(size, geo.viewBox);
    final p = Offset((point.dx - t.dx) / t.scale, (point.dy - t.dy) / t.scale);
    for (final d in data.reversed) {
      if (geo.paths[d.id]!.contains(p)) return d.id;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _geometry(data);
    final t = _transformFor(size, geo.viewBox);
    canvas.save();
    canvas.translate(t.dx, t.dy);
    canvas.scale(t.scale);

    for (final item in data) {
      final path = geo.paths[item.id]!;
      final state = states[item.id];
      final paint = Paint()..style = PaintingStyle.fill;
      if (state?.downloading == true) {
        paint.shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF16B88A), Color(0xFF4DE39A)],
        ).createShader(path.getBounds());
      } else if (state?.selected == true) {
        paint.shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3A3AFF), Color(0xFF2547F5)],
        ).createShader(path.getBounds());
      } else {
        paint.color = _fillFor(state);
      }
      canvas.drawPath(path, paint);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF16294D).withOpacity(.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9 / zoom
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
    _paintLabels(canvas, size, t, geo);
  }

  void _paintLabels(
      Canvas canvas, Size size, _MapTransform t, _Geometry geo) {
    if (zoom < labelMinZoom) return;
    for (final item in data) {
      final name = labels[item.id] ?? item.nameFa;
      final bounds = geo.paths[item.id]!.getBounds();
      final fontPx = 9.5 / zoom;
      final available = bounds.width * t.scale;
      final state = states[item.id];
      final onColor = (state?.selected == true ||
              state?.installed == true ||
              state?.updatable == true ||
              state?.downloading == true)
          ? Colors.white
          : const Color(0xFF16294D);
      final tp = TextPainter(
        text: TextSpan(
          text: name,
          style: TextStyle(
            color: onColor,
            fontSize: fontPx,
            fontWeight: FontWeight.w900,
            height: 1.15,
            fontFamily: 'Vazirmatn',
          ),
        ),
        textDirection: labelTextDirection,
        textAlign: TextAlign.center,
        maxLines: 2,
      )..layout(maxWidth: math.max(available, 58 / zoom));
      final c = labelPoints[item.id] ?? bounds.center;
      final pos = Offset(c.dx * t.scale + t.dx, c.dy * t.scale + t.dy);
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  Color _fillFor(IranProvinceVisualState? state) {
    if (state == null) return const Color(0xFFF5F7FB);
    if (state.downloading) return state.accent;
    if (state.updatable) return const Color(0xFF2E9BFF);
    if (state.installed) return const Color(0xFF18B88A);
    return const Color(0xFFF5F7FB);
  }

  @override
  bool shouldRepaint(covariant IranProvinceMapPainter oldDelegate) => true;
}

class _Geometry {
  const _Geometry(this.paths, this.viewBox);
  final Map<String, Path> paths;
  final Rect viewBox;
}

class _MapTransform {
  const _MapTransform({required this.scale, required this.dx, required this.dy});
  final double scale;
  final double dx;
  final double dy;
}
