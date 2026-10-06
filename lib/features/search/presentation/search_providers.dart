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
/// Text currently typed in the input. Typing alone never triggers a search.
final searchQueryProvider = StateProvider<String>((ref) => '');

/// The query the user explicitly submitted (keyboard Enter/Search key or the
/// in-app search button). Only this provider drives [searchResultsProvider].
final searchSubmittedQueryProvider = StateProvider<String>((ref) => '');
final searchSelectedIndexProvider = StateProvider<int>((ref) => 0);
final _onlineSearchProvider =
    Provider<PlaceSearchService>((ref) => PlaceSearchService());
final _offlineSearchProvider = Provider<OfflinePlaceSearchService>(
    (ref) => OfflinePlaceSearchService(ref.watch(abmMapServiceProvider)));
const _regionResolver = RegionResolver();

/// Search follows the actual map mode. Online map => online search only.
/// Offline ABM maps => *every* downloaded province/region is searchable at
/// once, each from its own `map.sqlite`. Which one is tried first follows
/// [RegionResolver]'s priority: an explicit city/province name written in
/// the query (e.g. «همدان بلوار امام خمینی») always wins; otherwise the
/// user's current GPS position picks the province (e.g. در اراک → استان
/// مرکزی) so the user never has to name the city by hand. If the winning
/// province has no match, the rest of the downloaded provinces are tried
/// too — no installed map is ever excluded. We intentionally never merge
/// online and offline modes: this prevents a network result from appearing
/// while the user is navigating an offline map and prevents a missing
/// offline index from silently causing a network request.
final searchResultsProvider =
    FutureProvider.autoDispose<List<PlaceSearchResult>>((ref) async {
  final query = ref.watch(searchSubmittedQueryProvider).trim();
  if (query.length < 2) return const [];

  final current = ref.read(vehiclePositionProvider).valueOrNull;

  // HomeScreen falls back to the online renderer if the requested offline
  // engine has no complete vector ABM installed. Mirror that exact decision
  // here so search mode always matches the map that is actually visible.
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
          // A city/province named in the text («همدان …») overrides "near me".
          localOnly:
              _regionResolver.explicitMatch(query, installedRegions) == null,
        );
    ref.read(searchSelectedIndexProvider.notifier).state = 0;
    return result;
  }

  // Online mode is deliberately network-only. A failed network request is
  // an empty result, not a fallback to the local ABM index.
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
