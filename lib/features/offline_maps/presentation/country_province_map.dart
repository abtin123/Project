import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/map_catalog.dart';
import 'fi_province_paths.dart';
import 'fr_province_paths.dart';
import 'es_province_paths.dart';
import 'de_province_paths.dart';
import 'ro_province_paths.dart';
import 'hu_province_paths.dart';
import 'cz_province_paths.dart';
import 'gb_province_paths.dart';
import 'iran_province_map.dart';
import 'iran_province_paths.dart';
import 'armenia_province_paths.dart';
import 'iraq_province_paths.dart';
import 'map_download_providers.dart';
import 'th_province_paths.dart';
import 'ua_province_paths.dart';
import 'zoomable_map_view.dart';

/// Geometry + names for one country's province map.
class CountryProvinceSpec {
  const CountryProvinceSpec({
    required this.data,
    required this.labelPoints,
    required this.titleFa,
    required this.titleEn,
    this.rtl = false,
    this.labelMinZoom = 1,
    this.noLabelIds = const <String>{},
  });

  final List<IranProvincePathData> data;
  final Map<String, Offset> labelPoints;
  final String titleFa;
  final String titleEn;

  /// Province names are shown in the country's own language/script; false =
  /// left-to-right script (Thai, Latin, Cyrillic).
  final bool rtl;

  /// Dense maps hide labels until the user zooms in.
  final double labelMinZoom;

  /// Tiny enclaves that stay tappable but get no label.
  final Set<String> noLabelIds;
}

/// Countries that have a province map in the download screen (besides Iran,
/// Armenia and Iraq which have their own widgets). Keyed by ISO country code.
const Map<String, CountryProvinceSpec> kCountryProvinceSpecs =
    <String, CountryProvinceSpec>{
  'TH': CountryProvinceSpec(
    data: kThProvincePathData,
    labelPoints: kThLabelPoints,
    titleFa: 'نقشه استان‌های تایلند',
    titleEn: 'Thailand provinces map',
    labelMinZoom: 2.4,
  ),
  'FI': CountryProvinceSpec(
    data: kFiProvincePathData,
    labelPoints: kFiLabelPoints,
    titleFa: 'نقشه استان‌های فنلاند',
    titleEn: 'Finland regions map',
  ),
  'DE': CountryProvinceSpec(
    data: kDeProvincePathData,
    labelPoints: kDeLabelPoints,
    titleFa: 'نقشه ایالت‌های آلمان',
    titleEn: 'Germany states map',
  ),
  'ES': CountryProvinceSpec(
    data: kEsProvincePathData,
    labelPoints: kEsLabelPoints,
    titleFa: 'نقشه مناطق خودمختار اسپانیا',
    titleEn: 'Spain autonomous communities map',
  ),
  'FR': CountryProvinceSpec(
    data: kFrProvincePathData,
    labelPoints: kFrLabelPoints,
    titleFa: 'نقشه مناطق فرانسه',
    titleEn: 'France regions map',
  ),
  'CZ': CountryProvinceSpec(
    data: kCzProvincePathData,
    labelPoints: kCzLabelPoints,
    titleFa: 'نقشه کراج‌های چک',
    titleEn: 'Czechia regions map',
  ),
  'HU': CountryProvinceSpec(
    data: kHuProvincePathData,
    labelPoints: kHuLabelPoints,
    titleFa: 'نقشه استان‌های مجارستان',
    titleEn: 'Hungary counties map',
    labelMinZoom: 1.5,
    noLabelIds: kHuNoLabelIds,
  ),
  'RO': CountryProvinceSpec(
    data: kRoProvincePathData,
    labelPoints: kRoLabelPoints,
    titleFa: 'نقشه استان‌های رومانی',
    titleEn: 'Romania counties map',
    labelMinZoom: 2.2,
  ),
  'GB': CountryProvinceSpec(
    data: kGbProvincePathData,
    labelPoints: kGbLabelPoints,
    titleFa: 'نقشه مناطق بریتانیا',
    titleEn: 'United Kingdom regions map',
  ),
  'UA': CountryProvinceSpec(
    data: kUaProvincePathData,
    labelPoints: kUaLabelPoints,
    titleFa: 'نقشه استان‌های اوکراین',
    titleEn: 'Ukraine oblasts map',
  ),
};


