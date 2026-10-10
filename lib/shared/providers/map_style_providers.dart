import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/data/settings_repository.dart';
import '../../features/settings/presentation/settings_repository_provider.dart';
import '../../features/settings/presentation/appearance_settings_providers.dart';
import 'app_settings_providers.dart';
import 'abtinmap_providers.dart';
import '../../features/routing/data/routing_provider.dart';
import '../../abtinmap/abm_style_assets.dart';

Map<String, String> _paletteHexes(OfflineMapPalette p) => {
  'background': '#${(p.background.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'water': '#${(p.water.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'green': '#${(p.green.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'urban': '#${(p.urban.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'building': '#${(p.building.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadOutline': '#${(p.roadOutline.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadMotorway': '#${(p.roadMotorway.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadTrunk': '#${(p.roadTrunk.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadPrimary': '#${(p.roadPrimary.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadSecondary': '#${(p.roadSecondary.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'roadLocal': '#${(p.roadLocal.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'label': '#${(p.label.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'halo': '#${(p.halo.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  'poi': '#${(p.poi.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
};

String _colorHex(Color c) =>
    '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

@immutable
class ResolvedMapStyle {
  const ResolvedMapStyle({required this.path, required this.offline});
  final String path;
  final bool offline;
}

final resolvedMapStyleFileProvider = FutureProvider<ResolvedMapStyle>((ref) async {
  final dark = ref.watch(mapStyleModeProvider) == MapStyleMode.night;
  final palette = ref.watch(currentOfflineMapPaletteProvider);
  final appearance = ref.watch(appearanceSettingsProvider);
  final requestedOffline =
      ref.watch(routingEngineProvider) != RoutingEngine.online;
  final sources = requestedOffline
      ? await ref.watch(installedOfflineMapSourcesProvider.future)
      : const <OfflineMapSource>[];

  var offlineReady = false;
  final mbtilesPaths = <String>[];
  for (final source in sources) {
    try {
      final artifacts = await ref.read(vectorMapServiceProvider).prepare(
            containerFile: source.file,
            id: source.id,
          );
      if (await artifacts.mbtilesFile.exists() &&
          await artifacts.mbtilesFile.length() > 0) {
        mbtilesPaths.add(artifacts.mbtilesFile.path);
      } else {
        throw StateError('ABM ${source.id} has no map.mbtiles.');
      }
    } catch (error, stack) {
    }
  }
  offlineReady = mbtilesPaths.isNotEmpty;
  final String? mbtilesPath = offlineReady ? mbtilesPaths.first : null;

  final path = await AbmStyleAssets.instance.resolve(
    dark: dark,
    colors: _paletteHexes(palette),
    roadWidths: palette.roadWidths,
    roadZoomWidths: palette.roadZoomWidthsByName,
    roadDirectionArrowColorHex: _colorHex(appearance.roadDirectionArrowColor),
    roadDirectionArrowSizePercent: appearance.roadDirectionArrowSizePercent,
    offline: offlineReady,
    mbtilesPath: mbtilesPath,
    mbtilesPaths: mbtilesPaths,
  );
  return ResolvedMapStyle(path: path, offline: offlineReady);
});

enum MapStyleMode { day, night }

enum MapPalettePreset {
  kartaDay,
  sandstoneDay,
  kartaNight,
  midnightNight,
}

enum OfflinePaletteField {
  background,
  water,
  green,
  urban,
  building,
  roadOutline,
  roadMotorway,
  roadTrunk,
  roadPrimary,
  roadSecondary,
  roadLocal,
  label,
  halo,
  poi,
}

const String kOfflineOnlyStyleMarker = 'offline-only';
const String kOnlineDayStyleMarker = 'online-day';
const String kOnlineNightStyleMarker = 'online-night';

final mapStyleModeProvider =
    StateProvider<MapStyleMode>((ref) => MapStyleMode.night);

final currentMapStyleProvider = Provider<String>((ref) {
  ref.watch(mapPerspectiveProvider);
  final engine = ref.watch(routingEngineProvider);
  if (engine != RoutingEngine.online) return kOfflineOnlyStyleMarker;
  return ref.watch(mapStyleModeProvider) == MapStyleMode.night
      ? kOnlineNightStyleMarker
      : kOnlineDayStyleMarker;
});

