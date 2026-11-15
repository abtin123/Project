import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../abtinmap/abm_map_service.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../../../shared/providers/map_style_providers.dart';
import '../data/map_catalog.dart';
import '../data/vector_map_service.dart';
import '../../routing/data/routing_provider.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/presentation/settings_repository_provider.dart';
import 'offline_maps_providers.dart';

enum RegionDownloadPhase { downloading, building, saving, completed }

class RegionDownloadState {
  const RegionDownloadState({
    this.downloading = false,
    this.received = 0,
    this.total,
    this.phase,
    this.error,
    this.paused = false,
  });

  final bool paused;

  final bool downloading;
  final RegionDownloadPhase? phase;
  final int received;
  final int? total;
  final String? error;

  double? get fraction =>
      (total == null || total == 0) ? null : (received / total!).clamp(0, 1);

  RegionDownloadState copyWith({
    bool? downloading,
    int? received,
    int? total,
    RegionDownloadPhase? phase,
    String? error,
    bool? paused,
  }) =>
      RegionDownloadState(
        paused: paused ?? this.paused,
        downloading: downloading ?? this.downloading,
        received: received ?? this.received,
        total: total ?? this.total,
        phase: phase ?? this.phase,
        error: error,
      );
}

class RegionDownloadController extends StateNotifier<RegionDownloadState> {
  RegionDownloadController(this._ref, this._region)
      : super(const RegionDownloadState());

  final Ref _ref;
  final MapRegion _region;
  bool _cancelled = false;
  bool _paused = false;

  KeepAliveLink? _keepAliveLink;

  Future<void> start() async {
    if (state.downloading) return;
    _cancelled = false;
    _paused = false;
    state = RegionDownloadState(
      downloading: true,
      phase: RegionDownloadPhase.downloading,
      received: state.received,
      total: state.total,
    );
    _keepAliveLink ??= _ref.keepAlive();
    final service = _ref.read(abmMapServiceProvider);
    var activeRegion = _region;
    final vector = _region.vectorMap;
    final vectorService = _ref.read(vectorMapServiceProvider);
    try {
      final onProgress = (AbmDownloadProgress p) {
        if (_cancelled || !mounted) return;
        state = state.copyWith(
          received: p.received,
          total: activeRegion.totalSizeBytes > 0
              ? activeRegion.totalSizeBytes
              : p.total,
        );
      };
      Future<void> downloadRegionFor(MapRegion region) async {
        if (region.isBundledAsset) {
          await service.installBundledAsset(
            name: region.abmFileName,
            assetPath: region.bundledAsset,
            version: region.version,
            onProgress: onProgress,
          );
        } else {
          await service.downloadRegion(
            id: region.id,
            files: region.effectiveFiles,
            patch: region.patch,
            downloadBase: region.effectiveDownloadBase,
            totalSizeBytes: region.totalSizeBytes,
            expectedSha256: region.version,
            onProgress: onProgress,
            isCancelled: () => _cancelled,
          );
        }
      }

      try {
        await downloadRegionFor(activeRegion);
      } on AbmFormatException catch (error) {
        final text = error.toString();
        final integrityFailure = text.contains('ناقص') ||
            text.contains('خراب') ||
            text.contains('نامعتبر');
        if (!integrityFailure || _cancelled) rethrow;

        try {
          final freshCatalog = await _ref
              .read(mapCatalogServiceProvider)
              .load(forceRefresh: true);
          final freshRegion = freshCatalog.byId(_region.id);
          if (freshRegion == null || freshRegion.version == _region.version) {
            rethrow;
          }
          activeRegion = freshRegion;
          
          await downloadRegionFor(activeRegion);
        } catch (_) {
          rethrow;
        }
      }
      if (_cancelled) throw const AbmDownloadCancelled();
      final containerFile = await service.localFile(activeRegion.abmFileName);
      if (mounted) {
        state = state.copyWith(
          phase: RegionDownloadPhase.building,
          received: activeRegion.totalSizeBytes,
          total: activeRegion.totalSizeBytes,
        );
      }
      await vectorService.prepare(
        containerFile: containerFile,
        id: _region.id,
        onProgress: (v) {
          if (!mounted || _cancelled) return;
          state = state.copyWith(
            received: activeRegion.totalSizeBytes,
            total: activeRegion.totalSizeBytes,
          );
        },
      );
      if (mounted) {
        state = state.copyWith(
          phase: RegionDownloadPhase.saving,
          received: activeRegion.totalSizeBytes,
          total: activeRegion.totalSizeBytes,
        );
      }
      if (!mounted) return;
      if (_cancelled) {
        state = const RegionDownloadState();
        return;
      }
      if (mounted) {
        state = RegionDownloadState(
          downloading: false,
          received:
              activeRegion.totalSizeBytes > 0 ? activeRegion.totalSizeBytes : 1,
          total:
              activeRegion.totalSizeBytes > 0 ? activeRegion.totalSizeBytes : 1,
          phase: RegionDownloadPhase.completed,
        );
      }
      _ref.read(abmActiveMapNameProvider.notifier).state =
          activeRegion.abmFileName;
      _ref.read(activeOfflineMapIdProvider.notifier).state = activeRegion.id;
      await setRoutingEngine(_ref, RoutingEngine.abtinmap);
      await _ref.read(settingsRepositoryProvider).setValue(
            SettingsRepository.keyActiveMapName,
            activeRegion.abmFileName,
          );
      _ref.invalidate(installedOfflineMapSourcesProvider);
      _ref.invalidate(abmInstalledMapIdsProviderFamily(activeRegion.id));
      _ref.invalidate(abmInstalledProvider);
      _ref.invalidate(abmInstalledVersionProvider);
      _ref.invalidate(offlineAtlasReadyProvider);
      _ref.invalidate(resolvedMapStyleProvider);
    } on AbmDownloadCancelled {
      if (mounted) {
        state = _paused
            ? RegionDownloadState(
                paused: true, received: state.received, total: state.total)
            : const RegionDownloadState();
      }
      _ref.invalidate(regionStagedBytesProvider(_region));
    } catch (error, stack) {
      
      if (mounted) state = RegionDownloadState(error: '$error');
    } finally {
      _keepAliveLink?.close();
      _keepAliveLink = null;
    }
  }

