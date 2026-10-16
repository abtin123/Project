import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/app_localizations.dart';

import '../../core/localization/locale_flags.dart';
import '../offline_maps/data/map_catalog.dart';
import '../offline_maps/presentation/offline_maps_providers.dart';
import '../offline_maps/presentation/map_download_providers.dart';
import '../../shared/providers/abtinmap_providers.dart';
import '../../shared/providers/map_style_providers.dart';
import '../../shared/providers/app_settings_providers.dart';
import '../settings/presentation/settings_repository_provider.dart';
import '../settings/data/settings_repository.dart';
import 'language_hub_models.dart';

final mapCatalogProvider = FutureProvider<MapCatalog>((ref) async {
  return ref.watch(mapCatalogServiceProvider).load();
});

Future<void> selectAppLanguage(WidgetRef ref, String code) async {
  if (AppStrings.supportedBundledLanguageCodes.contains(code) && code != 'fa') {
    await AppStrings.loadBundledLanguage(code);
  }
  ref.read(languageProvider.notifier).state = code;
  await ref
      .read(settingsRepositoryProvider)
      .setValue(SettingsRepository.keyLanguage, code);
}