final resolvedMapStyleProvider = FutureProvider<String>(
  (ref) async => ref.watch(currentMapStyleProvider),
);

const double kRouteNeonGlowIntensity = 0.7;

const List<String> kNeonRouteColorHexes = [
  '#00E5FF',
  '#2D8CFF',
  '#A855FF',
  '#FF3DDB',
  '#39FF88',
  '#FFE600',
  '#FF9500',
  '#FF3B5C',
];

const List<String> kRouteColorHexes = [
  '#2FE6C4',
  '#2F80ED',
  '#9B51E0',
  '#F2994A',
  '#EB5757',
  '#E0459A',
];

final routeWidthProvider =
    Provider<double>((ref) => ref.watch(appearanceSettingsProvider).routeWidth);

enum RoadWidthClass { motorway, trunk, primary, secondary, local }

const double kRoadWidthMin = 0.4;
const double kRoadWidthMax = 2.5;

const int kRoadZoomMin = 10;
const int kRoadZoomMax = 20;

const List<(int, int)> kRoadZoomBands = <(int, int)>[
  (10, 13),
  (14, 17),
  (18, 20),
];

(int, int) roadZoomBandOf(int zoom) {
  final z = zoom.clamp(kRoadZoomMin, kRoadZoomMax);
  return kRoadZoomBands.firstWhere((b) => z >= b.$1 && z <= b.$2);
}

@immutable
class OfflineMapPalette {
  const OfflineMapPalette({
    required this.background,
    required this.water,
    required this.green,
    required this.urban,
    required this.building,
    required this.roadOutline,
    required this.roadMotorway,
    required this.roadTrunk,
    required this.roadPrimary,
    required this.roadSecondary,
    required this.roadLocal,
    required this.label,
    required this.halo,
    required this.poi,
    this.roadWidthMotorway = 1.0,
    this.roadWidthTrunk = 1.0,
    this.roadWidthPrimary = 1.0,
    this.roadWidthSecondary = 1.0,
    this.roadWidthLocal = 1.0,
    this.roadZoomWidths = const <int, Map<RoadWidthClass, double>>{},
  });

  final Color background;
  final Color water;
  final Color green;
  final Color urban;
  final Color building;
  final Color roadOutline;

  final Color roadMotorway;
  final Color roadTrunk;
  final Color roadPrimary;
  final Color roadSecondary;
  final Color roadLocal;
  final Color label;
  final Color halo;
  final Color poi;

  final double roadWidthMotorway;
  final double roadWidthTrunk;
  final double roadWidthPrimary;
  final double roadWidthSecondary;
  final double roadWidthLocal;

  final Map<int, Map<RoadWidthClass, double>> roadZoomWidths;

  double roadWidthAt(RoadWidthClass c, int zoom) {
    final band = roadZoomBandOf(zoom);
    return roadZoomWidths[band.$1]?[c] ?? roadWidthOf(c);
  }

  bool hasRoadZoomOverride(int zoom) {
    final band = roadZoomBandOf(zoom);
    return roadZoomWidths[band.$1]?.isNotEmpty ?? false;
  }

  OfflineMapPalette withRoadWidthAtZoom(
      RoadWidthClass c, int zoom, double value) {
    final v = value.clamp(kRoadWidthMin, kRoadWidthMax).toDouble();
    final band = roadZoomBandOf(zoom);
    final next = <int, Map<RoadWidthClass, double>>{
      for (final e in roadZoomWidths.entries)
        e.key: Map<RoadWidthClass, double>.from(e.value),
    };
    final row = Map<RoadWidthClass, double>.from(
        next[band.$1] ?? <RoadWidthClass, double>{
          for (final k in RoadWidthClass.values) k: roadWidthAt(k, band.$1),
        });
    row[c] = v;
    for (var z = band.$1; z <= band.$2; z++) {
      next[z] = Map<RoadWidthClass, double>.from(row);
    }
    return copyWith(roadZoomWidths: next);
  }

