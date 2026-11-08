import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../abtinmap/abm_models.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../features/settings/presentation/settings_repository_provider.dart';

final abmPoiVisibilityProvider =
    StateNotifierProvider<AbmPoiVisibilityNotifier, Set<int>?>(
  (ref) => AbmPoiVisibilityNotifier(ref),
);

class AbmPoiVisibilityNotifier extends StateNotifier<Set<int>?> {
  AbmPoiVisibilityNotifier(this._ref) : super(null);

  final Ref _ref;

  static const _allMarker = '*';

  Future<void> load() async {
    final repo = _ref.read(settingsRepositoryProvider);
    final raw = await repo.getValue(SettingsRepository.keyVisiblePoiKlasses);
    if (raw == null || raw == _allMarker) {
      state = null;
      return;
    }
    if (raw.isEmpty) {
      state = const <int>{};
      return;
    }
    state = raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
  }

  Future<void> setKlassEnabled(int klass, bool enabled) async {
    final base = state ?? AbmKlass.selectablePoiKlasses.toSet();
    final next = Set<int>.from(base);
    if (enabled) {
      next.add(klass);
    } else {
      next.remove(klass);
    }
    state = next;
    await _persist(next);
  }

  Future<void> showAll() async {
    state = null;
    final repo = _ref.read(settingsRepositoryProvider);
    await repo.setValue(SettingsRepository.keyVisiblePoiKlasses, _allMarker);
  }

  Future<void> hideAll() async {
    state = const <int>{};
    await _persist(state!);
  }

  Future<void> _persist(Set<int> value) async {
    final repo = _ref.read(settingsRepositoryProvider);
    await repo.setValue(
      SettingsRepository.keyVisiblePoiKlasses,
      value.join(','),
    );
  }
}
