import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// سابقهٔ جستجو و سابقهٔ مسیریابی (جدول‌های SearchHistory / RouteHistory).
class HistoryRepository {
  final AppDatabase db;
  HistoryRepository(this.db);

  /// حداکثر تعداد رکوردِ نگه‌داشته‌شده برای هر سابقه.
  static const int maxEntries = 30;

  // ---------------------------------------------------------------- search

  Stream<List<SearchHistoryData>> watchSearches({int limit = 12}) {
    return (db.select(db.searchHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.searchedAt)])
          ..limit(limit))
        .watch();
  }

  Future<void> addSearch({
    required String query,
    required String title,
    String? subtitle,
    required double latitude,
    required double longitude,
    bool isOffline = false,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return;
    // یک مکانِ تکراری فقط یک‌بار و در بالای فهرست می‌ماند.
    await (db.delete(db.searchHistory)
          ..where((t) =>
              t.title.equals(cleanTitle) &
              t.latitude.isBetweenValues(latitude - 0.0005, latitude + 0.0005) &
              t.longitude
                  .isBetweenValues(longitude - 0.0005, longitude + 0.0005)))
        .go();
    await db.into(db.searchHistory).insert(
          SearchHistoryCompanion.insert(
            query: query.trim().isEmpty ? cleanTitle : query.trim(),
            title: cleanTitle,
            subtitle: Value(subtitle),
            latitude: latitude,
            longitude: longitude,
            isOffline: Value(isOffline),
          ),
        );
    await _trimSearches();
  }

  Future<void> removeSearch(int id) =>
      (db.delete(db.searchHistory)..where((t) => t.id.equals(id))).go();

  Future<void> clearSearches() => db.delete(db.searchHistory).go();

  Future<void> _trimSearches() async {
    final rows = await (db.select(db.searchHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.searchedAt)]))
        .get();
    if (rows.length <= maxEntries) return;
    final stale = rows.skip(maxEntries).map((r) => r.id).toList();
    await (db.delete(db.searchHistory)..where((t) => t.id.isIn(stale))).go();
  }

  // ----------------------------------------------------------------- route

  Stream<List<RouteHistoryData>> watchRoutes({int limit = 12}) {
    return (db.select(db.routeHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  Future<void> addRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    String? endLabel,
  }) async {
    // مقصد تکراری (کمتر از ~۴۰ متر) فقط یک‌بار در سابقه می‌ماند.
    final existing = await db.select(db.routeHistory).get();
    final dup = existing
        .where((r) => _meters(r.endLat, r.endLng, endLat, endLng) < 40)
        .map((r) => r.id)
        .toList();
    if (dup.isNotEmpty) {
      await (db.delete(db.routeHistory)..where((t) => t.id.isIn(dup))).go();
    }
    final label = endLabel?.trim();
    await db.into(db.routeHistory).insert(
          RouteHistoryCompanion.insert(
            startLat: startLat,
            startLng: startLng,
            endLat: endLat,
            endLng: endLng,
            endLabel: Value(label == null || label.isEmpty ? null : label),
          ),
        );
    final rows = await (db.select(db.routeHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    if (rows.length > maxEntries) {
      final stale = rows.skip(maxEntries).map((r) => r.id).toList();
      await (db.delete(db.routeHistory)..where((t) => t.id.isIn(stale))).go();
    }
  }

  Future<void> removeRoute(int id) =>
      (db.delete(db.routeHistory)..where((t) => t.id.equals(id))).go();

  Future<void> clearRoutes() => db.delete(db.routeHistory).go();

  static double _meters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180.0;
    final p2 = lat2 * math.pi / 180.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
