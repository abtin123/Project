import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'country_province_map.dart' show buildProvinceStates;
import 'iran_province_map.dart';
import 'iraq_province_paths.dart';
import 'zoomable_map_view.dart';

class IraqProvinceMap extends ConsumerWidget {
  const IraqProvinceMap({
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
      data: kIraqProvincePathData,
      regions: regions,
      installedIds: installedIds,
      updateIds: updateIds,
      selectedId: selectedId,
      showUpdates: showUpdates,
      accent: accent,
    );
    final labels = <String, String>{};
    for (final p in kIraqProvincePathData) {
      labels[p.id] = isEnglish ? (kIraqProvinceNamesEn[p.id] ?? p.nameFa) : p.nameFa;
    }

    return Semantics(
      label: isEnglish ? 'Iraq provinces map' : 'نقشه استان‌های عراق',
      child: ZoomableMapView(
        onTapScene: (point, size) {
          final id = IranProvinceMapPainter.hitTestProvince(
            point,
            size,
            data: kIraqProvincePathData,
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
            data: kIraqProvincePathData,
            labelPoints: kIraqLabelPoints,
          ),
        ),
      ),
    );
  }
}
