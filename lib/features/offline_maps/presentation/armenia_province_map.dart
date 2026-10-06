import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'armenia_province_paths.dart';
import 'country_province_map.dart' show buildProvinceStates;
import 'iran_province_map.dart';
import 'zoomable_map_view.dart';

/// Armenia province (marz) map for the map-download screen. Same painter,
/// colours, zoom, hit-testing and labels as [IranProvinceMap]; the geometry is
/// traced from the supplied Armenia template (assets/maps/armenia_provinces.svg).
///
/// Armenia is downloaded as one package, so every province shows the state of
/// that package (green = installed, blue = update). Tapping a province only
/// highlights it, like selecting a province on the Iran map.
class ArmeniaProvinceMap extends ConsumerWidget {
  const ArmeniaProvinceMap({
    super.key,
    required this.regions,
    required this.installedIds,
    required this.updateIds,
    required this.isEnglish,
    required this.selectedId,
    required this.onProvinceTap,
    this.showUpdates = true,
  });

  final List<MapRegion> regions;
  final Set<String> installedIds;
  final Set<String> updateIds;
  final bool isEnglish;
  final String? selectedId;
  final ValueChanged<String> onProvinceTap;
  final bool showUpdates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.primaryAccent(context);
    final states = buildProvinceStates(
      ref: ref,
      data: kArmeniaProvincePathData,
      regions: regions,
      installedIds: installedIds,
      updateIds: updateIds,
      selectedId: selectedId,
      showUpdates: showUpdates,
      accent: accent,
    );
    final labels = <String, String>{};
    for (final p in kArmeniaProvincePathData) {
      labels[p.id] = isEnglish ? (kArmeniaProvinceNamesEn[p.id] ?? p.nameFa) : p.nameFa;
    }

    return Semantics(
      label: isEnglish ? 'Armenia provinces map' : 'نقشه استان‌های ارمنستان',
      child: ZoomableMapView(
        onTapScene: (point, size) {
          final id = IranProvinceMapPainter.hitTestProvince(
            point,
            size,
            data: kArmeniaProvincePathData,
          );
          if (id != null) onProvinceTap(id);
        },
        builder: (context, size, zoom) => CustomPaint(
          size: size,
          painter: IranProvinceMapPainter(
            states: states,
            labels: labels,
            borderColor: const Color(0xFFC7DAFF),
            zoom: zoom,
            data: kArmeniaProvincePathData,
            labelPoints: kArmeniaLabelPoints,
          ),
        ),
      ),
    );
  }
}