  void pause() {
    _paused = true;
    _cancelled = true;
  }

  Future<void> delete() async {
    final service = _ref.read(abmMapServiceProvider);
    await service.deleteMap(_region.abmFileName);
    await _ref.read(vectorMapServiceProvider).delete(_region.id);
    state = const RegionDownloadState();
    _ref.invalidate(abmInstalledMapIdsProviderFamily(_region.id));
    _ref.invalidate(abmInstalledProvider);
    _ref.invalidate(abmInstalledVersionProvider);
    _ref.invalidate(installedOfflineMapSourcesProvider);
    final remaining =
        await _ref.read(installedOfflineMapSourcesProvider.future);
    if (_ref.read(abmActiveMapNameProvider) == _region.abmFileName) {
      if (remaining.isNotEmpty) {
        final next = remaining.first;
        _ref.read(abmActiveMapNameProvider.notifier).state = next.fileName;
        _ref.read(activeOfflineMapIdProvider.notifier).state = next.id;
        await _ref.read(settingsRepositoryProvider).setValue(
              SettingsRepository.keyActiveMapName,
              next.fileName,
            );
      } else {
        _ref.read(abmActiveMapNameProvider.notifier).state = '__none__.abm';
        _ref.read(activeOfflineMapIdProvider.notifier).state = '';
      }
    }
    if (remaining.isEmpty) {
      await setRoutingEngine(_ref, RoutingEngine.online);
    }
    _ref.invalidate(activeOfflineMapFileProvider);
    _ref.invalidate(offlineAtlasReadyProvider);
    _ref.invalidate(resolvedMapStyleProvider);
  }
}

final regionDownloadControllerProvider = StateNotifierProvider.family
    .autoDispose<RegionDownloadController, RegionDownloadState, MapRegion>(
        (ref, region) => RegionDownloadController(ref, region));

final regionStagedBytesProvider =
    FutureProvider.family.autoDispose<int, MapRegion>((ref, region) {
  return ref
      .watch(abmMapServiceProvider)
      .stagedBytes(id: region.id, version: region.version);
});

final abmInstalledMapIdsProviderFamily =
    FutureProvider.family.autoDispose<bool, String>((ref, regionId) async {
  final service = ref.watch(abmMapServiceProvider);
  return service.isInstalled('$regionId.abm');
});