  OfflineMapPalette withoutRoadZoom(int zoom) {
    final band = roadZoomBandOf(zoom);
    final next = <int, Map<RoadWidthClass, double>>{
      for (final e in roadZoomWidths.entries)
        if (e.key < band.$1 || e.key > band.$2)
          e.key: Map<RoadWidthClass, double>.from(e.value),
    };
    if (next.length == roadZoomWidths.length) return this;
    return copyWith(roadZoomWidths: next);
  }

  Map<int, Map<String, double>> get roadZoomWidthsByName =>
      <int, Map<String, double>>{
        for (final e in roadZoomWidths.entries)
          e.key: <String, double>{
            for (final k in RoadWidthClass.values)
              k.name: e.value[k] ?? roadWidthOf(k),
          },
      };

  double roadWidthOf(RoadWidthClass c) => switch (c) {
        RoadWidthClass.motorway => roadWidthMotorway,
        RoadWidthClass.trunk => roadWidthTrunk,
        RoadWidthClass.primary => roadWidthPrimary,
        RoadWidthClass.secondary => roadWidthSecondary,
        RoadWidthClass.local => roadWidthLocal,
      };

  OfflineMapPalette withRoadWidth(RoadWidthClass c, double value) {
    final v = value.clamp(kRoadWidthMin, kRoadWidthMax).toDouble();
    return switch (c) {
      RoadWidthClass.motorway => copyWith(roadWidthMotorway: v),
      RoadWidthClass.trunk => copyWith(roadWidthTrunk: v),
      RoadWidthClass.primary => copyWith(roadWidthPrimary: v),
      RoadWidthClass.secondary => copyWith(roadWidthSecondary: v),
      RoadWidthClass.local => copyWith(roadWidthLocal: v),
    };
  }

  Map<String, double> get roadWidths => <String, double>{
        'motorway': roadWidthMotorway,
        'trunk': roadWidthTrunk,
        'primary': roadWidthPrimary,
        'secondary': roadWidthSecondary,
        'local': roadWidthLocal,
      };

  static const OfflineMapPalette darkDefault = OfflineMapPalette(
    background: Color(0xFF0F1419),
    water: Color(0xFF1B3A57),
    green: Color(0xFF1E3A2A),
    urban: Color(0xFF22262C),
    building: Color(0xFF2A2F37),
    roadOutline: Color(0xFF161D26),
    roadMotorway: Color(0xFFC79C6A),
    roadTrunk: Color(0xFFA7653E),
    roadPrimary: Color(0xFF70767A),
    roadSecondary: Color(0xFF69778A),
    roadLocal: Color(0xFF4C596A),
    label: Color(0xFFE2E8F0),
    halo: Color(0xFF101418),
    poi: Color(0xFFFFD166),
  );

  static const OfflineMapPalette lightDefault = OfflineMapPalette(
    background: Color(0xFFF3F1EC),
    water: Color(0xFFB9D9F3),
    green: Color(0xFFCFE7C9),
    urban: Color(0xFFE7E1D7),
    building: Color(0xFFD9D1C4),
    roadOutline: Color(0xFFD5D9DE),
    roadMotorway: Color(0xFFD4A56B),
    roadTrunk: Color(0xFFBA7545),
    roadPrimary: Color(0xFF68737D),
    roadSecondary: Color(0xFF96A2B1),
    roadLocal: Color(0xFFB5BDC8),
    label: Color(0xFF353535),
    halo: Colors.white,
    poi: Color(0xFFE39B1F),
  );

  factory OfflineMapPalette.defaults(MapStyleMode mode) {
    return mode == MapStyleMode.night ? darkDefault : lightDefault;
  }