/// Normalises a package code ("AM_AG") and a path id ("AM-AG") to one key.
String provinceKey(String id) => id.trim().toUpperCase().replaceAll('_', '-');

/// Province geometry for every country that has a province map (ISO code).
Map<String, List<IranProvincePathData>> get kProvinceDataByCountry =>
    <String, List<IranProvincePathData>>{
      'IR': kIranProvincePathData,
      'AM': kArmeniaProvincePathData,
      'IQ': kIraqProvincePathData,
      for (final e in kCountryProvinceSpecs.entries) e.key: e.value.data,
    };

/// Matches downloadable packages to map provinces (path id -> package).
/// Empty when the country is still one single package (no per-province split).
Map<String, MapRegion> matchProvinceRegions(
  List<IranProvincePathData> data,
  Iterable<MapRegion> regions,
) {
  final byKey = <String, MapRegion>{
    for (final r in regions)
      if (r.id != 'iran') provinceKey(r.id): r,
  };
  return <String, MapRegion>{
    for (final d in data)
      if (byKey[provinceKey(d.id)] != null) d.id: byKey[provinceKey(d.id)]!,
  };
}

/// Per-province colours: each province shows the state of its OWN package
/// (green = installed, blue = update, violet = downloading). When the country
/// is still a single package, every province mirrors that package.
Map<String, IranProvinceVisualState> buildProvinceStates({
  required WidgetRef ref,
  required List<IranProvincePathData> data,
  required List<MapRegion> regions,
  required Set<String> installedIds,
  required Set<String> updateIds,
  required String? selectedId,
  required bool showUpdates,
  required Color accent,
}) {
  final matched = matchProvinceRegions(data, regions);
  final packs = regions.where((r) => r.id != 'iran').toList();
  final allInstalled =
      packs.isNotEmpty && packs.every((r) => installedIds.contains(r.id));
  final anyUpdate = showUpdates && packs.any((r) => updateIds.contains(r.id));
  final states = <String, IranProvinceVisualState>{};
  for (final p in data) {
    if (matched.isNotEmpty) {
      final region = matched[p.id];
      states[p.id] = IranProvinceVisualState(
        installed: region != null && installedIds.contains(region.id),
        updatable:
            showUpdates && region != null && updateIds.contains(region.id),
        downloading: region != null &&
            ref.watch(regionDownloadControllerProvider(region)).downloading,
        selected: selectedId == p.id,
        accent: accent,
      );
    } else {
      states[p.id] = IranProvinceVisualState(
        installed: allInstalled,
        updatable: anyUpdate,
        downloading: false,
        selected: selectedId == p.id,
        accent: accent,
      );
    }
  }
  return states;
}

/// Province map for the map-download screen. Same painter, colours, zoom and
/// hit-testing as [IranProvinceMap]. A country is one download package, so
/// every province shows the state of that package (green = installed,
/// blue = update); tapping a province only highlights it.
class CountryProvinceMap extends ConsumerWidget {
  const CountryProvinceMap({
    super.key,
    required this.spec,
    required this.regions,
    required this.installedIds,
    required this.updateIds,
    required this.isEnglish,
    required this.selectedId,
    required this.onProvinceTap,
    this.showUpdates = true,
  });

  final CountryProvinceSpec spec;
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
      data: spec.data,
      regions: regions,
      installedIds: installedIds,
      updateIds: updateIds,
      selectedId: selectedId,
      showUpdates: showUpdates,
      accent: accent,
    );
    final labels = <String, String>{};
    for (final p in spec.data) {
      // native name, same in every app language
      labels[p.id] = spec.noLabelIds.contains(p.id) ? '' : p.nameFa;
    }

    return Semantics(
      label: isEnglish ? spec.titleEn : spec.titleFa,
      child: ZoomableMapView(
        onTapScene: (point, size) {
          final id = IranProvinceMapPainter.hitTestProvince(
            point,
            size,
            data: spec.data,
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
            data: spec.data,
            labelPoints: spec.labelPoints,
            labelMinZoom: spec.labelMinZoom,
            labelTextDirection: spec.rtl ? TextDirection.rtl : TextDirection.ltr,
          ),
        ),
      ),
    );
  }
}
