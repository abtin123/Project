import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/database_provider.dart';
import '../data/saved_places_repository.dart';

export '../../../core/database/database_provider.dart' show appDatabaseProvider;

final savedPlacesRepositoryProvider = Provider<SavedPlacesRepository>((ref) {
  return SavedPlacesRepository(ref.watch(appDatabaseProvider));
});

final savedPlacesListProvider = StreamProvider((ref) {
  return ref.watch(savedPlacesRepositoryProvider).watchAll();
});

SavedPlace? _firstOfCategory(List<SavedPlace>? places, String category) {
  if (places == null) return null;
  for (final p in places) {
    if (p.category == category) return p;
  }
  return null;
}

/// مکان «خانه» (null اگر تعریف نشده).
final homePlaceProvider = Provider<SavedPlace?>((ref) =>
    _firstOfCategory(ref.watch(savedPlacesListProvider).valueOrNull, 'home'));

/// مکان «محل کار» (null اگر تعریف نشده).
final workPlaceProvider = Provider<SavedPlace?>((ref) =>
    _firstOfCategory(ref.watch(savedPlacesListProvider).valueOrNull, 'work'));