  static OfflineMapPalette preset(
    MapStyleMode mode,
    MapPalettePreset preset,
  ) {
    final base = OfflineMapPalette.defaults(mode);
    switch (preset) {
      case MapPalettePreset.kartaDay:
        return lightDefault;
      case MapPalettePreset.sandstoneDay:
        return base.copyWith(
          background: const Color(0xFFF0E7D7),
          water: const Color(0xFFAED6E8),
          green: const Color(0xFFC9DEC0),
          urban: const Color(0xFFE3D8C9),
          building: const Color(0xFFD1C3AF),
          roadOutline: const Color(0xFFC8BBAA),
          roadMotorway: const Color(0xFFC99358),
          roadTrunk: const Color(0xFFA9673E),
          roadPrimary: const Color(0xFF6E7375),
          roadSecondary: const Color(0xFF9E9C92),
          roadLocal: const Color(0xFFCBC6BB),
          label: const Color(0xFF34302C),
        );
      case MapPalettePreset.kartaNight:
        return darkDefault;
      case MapPalettePreset.midnightNight:
        return base.copyWith(
          background: const Color(0xFF151A22),
          water: const Color(0xFF20445E),
          green: const Color(0xFF243A32),
          urban: const Color(0xFF292D34),
          building: const Color(0xFF353B45),
          roadOutline: const Color(0xFF10151C),
          roadMotorway: const Color(0xFFD2AA76),
          roadTrunk: const Color(0xFFB7754A),
          roadPrimary: const Color(0xFF858B91),
          roadSecondary: const Color(0xFF6F7883),
          roadLocal: const Color(0xFF535D68),
          label: const Color(0xFFF0F4F8),
          halo: const Color(0xFF151A22),
        );
    }
  }

  Color colorOf(OfflinePaletteField field) {
    switch (field) {
      case OfflinePaletteField.background:
        return background;
      case OfflinePaletteField.water:
        return water;
      case OfflinePaletteField.green:
        return green;
      case OfflinePaletteField.urban:
        return urban;
      case OfflinePaletteField.building:
        return building;
      case OfflinePaletteField.roadOutline:
        return roadOutline;
      case OfflinePaletteField.roadMotorway:
        return roadMotorway;
      case OfflinePaletteField.roadTrunk:
        return roadTrunk;
      case OfflinePaletteField.roadPrimary:
        return roadPrimary;
      case OfflinePaletteField.roadSecondary:
        return roadSecondary;
      case OfflinePaletteField.roadLocal:
        return roadLocal;
      case OfflinePaletteField.label:
        return label;
      case OfflinePaletteField.halo:
        return halo;
      case OfflinePaletteField.poi:
        return poi;
    }
  }

  OfflineMapPalette withColor(OfflinePaletteField field, Color color) {
    switch (field) {
      case OfflinePaletteField.background:
        return copyWith(background: color);
      case OfflinePaletteField.water:
        return copyWith(water: color);
      case OfflinePaletteField.green:
        return copyWith(green: color);
      case OfflinePaletteField.urban:
        return copyWith(urban: color);
      case OfflinePaletteField.building:
        return copyWith(building: color);
      case OfflinePaletteField.roadOutline:
        return copyWith(roadOutline: color);
      case OfflinePaletteField.roadMotorway:
        return copyWith(roadMotorway: color);
      case OfflinePaletteField.roadTrunk:
        return copyWith(roadTrunk: color);
      case OfflinePaletteField.roadPrimary:
        return copyWith(roadPrimary: color);
      case OfflinePaletteField.roadSecondary:
        return copyWith(roadSecondary: color);
      case OfflinePaletteField.roadLocal:
        return copyWith(roadLocal: color);
      case OfflinePaletteField.label:
        return copyWith(label: color);
      case OfflinePaletteField.halo:
        return copyWith(halo: color);
      case OfflinePaletteField.poi:
        return copyWith(poi: color);
    }
  }

