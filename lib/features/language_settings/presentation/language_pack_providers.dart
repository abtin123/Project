import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/language_pack_catalog.dart';
import '../data/language_pack_service.dart';

final languagePackServiceProvider = Provider<LanguagePackService>((ref) {
  return LanguagePackService();
});

final languagePackCatalogRefreshProvider = StateProvider<int>((ref) => 0);

final languagePackManifestProvider =
    FutureProvider<List<LanguagePack>>((ref) async {
  final refreshCount = ref.watch(languagePackCatalogRefreshProvider);
  return ref
      .watch(languagePackServiceProvider)
      .fetchManifest(forceRefresh: refreshCount > 0);
});

final downloadedLanguagesProvider =
    StateNotifierProvider<DownloadedLanguagesNotifier, Set<String>>((ref) {
  return DownloadedLanguagesNotifier(ref.watch(languagePackServiceProvider));
});

class DownloadedLanguagesNotifier extends StateNotifier<Set<String>> {
  DownloadedLanguagesNotifier(this._service) : super(const {});
  final LanguagePackService _service;

  Future<void> loadFromDisk() async {
    state = await _service.loadAllDownloaded();
  }

  Future<Set<String>> loadFromDiskAndReturn() async {
    await loadFromDisk();
    return state;
  }

  Future<void> markDownloaded(String code) async {
    state = {...state, code};
  }

  Future<void> markRemoved(String code) async {
    state = {...state}..remove(code);
  }
}

final languageDownloadProgressProvider =
    StateProvider<Map<String, LanguageDownloadProgress>>((ref) => {});

final languageDownloadErrorProvider =
    StateProvider<Map<String, String>>((ref) => {});

Future<void> downloadLanguagePack(WidgetRef ref, LanguagePack pack) async {
  final service = ref.read(languagePackServiceProvider);
  ref.read(languageDownloadErrorProvider.notifier).update(
        (m) => {...m}..remove(pack.code),
      );
  try {
    final pending = await service.pendingProgress(pack);
    ref.read(languageDownloadProgressProvider.notifier).update(
          (m) => {...m, pack.code: pending},
        );
    await service.download(
      pack,
      onProgress: (p) {
        ref.read(languageDownloadProgressProvider.notifier).update(
              (m) => {...m, pack.code: p},
            );
      },
    );
    await ref
        .read(downloadedLanguagesProvider.notifier)
        .markDownloaded(pack.code);
    ref.read(languageDownloadErrorProvider.notifier).update(
          (m) => {...m}..remove(pack.code),
        );
  } catch (e) {
    ref.read(languageDownloadErrorProvider.notifier).update(
          (m) => {...m, pack.code: e.toString()},
        );
  } finally {
    ref.read(languageDownloadProgressProvider.notifier).update(
          (m) => {...m}..remove(pack.code),
        );
  }
}

Future<void> deleteLanguagePack(WidgetRef ref, LanguagePack pack) async {
  final service = ref.read(languagePackServiceProvider);
  await service.delete(pack);
  await ref.read(downloadedLanguagesProvider.notifier).markRemoved(pack.code);
}
