import '../../../core/geo/geo_types.dart';
import 'map_catalog.dart';

/// Resolves which installed province/region `.abm` (and therefore which
/// `map.sqlite`) should answer a search/POI/routing query — entirely
/// offline, with no network call.
///
/// Priority order:
/// 1) اگر نام استان/شهر به‌صراحت در متن سرچ باشد (مثلاً «همدان بلوار امام
///    خمینی»)، همان استان برنده است، حتی اگر GPS جای دیگری باشد.
/// 2) در غیر این صورت، اگر موقعیت GPS داخل محدودهٔ یکی از استان‌های
///    نصب‌شده باشد، همان استان انتخاب می‌شود (مثلاً کاربر در اراک →
///    استان مرکزی، بدون نیاز به نوشتن نام شهر).
/// 3) در غیر این صورت، نزدیک‌ترین استان نصب‌شده (بر اساس مرکز محدودهٔ آن)
///    انتخاب می‌شود.
///
/// [order] همیشه فهرست *همهٔ* استان‌های نصب‌شده را برمی‌گرداند، فقط با
/// برنده در جایگاه اول؛ یعنی اگر جستجو در استان برنده نتیجه‌ای نداشت،
/// بقیهٔ نقشه‌های دانلودشده هم به‌عنوان fallback بررسی می‌شوند — همهٔ
/// استان‌های دانلودشده هم‌زمان قابل استفاده می‌مانند.
class RegionResolver {
  const RegionResolver();

  static String _normalize(String value) => value
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(RegExp(r'[\u064B-\u065F\u200c]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();

  /// نامی که کاربر صریحاً در متن نوشته باشد را با نام استان‌های نصب‌شده
  /// مطابقت می‌دهد. طولانی‌ترین تطبیق برنده است (مثلاً «آذربایجان شرقی»
  /// باید بر «آذربایجان» ارجحیت داشته باشد اگر هر دو نصب باشند).
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

  /// استان مربوط به یک نقطهٔ GPS، بدون هیچ متن سرچ (برای مسیریابی/موقعیت
  /// فعلی کاربر استفاده می‌شود): ابتدا استانی که نقطه داخل محدودهٔ آن است،
  /// وگرنه نزدیک‌ترین استان نصب‌شده.
  MapRegion? resolveByPosition(LatLng point, List<MapRegion> installedRegions) {
    if (installedRegions.isEmpty) return null;
    return _containing(point, installedRegions) ??
        _nearest(point, installedRegions);
  }

  /// فهرست اولویت‌دار استان‌های نصب‌شده برای یک عبارت سرچ. جایگاه اول همان
  /// استانی است که باید ابتدا در map.sqlite آن جست‌وجو شود؛ بقیه به همان
  /// ترتیب ورودی، به‌عنوان fallback دنبال آن می‌آیند.
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
