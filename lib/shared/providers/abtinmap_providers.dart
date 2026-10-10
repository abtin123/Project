import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../abtinmap/abm_map_service.dart';
import '../../features/offline_maps/data/map_catalog.dart';
import '../../features/offline_maps/data/vector_map_service.dart';
import '../../features/offline_maps/presentation/offline_maps_providers.dart';
import '../../features/routing/data/routing_provider.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../features/settings/presentation/settings_repository_provider.dart';

final abmMapServiceProvider = Provider<AbmMapService>((ref) {
  final service = AbmMapService();
  ref.onDispose(service.closeMap);
  return service;
});

final vectorMapServiceProvider = Provider<VectorMapService>((ref) {
  return VectorMapService();
});

final activeOfflineMapIdProvider = StateProvider<String>((ref) => '');

final abmActiveMapNameProvider = StateProvider<String>((ref) => '__none__.abm');

final routingEngineProvider =
    StateProvider<RoutingEngine>((ref) => RoutingEngine.online);

class OfflineMapSource {
  const OfflineMapSource({required this.file, required this.id});

  final File file;
  final String id;

  String get fileName => p.basename(file.path);
}

final installedOfflineMapSourcesProvider =
    FutureProvider<List<OfflineMapSource>>((ref) async {
  final service = ref.read(abmMapServiceProvider);
  final names = await service.installedMaps();
  final out = <OfflineMapSource>[];
  final seen = <String>{};
  for (final name in names) {
    final id = p.basenameWithoutExtension(name).toUpperCase();
    if (!seen.add(id)) continue;
    final file = await service.localFile(name);
    if (!await file.exists() || await file.length() <= 0) continue;
    out.add(OfflineMapSource(file: file, id: id));
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
});

Future<List<double>?> offlineMapBbox(
  VectorMapService service,
  OfflineMapSource source,
) async {
  try {
    final artifacts =
        await service.prepare(containerFile: source.file, id: source.id);
    final raw = artifacts.metadata['bbox'];
    if (raw is List && raw.length >= 4) {
      return <double>[for (var i = 0; i < 4; i++) (raw[i] as num).toDouble()];
    }
  } catch (_) {}
  return null;
}

bool bboxIntersects(List<double>? a, double minLon, double minLat,
    double maxLon, double maxLat) {
  if (a == null) return true;
  return !(a[2] < minLon || a[0] > maxLon || a[3] < minLat || a[1] > maxLat);
}

bool bboxContains(List<double>? a, double lat, double lon) {
  if (a == null) return false;
  return lon >= a[0] && lon <= a[2] && lat >= a[1] && lat <= a[3];
}

Future<bool> hasActiveOfflineAtlas(dynamic ref) async {
  final List<OfflineMapSource> sources =
      await ref.read(installedOfflineMapSourcesProvider.future);
  for (final source in sources) {
    try {
      await ref.read(vectorMapServiceProvider).prepare(
            containerFile: source.file,
            id: source.id,
          );
      return true;
    } catch (error, stack) {
    }
  }
  return false;
}

Future<void> _setRoutingEngine(dynamic ref, RoutingEngine engine) async {
  if (engine == RoutingEngine.abtinmap) {
    var ready = await hasActiveOfflineAtlas(ref);
    if (!ready) {
      ref.read(routingEngineProvider.notifier).state = RoutingEngine.online;
      await ref.read(settingsRepositoryProvider).setValue(
        SettingsRepository.keyRoutingEngine, RoutingEngine.online.storageValue);
      return;
    }
  }
  ref.read(routingEngineProvider.notifier).state = engine;
  await ref.read(settingsRepositoryProvider).setValue(
    SettingsRepository.keyRoutingEngine, engine.storageValue);
}

Future<void> setRoutingEngine(Ref ref, RoutingEngine engine) =>
    _setRoutingEngine(ref, engine);

Future<void> setRoutingEngineFromWidget(WidgetRef ref, RoutingEngine engine) =>
    _setRoutingEngine(ref, engine);


final offlineAtlasReadyProvider = FutureProvider<bool>((ref) async {
  return hasActiveOfflineAtlas(ref);
});

final activeOfflineMapFileProvider = FutureProvider<File?>((ref) async {
  final service = ref.read(abmMapServiceProvider);
  final sources = await ref.watch(installedOfflineMapSourcesProvider.future);
  if (sources.isEmpty) return null;
  final name = ref.watch(abmActiveMapNameProvider).trim();
  if (name.isNotEmpty && name != '__none__.abm') {
    final file = await service.localFile(name);
    if (await file.exists() && await file.length() > 0) return file;
  }
  return sources.first.file;
});

final abmInstalledProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(abmMapServiceProvider);
  return service.isInstalled(ref.watch(abmActiveMapNameProvider));
});

final abmInstalledVersionProvider = FutureProvider<String?>((ref) async {
  final service = ref.watch(abmMapServiceProvider);
  return service.installedVersion(ref.watch(abmActiveMapNameProvider));
});

class AbmDownloadState {
  const AbmDownloadState({
    this.busy = false,
    this.received = 0,
    this.total,
    this.error,
    this.done = false,
  });

  final bool busy;
  final int received;
  final int? total;
  final String? error;
  final bool done;

  double? get fraction =>
      (total == null || total == 0) ? null : received / total!;

  AbmDownloadState copyWith({
    bool? busy,
    int? received,
    int? total,
    String? error,
    bool? done,
  }) =>
      AbmDownloadState(
        busy: busy ?? this.busy,
        received: received ?? this.received,
        total: total ?? this.total,
        error: error,
        done: done ?? this.done,
      );
}

class AbmDownloadController extends StateNotifier<AbmDownloadState> {
  AbmDownloadController(this._ref) : super(const AbmDownloadState());

  final Ref _ref;

  Future<File?> download({bool force = false}) async {
    final service = _ref.read(abmMapServiceProvider);
    final name = _ref.read(abmActiveMapNameProvider);
    final id = name.toLowerCase().endsWith('.abm')
        ? name.substring(0, name.length - 4)
        : name;
    state = const AbmDownloadState(busy: true);
    try {
      final catalog = await _ref.read(mapCatalogServiceProvider).load();
      final region = catalog.byId(id) ?? catalog.byId(id.toUpperCase());
      final File file;
      if (region != null) {
        file = await service.downloadRegion(
          id: region.id,
          files: region.effectiveFiles,
          downloadBase: region.effectiveDownloadBase,
          totalSizeBytes: region.totalSizeBytes,
          expectedSha256: region.version,
          force: force,
          onProgress: (p) {
            state = state.copyWith(received: p.received, total: p.total);
          },
        );
      } else {
        file = await service.download(
          name,
          force: force,
          onProgress: (p) {
            state = state.copyWith(received: p.received, total: p.total);
          },
        );
      }
      state = state.copyWith(busy: false, done: true);
      _ref.invalidate(abmInstalledProvider);
      _ref.invalidate(abmInstalledVersionProvider);
      return file;
    } catch (error) {
      state = AbmDownloadState(
          busy: false, error: 'دانلود نقشه ناموفق بود: $error');
      return null;
    }
  }

  Future<void> delete() async {
    final service = _ref.read(abmMapServiceProvider);
    await service.deleteMap(_ref.read(abmActiveMapNameProvider));
    state = const AbmDownloadState();
    _ref.invalidate(abmInstalledProvider);
    _ref.invalidate(abmInstalledVersionProvider);
  }
}