  OfflineMapPalette copyWith({
    Color? background,
    Color? water,
    Color? green,
    Color? urban,
    Color? building,
    Color? roadOutline,
    Color? roadMotorway,
    Color? roadTrunk,
    Color? roadPrimary,
    Color? roadSecondary,
    Color? roadLocal,
    Color? label,
    Color? halo,
    Color? poi,
    double? roadWidthMotorway,
    double? roadWidthTrunk,
    double? roadWidthPrimary,
    double? roadWidthSecondary,
    double? roadWidthLocal,
    Map<int, Map<RoadWidthClass, double>>? roadZoomWidths,
  }) {
    return OfflineMapPalette(
      background: background ?? this.background,
      water: water ?? this.water,
      green: green ?? this.green,
      urban: urban ?? this.urban,
      building: building ?? this.building,
      roadOutline: roadOutline ?? this.roadOutline,
      roadMotorway: roadMotorway ?? this.roadMotorway,
      roadTrunk: roadTrunk ?? this.roadTrunk,
      roadPrimary: roadPrimary ?? this.roadPrimary,
      roadSecondary: roadSecondary ?? this.roadSecondary,
      roadLocal: roadLocal ?? this.roadLocal,
      label: label ?? this.label,
      halo: halo ?? this.halo,
      poi: poi ?? this.poi,
      roadWidthMotorway: roadWidthMotorway ?? this.roadWidthMotorway,
      roadWidthTrunk: roadWidthTrunk ?? this.roadWidthTrunk,
      roadWidthPrimary: roadWidthPrimary ?? this.roadWidthPrimary,
      roadWidthSecondary: roadWidthSecondary ?? this.roadWidthSecondary,
      roadWidthLocal: roadWidthLocal ?? this.roadWidthLocal,
      roadZoomWidths: roadZoomWidths ?? this.roadZoomWidths,
    );
  }

  String serialize() {
    final values = <String, Color>{
      'background': background,
      'water': water,
      'green': green,
      'urban': urban,
      'building': building,
      'roadOutline': roadOutline,
      'roadMotorway': roadMotorway,
      'roadTrunk': roadTrunk,
      'roadPrimary': roadPrimary,
      'roadSecondary': roadSecondary,
      'roadLocal': roadLocal,
      'label': label,
      'halo': halo,
      'poi': poi,
    };
    final colorValues = values.entries
        .map(
          (e) =>
              '${e.key}:${(e.value.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        )
        .join(',');
    String w(double v) => v.toStringAsFixed(4);
    return '$colorValues,'
        'wMotorway:${w(roadWidthMotorway)},wTrunk:${w(roadWidthTrunk)},'
        'wPrimary:${w(roadWidthPrimary)},wSecondary:${w(roadWidthSecondary)},'
        'wLocal:${w(roadWidthLocal)}'
        '${_serializeZoomWidths()}';
  }

  String _serializeZoomWidths() {
    final b = StringBuffer();
    final zooms = roadZoomWidths.keys.toList()..sort();
    for (final z in zooms) {
      for (final c in RoadWidthClass.values) {
        final v = roadZoomWidths[z]?[c];
        if (v != null) b.write(',zw${z}_${c.name}:${v.toStringAsFixed(4)}');
      }
    }
    return b.toString();
  }

  static OfflineMapPalette deserialize(String? raw,
      {required OfflineMapPalette fallback}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    double clampWidth(double? v) =>
        (v ?? 1.0).clamp(kRoadWidthMin, kRoadWidthMax).toDouble();
    final parsed = <String, Color>{};
    double? legacyWidth;
    final widths = <String, double>{};
    final zoomWidths = <int, Map<RoadWidthClass, double>>{};
    final zoomKey = RegExp(r'^zw(\d+)_(\w+)$');
    for (final part in raw.split(',')) {
      final kv = part.split(':');
      if (kv.length != 2) continue;
      final zm = zoomKey.firstMatch(kv[0]);
      if (zm != null) {
        final z = int.parse(zm.group(1)!);
        final value = double.tryParse(kv[1]);
        RoadWidthClass? cls;
        for (final c in RoadWidthClass.values) {
          if (c.name == zm.group(2)) cls = c;
        }
        if (cls != null && value != null && z >= kRoadZoomMin && z <= kRoadZoomMax) {
          (zoomWidths[z] ??= <RoadWidthClass, double>{})[cls] =
              clampWidth(value);
        }
        continue;
      }
      if (kv[0] == 'roadWidthScale') {
        legacyWidth = double.tryParse(kv[1]);
        continue;
      }
      if (const {'wMotorway', 'wTrunk', 'wPrimary', 'wSecondary', 'wLocal'}
          .contains(kv[0])) {
        final parsedWidth = double.tryParse(kv[1]);
        if (parsedWidth != null) widths[kv[0]] = parsedWidth;
        continue;
      }
      final value = int.tryParse(kv[1], radix: 16);
      if (value == null) continue;
      parsed[kv[0]] = Color(0xFF000000 | value);
    }
    return fallback.copyWith(
      background: parsed['background'],
      water: parsed['water'],
      green: parsed['green'],
      urban: parsed['urban'],
      building: parsed['building'],
      roadOutline: parsed['roadOutline'],
      roadMotorway: parsed['roadMotorway'],
      roadTrunk: parsed['roadTrunk'],
      roadPrimary: parsed['roadPrimary'],
      roadSecondary: parsed['roadSecondary'],
      roadLocal: parsed['roadLocal'],
      label: parsed['label'],
      halo: parsed['halo'],
      poi: parsed['poi'],
      roadWidthMotorway: clampWidth(widths['wMotorway'] ?? legacyWidth),
      roadWidthTrunk: clampWidth(widths['wTrunk'] ?? legacyWidth),
      roadWidthPrimary: clampWidth(widths['wPrimary'] ?? legacyWidth),
      roadWidthSecondary: clampWidth(widths['wSecondary'] ?? legacyWidth),
      roadWidthLocal: clampWidth(widths['wLocal'] ?? legacyWidth),
      roadZoomWidths: zoomWidths,
    );
  }
}

class OfflineMapPaletteNotifier extends StateNotifier<OfflineMapPalette> {
  OfflineMapPaletteNotifier(this._ref, this._mode)
      : super(OfflineMapPalette.defaults(_mode));

