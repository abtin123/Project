import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../abtinmap/abm_map_service.dart';
import '../../../core/geo/geo_types.dart';
import '../../offline_maps/data/region_resolver.dart';
import '../../offline_maps/data/map_catalog.dart';
import '../../offline_maps/presentation/offline_maps_providers.dart';
import '../../routing/data/routing_provider.dart';
import '../../gps/presentation/gps_providers.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../data/offline_place_search_service.dart';
import '../data/place_search_service.dart';

final searchActiveProvider = StateProvider<bool>((ref) => false);
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchSubmittedQueryProvider = StateProvider<String>((ref) => '');
final searchSelectedIndexProvider = StateProvider<int>((ref) => 0);
final _onlineSearchProvider =
    Provider<PlaceSearchService>((ref) => PlaceSearchService());
final _offlineSearchProvider = Provider<OfflinePlaceSearchService>(
    (ref) => OfflinePlaceSearchService(ref.watch(abmMapServiceProvider)));
const _regionResolver = RegionResolver();

final searchResultsProvider =
    FutureProvider.autoDispose<List<PlaceSearchResult>>((ref) async {
  final query = ref.watch(searchSubmittedQueryProvider).trim();
  if (query.length < 2) return const [];

  final current = ref.read(vehiclePositionProvider).valueOrNull;

  final requestedEngine = ref.watch(routingEngineProvider);
  final installedRegions = requestedEngine != RoutingEngine.online
      ? await ref
          .read(installedMapRegionsProvider.future)
          .catchError((_) => const <MapRegion>[])
      : const <MapRegion>[];

  if (installedRegions.isNotEmpty) {
    final gpsPosition =
        current == null ? null : LatLng(current.lat, current.lng);
    final orderedRegions = _regionResolver.order(
      query: query,
      installedRegions: installedRegions,
      gpsPosition: gpsPosition,
    );
    final result = await ref.read(_offlineSearchProvider).searchAcrossRegions(
          query,
          orderedRegions: orderedRegions,
          biasLat: current?.lat,
          biasLng: current?.lng,
          localOnly:
              _regionResolver.explicitMatch(query, installedRegions) == null,
        );
    ref.read(searchSelectedIndexProvider.notifier).state = 0;
    return result;
  }

  final result = await ref
      .read(_onlineSearchProvider)
      .searchOnline(
        query,
        biasLat: current?.lat,
        biasLng: current?.lng,
      )
      .timeout(
        const Duration(seconds: 8),
        onTimeout: () => const <PlaceSearchResult>[],
      )
      .catchError((_) => <PlaceSearchResult>[]);
  ref.read(searchSelectedIndexProvider.notifier).state = 0;
  return result;
});
