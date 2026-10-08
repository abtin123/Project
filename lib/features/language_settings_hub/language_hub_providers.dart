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

/// فهرست کشورها از همان MapCatalogService واقعی (کش‌شده، با فهرست پیش‌فرض
/// آفلاین به‌عنوان fallback) — نه یک منبع جدید.
final mapCatalogProvider = FutureProvider<MapCatalog>((ref) async {
  return ref.watch(mapCatalogServiceProvider).load();
});

/// زبان رابط برنامه را تغییر می‌دهد و در تنظیمات ذخیره می‌کند. صفحهٔ زبان
/// (LanguageHubScreen) این تابع را هم برای فارسی/انگلیسیِ همراه اپ و هم
/// برای زبان‌های دانلودشده صدا می‌زند.
Future<void> selectAppLanguage(WidgetRef ref, String code) async {
  if (AppStrings.supportedBundledLanguageCodes.contains(code) && code != 'fa') {
    await AppStrings.loadBundledLanguage(code);
  }
  ref.read(languageProvider.notifier).state = code;
  await ref
      .read(settingsRepositoryProvider)
      .setValue(SettingsRepository.keyLanguage, code);
}