  final Ref _ref;
  final MapStyleMode _mode;

  String get _storageKey => _mode == MapStyleMode.night
      ? SettingsRepository.keyOfflinePaletteDark
      : SettingsRepository.keyOfflinePaletteLight;

  Future<void> load() async {
    final repo = _ref.read(settingsRepositoryProvider);
    final raw = await repo.getValue(_storageKey);
    state = OfflineMapPalette.deserialize(
      raw,
      fallback: OfflineMapPalette.defaults(_mode),
    );
  }

  Future<void> setColor(OfflinePaletteField field, Color color) async {
    state = state.withColor(field, color);
    await _persist();
  }

  Future<void> setRoadWidth(RoadWidthClass cls, double value) async {
    state = state.withRoadWidth(cls, value);
    await _persist();
  }

  Future<void> setRoadWidthAtZoom(
      RoadWidthClass cls, int zoom, double value) async {
    state = state.withRoadWidthAtZoom(cls, zoom, value);
    await _persist();
  }

  Future<void> resetRoadZoom(int zoom) async {
    state = state.withoutRoadZoom(zoom);
    await _persist();
  }

  Future<void> reset() async {
    state = OfflineMapPalette.defaults(_mode);
    await _persist();
  }

  Future<void> applyPreset(MapPalettePreset preset) async {
    state = OfflineMapPalette.preset(_mode, preset).copyWith(
      roadWidthMotorway: state.roadWidthMotorway,
      roadWidthTrunk: state.roadWidthTrunk,
      roadWidthPrimary: state.roadWidthPrimary,
      roadWidthSecondary: state.roadWidthSecondary,
      roadWidthLocal: state.roadWidthLocal,
      roadZoomWidths: state.roadZoomWidths,
    );
    await _persist();
  }

  Future<void> _persist() {
    return _ref
        .read(settingsRepositoryProvider)
        .setValue(_storageKey, state.serialize());
  }
}

final offlineLightPaletteProvider =
    StateNotifierProvider<OfflineMapPaletteNotifier, OfflineMapPalette>(
  (ref) => OfflineMapPaletteNotifier(ref, MapStyleMode.day),
);

final offlineDarkPaletteProvider =
    StateNotifierProvider<OfflineMapPaletteNotifier, OfflineMapPalette>(
  (ref) => OfflineMapPaletteNotifier(ref, MapStyleMode.night),
);

final currentOfflineMapPaletteProvider = Provider<OfflineMapPalette>((ref) {
  final mode = ref.watch(mapStyleModeProvider);
  return mode == MapStyleMode.night
      ? ref.watch(offlineDarkPaletteProvider)
      : ref.watch(offlineLightPaletteProvider);
});
