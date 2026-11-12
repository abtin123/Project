import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_provider.dart';
import '../data/history_repository.dart';

final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  return HistoryRepository(ref.watch(appDatabaseProvider));
});

final searchHistoryListProvider =
    StreamProvider.autoDispose<List<SearchHistoryData>>((ref) {
  return ref.watch(historyRepositoryProvider).watchSearches();
});

final routeHistoryListProvider =
    StreamProvider.autoDispose<List<RouteHistoryData>>((ref) {
  return ref.watch(historyRepositoryProvider).watchRoutes();
});
