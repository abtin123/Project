import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/localization/app_localizations.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../features/settings/presentation/settings_repository_provider.dart';
import '../../features/settings/presentation/appearance_settings_providers.dart';
import '../../features/settings/domain/appearance_settings.dart';
import '../../features/hud/presentation/hud_settings_providers.dart';
import 'map_style_providers.dart';
import 'abtinmap_providers.dart';
import 'abm_poi_visibility_providers.dart';
import '../../features/routing/data/routing_provider.dart';
import '../../features/language_settings/presentation/language_pack_providers.dart';
import 'app_notice_provider.dart';

export '../../features/settings/domain/appearance_settings.dart'
    show MapPerspective;

const defaultAppPrimaryColor = Color(0xFF8A3FD0);

const appColorPresets = <Color>[
  defaultAppPrimaryColor,
  Color(0xFF7C4DFF),
  Color(0xFF2F6FE0),
  Color(0xFF3FD0E0),
  Color(0xFF52C24C),
  Color(0xFFE0D23F),
  Color(0xFFE0973F),
  Color(0xFFE0523F),
];

final languageProvider = StateProvider<String>((ref) => 'fa');

final themeModeProvider = Provider<ThemeMode>(
    (ref) => ref.watch(appearanceSettingsProvider).themeMode);

final primaryColorProvider = Provider<Color>(
    (ref) => ref.watch(appearanceSettingsProvider).primaryColor);

final mapPerspectiveProvider = Provider<MapPerspective>(
    (ref) => ref.watch(appearanceSettingsProvider).mapPerspective);

final appSettingsInitProvider = FutureProvider<void>((ref) async {
  final repo = ref.watch(settingsRepositoryProvider);

  final savedEngineFuture = repo.getValue(SettingsRepository.keyRoutingEngine);
  final savedLangFuture = repo.getValue(SettingsRepository.keyLanguage);
  final savedActiveMapFuture =
      repo.getValue(SettingsRepository.keyActiveMapName);
  final savedMapDisplayModeFuture =
      repo.getValue(SettingsRepository.keyMapDisplayMode);
  final downloadedLanguagesFuture =
      ref.read(downloadedLanguagesProvider.notifier).loadFromDiskAndReturn();

  final downloadedLanguages = await downloadedLanguagesFuture;
  final savedEngine = await savedEngineFuture;
  ref.read(routingEngineProvider.notifier).state =
      RoutingEngineX.parse(savedEngine);

  final savedLang = await savedLangFuture;
  if (savedLang != null &&
      (AppStrings.supportedBundledLanguageCodes.contains(savedLang) ||
          downloadedLanguages.contains(savedLang))) {
    if (!downloadedLanguages.contains(savedLang) && savedLang != 'fa') {
      await AppStrings.loadBundledLanguage(savedLang);
    }
    ref.read(languageProvider.notifier).state = savedLang;
  }

  final savedActiveMap = await savedActiveMapFuture;
  if (savedActiveMap != null && savedActiveMap.isNotEmpty) {
    ref.read(abmActiveMapNameProvider.notifier).state = savedActiveMap;
    final normalized = savedActiveMap.toLowerCase().endsWith('.abm')
        ? savedActiveMap.substring(0, savedActiveMap.length - 4)
        : savedActiveMap;
    if (normalized.isNotEmpty) {
      ref.read(activeOfflineMapIdProvider.notifier).state =
          normalized.toUpperCase();
    }

    if (RoutingEngineX.parse(savedEngine) == RoutingEngine.abtinmap) {
      try {
        final ready = await hasActiveOfflineAtlas(ref);
        if (!ready) {
          ref.read(routingEngineProvider.notifier).state = RoutingEngine.online;
          await repo.setValue(
            SettingsRepository.keyRoutingEngine,
            RoutingEngine.online.storageValue,
          );
        }
      } catch (error, stack) {
        
        ref.read(routingEngineProvider.notifier).state = RoutingEngine.online;
      }
    }
  }

  await Future.wait<void>([
    ref.read(appearanceSettingsProvider.notifier).load(),
    ref.read(appNoticeProvider.notifier).load(),
    ref.read(offlineLightPaletteProvider.notifier).load(),
    ref.read(offlineDarkPaletteProvider.notifier).load(),
    ref.read(abmPoiVisibilityProvider.notifier).load(),
    ref.read(hudSettingsProvider.notifier).load(),
  ]);

  final savedMapDisplayMode = await savedMapDisplayModeFuture;
  final savedThemeIsLight =
      ref.read(appearanceSettingsProvider).themeMode == ThemeMode.light;
  if (savedMapDisplayMode == MapStyleMode.day.name) {
    ref.read(mapStyleModeProvider.notifier).state = MapStyleMode.day;
  } else if (savedMapDisplayMode == MapStyleMode.night.name) {
    ref.read(mapStyleModeProvider.notifier).state = MapStyleMode.night;
  } else if (savedThemeIsLight) {
    ref.read(mapStyleModeProvider.notifier).state = MapStyleMode.day;
  }
});

class AppSettingsNotifier extends StateNotifier<Map<String, String>> {
  final AppDatabase db;

  AppSettingsNotifier(this.db) : super({});
}
