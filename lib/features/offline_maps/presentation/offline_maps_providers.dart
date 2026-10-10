import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../data/map_catalog.dart';
import '../../../shared/providers/abtinmap_providers.dart';

final mapCatalogServiceProvider = Provider<MapCatalogService>((ref) {
  final service = MapCatalogService();
  ref.onDispose(service.dispose);
  return service;
});

final catalogRefreshProvider = StateProvider<int>((ref) => 0);

final mapCatalogProvider = FutureProvider<MapCatalog>((ref) async {
  final refreshCount = ref.watch(catalogRefreshProvider);
  final catalog = await ref
      .watch(mapCatalogServiceProvider)
      .loadForRefreshToken(refreshCount);
  return catalog;
});

final installedMapRegionsProvider =
    FutureProvider.autoDispose<List<MapRegion>>((ref) async {
  final mapService = ref.watch(abmMapServiceProvider);
  final installedNames = await mapService.installedMaps();
  if (installedNames.isEmpty) return const <MapRegion>[];

  MapCatalog? catalog;
  try {
    catalog = await ref.watch(mapCatalogServiceProvider).load();
  } catch (_) {
    catalog = null;
  }

  final regions = <MapRegion>[];
  for (final fileName in installedNames) {
    final id = p
        .basenameWithoutExtension(fileName)
        .toUpperCase();
    final fromCatalog = catalog?.byId(id);
    if (fromCatalog != null) {
      regions.add(fromCatalog);
      continue;
    }
    int sizeBytes = 0;
    try {
      sizeBytes = await (await mapService.localFile(fileName)).length();
    } catch (_) {}
    regions.add(MapRegion.fromInstalledFileOnly(
      id: id,
      fileSizeBytes: sizeBytes,
    ));
  }
  return regions;
});

final abmInstalledMapIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final service = ref.watch(abmMapServiceProvider);
  final names = await service.installedMaps();
  return names.map((n) => p.basenameWithoutExtension(n)).toSet();
});

final updatableMapIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final catalog = await ref.watch(mapCatalogProvider.future);
  final service = ref.watch(abmMapServiceProvider);
  final out = <String>{};
  for (final region in catalog.regions) {
    final installed = await service.installedSha256(region.abmFileName);
    if (installed != null &&
        region.version.isNotEmpty &&
        installed.toLowerCase() != region.version.toLowerCase()) {
      out.add(region.id);
    }
  }
  return out;
});
