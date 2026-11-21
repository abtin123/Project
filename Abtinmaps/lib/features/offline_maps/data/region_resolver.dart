import '../../../core/geo/geo_types.dart';
import 'map_catalog.dart';

class RegionResolver {
  const RegionResolver();

  static String _normalize(String value) => value
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(RegExp(r'[\u064B-\u065F\u200c]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  MapRegion? explicitMatch(String query, List<MapRegion> installedRegions) {
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) return null;
    MapRegion? best;
    var bestLength = 0;
    for (final region in installedRegions) {
      for (final candidate in <String>[
        region.name,
        region.nameEn,
        region.regionName,
        region.regionNameEn,
      ]) {
        final name = _normalize(candidate);
        if (name.length < 2) continue;
        if (normalizedQuery.contains(name) && name.length > bestLength) {
          best = region;
          bestLength = name.length;
        }
      }
    }
    return best;
  }

  MapRegion? _containing(LatLng point, List<MapRegion> installedRegions) {
    for (final region in installedRegions) {
      final b = region.bounds;
      if (point.latitude >= b.southwest.latitude &&
          point.latitude <= b.northeast.latitude &&
          point.longitude >= b.southwest.longitude &&
          point.longitude <= b.northeast.longitude) {
        return region;
      }
    }
    return null;
  }

  MapRegion? _nearest(LatLng point, List<MapRegion> installedRegions) {
    MapRegion? best;
    var bestDistance = double.infinity;
    for (final region in installedRegions) {
      final b = region.bounds;
      final centerLat = (b.southwest.latitude + b.northeast.latitude) / 2;
      final centerLng = (b.southwest.longitude + b.northeast.longitude) / 2;
      final dLat = point.latitude - centerLat;
      final dLng = point.longitude - centerLng;
      final distance = dLat * dLat + dLng * dLng;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = region;
      }
    }
    return best;
  }

  MapRegion? resolveByPosition(LatLng point, List<MapRegion> installedRegions) {
    if (installedRegions.isEmpty) return null;
    return _containing(point, installedRegions) ??
        _nearest(point, installedRegions);
  }

  List<MapRegion> order({
    required String query,
    required List<MapRegion> installedRegions,
    LatLng? gpsPosition,
  }) {
    if (installedRegions.isEmpty) return const <MapRegion>[];
    final winner = explicitMatch(query, installedRegions) ??
        (gpsPosition == null
            ? null
            : resolveByPosition(gpsPosition, installedRegions));
    if (winner == null) return List<MapRegion>.of(installedRegions);
    return <MapRegion>[
      winner,
      ...installedRegions.where((r) => r.id != winner.id),
    ];
  }
}
