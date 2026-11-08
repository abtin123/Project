import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repository.dart';
import '../domain/appearance_settings.dart';
import 'settings_repository_provider.dart';

export '../domain/appearance_settings.dart';


final appearanceSettingsProvider =
    StateNotifierProvider<AppearanceSettingsNotifier, AppearanceSettings>(
      (ref) => AppearanceSettingsNotifier(ref),
    );

class AppearanceSettingsNotifier extends StateNotifier<AppearanceSettings> {
  AppearanceSettingsNotifier(this._ref) : super(const AppearanceSettings());

  final Ref _ref;

  SettingsRepository get _repo => _ref.read(settingsRepositoryProvider);

  Future<void> load() async {
    final raw = await _repo.getValue(SettingsRepository.keyAppearanceSettings);
    if (raw != null && raw.isNotEmpty) {
      state = AppearanceSettings.deserialize(raw);
      return;
    }
    await _migrateLegacyIfNeeded();
  }

  Future<void> _migrateLegacyIfNeeded() async {
    var s = const AppearanceSettings();
    var changed = false;

    Future<String?> v(String key) => _repo.getValue(key);

    final pinColor = await v(SettingsRepository.keyPinColor);
    if (pinColor != null && pinColor.isNotEmpty) {
      final c = int.tryParse(pinColor);
      if (c != null) {
        s = s.copyWith(pinColor: Color(c));
        changed = true;
      }
    }
    final pinShadow = await v(SettingsRepository.keyPinShadow);
    if (pinShadow != null && pinShadow.isNotEmpty) {
      s = s.copyWith(pinShadowEnabled: pinShadow == 'true');
      changed = true;
    }
    final pinSize = await v(SettingsRepository.keyPinSize);
    if (pinSize != null && pinSize.isNotEmpty) {
      final d = double.tryParse(pinSize);
      if (d != null) {
        s = s.copyWith(pinSize: d);
        changed = true;
      }
    }
    final lineStyle = await v(SettingsRepository.keyRouteLineStyle);
    if (lineStyle != null) {
      for (final style in RouteLineStyle.values) {
        if (style.name == lineStyle) {
          s = s.copyWith(routeLineStyle: style);
          changed = true;
          break;
        }
      }
    }
    final tilt = await v(SettingsRepository.keyMapTilt);
    if (tilt != null && tilt.isNotEmpty) {
      final d = double.tryParse(tilt);
      if (d != null) {
        s = s.copyWith(mapTilt: d);
        changed = true;
      }
    }
    final mainZoom = await v(SettingsRepository.keyElementMainRoadZoom);
    if (mainZoom != null && mainZoom.isNotEmpty) {
      final i = int.tryParse(mainZoom);
      if (i != null) {
        s = s.copyWith(elementMainRoadMinZoom: i);
        changed = true;
      }
    }
    final subZoom = await v(SettingsRepository.keyElementSubRoadZoom);
    if (subZoom != null && subZoom.isNotEmpty) {
      final i = int.tryParse(subZoom);
      if (i != null) {
        s = s.copyWith(elementSubRoadMinZoom: i);
        changed = true;
      }
    }
    final alleyZoom = await v(SettingsRepository.keyElementAlleyZoom);
    if (alleyZoom != null && alleyZoom.isNotEmpty) {
      final i = int.tryParse(alleyZoom);
      if (i != null) {
        s = s.copyWith(elementAlleyMinZoom: i);
        changed = true;
      }
    }
    final routeColorIdx = await v(SettingsRepository.keyRouteColor);
    if (routeColorIdx != null) {
      final i = int.tryParse(routeColorIdx);
      if (i != null) {
        s = s.copyWith(routeColorIndex: i < 0 ? -1 : i);
        changed = true;
      }
    }
    final routeHex = await v(SettingsRepository.keyRouteColorHex);
    if (routeHex != null && routeHex.isNotEmpty) {
      s = s.copyWith(routeColorHex: routeHex);
      changed = true;
    }
    final routeGlowHex = await v(SettingsRepository.keyRouteColorGlowHex);
    if (routeGlowHex != null && routeGlowHex.isNotEmpty) {
      s = s.copyWith(routeColorGlowHex: routeGlowHex);
      changed = true;
    }
    final routeWidth = await _repo.getDouble(
      SettingsRepository.keyRouteWidth,
      fallback: s.routeWidth,
    );
    if (routeWidth != s.routeWidth) {
      s = s.copyWith(routeWidth: routeWidth.clamp(4.0, 22.0).toDouble());
      changed = true;
    }
    final glowEnabled = await _repo.getBool(
      SettingsRepository.keyRouteGlowEnabled,
      fallback: s.routeGlowEnabled,
    );
    s = s.copyWith(routeGlowEnabled: glowEnabled);
    final glowIntensity = await _repo.getDouble(
      SettingsRepository.keyRouteGlowIntensity,
      fallback: s.routeGlowIntensity,
    );
    s = s.copyWith(
      routeGlowIntensity: glowIntensity.clamp(0.0, 1.0).toDouble(),
    );

    final weatherPos = await v(SettingsRepository.keyWeatherPosition);
    if (weatherPos != null) {
      for (final p in WeatherWidgetPosition.values) {
        if (p.name == weatherPos) {
          final isBottom =
              p == WeatherWidgetPosition.bottomLeft ||
              p == WeatherWidgetPosition.bottomRight;
          final isRight =
              p == WeatherWidgetPosition.topRight ||
              p == WeatherWidgetPosition.bottomRight;
          s = s.copyWith(
            weatherPosition: p,
            weatherVerticalPercent: isBottom ? 100.0 : 0.0,
            weatherHorizontalPercent: isRight ? 100.0 : 0.0,
          );
          changed = true;
          break;
        }
      }
    }
    final weatherSize = await _repo.getDouble(
      SettingsRepository.keyWeatherSize,
      fallback: s.weatherSize,
    );
    s = s.copyWith(weatherSize: weatherSize.clamp(70.0, 150.0).toDouble());
    final weatherBg = await v(SettingsRepository.keyWeatherBgColor);
    if (weatherBg != null && weatherBg.isNotEmpty) {
      final c = int.tryParse(weatherBg);
      if (c != null) {
        s = s.copyWith(weatherBgColor: Color(c));
        changed = true;
      }
    }
    final weatherOpacity = await _repo.getDouble(
      SettingsRepository.keyWeatherBgOpacity,
      fallback: s.weatherBgOpacity,
    );
    s = s.copyWith(weatherBgOpacity: weatherOpacity.clamp(0.0, 1.0).toDouble());

    final vehicleModelIdx = await v(SettingsRepository.keyVehicleModelIndex);
    if (vehicleModelIdx != null) {
      final i = int.tryParse(vehicleModelIdx);
      if (i != null) {
        s = s.copyWith(vehicleModelIndex: i);
        changed = true;
      }
    }
    final vehicleType = await v(SettingsRepository.keyVehicleType);
    if (vehicleType == 'bmwI8') {
      s = s.copyWith(activeTab: AppearanceTab.car);
    } else if (vehicleType == 'arrow') {
      s = s.copyWith(activeTab: AppearanceTab.pin);
    }

    final themeMode = await v(SettingsRepository.keyThemeMode);
    if (themeMode == 'light') {
      s = s.copyWith(themeMode: ThemeMode.light);
    } else if (themeMode == 'dark') {
      s = s.copyWith(themeMode: ThemeMode.dark);
    } else if (themeMode == 'system') {
      s = s.copyWith(themeMode: ThemeMode.system);
    }
    final appColor = await v(SettingsRepository.keyAppColor);
    if (appColor != null) {
      final c = int.tryParse(appColor);
      if (c != null) {
        s = s.copyWith(primaryColor: Color(0xFF000000 | (c & 0x00FFFFFF)));
        changed = true;
      }
    }
    final perspective = await v(SettingsRepository.keyMapPerspective);
    if (perspective == '2d') {
      s = s.copyWith(mapPerspective: MapPerspective.twoD);
    } else if (perspective == '3d') {
      s = s.copyWith(mapPerspective: MapPerspective.threeD);
    }

    s = s.copyWith(preset: AppearancePresets.detect(s));
    state = s;
    if (changed) {
      await _persist();
    }
  }

  Future<void> _persist() async {
    await _repo.setValue(
      SettingsRepository.keyAppearanceSettings,
      state.serialize(),
    );
  }

  Future<void> update(
    AppearanceSettings Function(AppearanceSettings) fn,
  ) async {
    final next = fn(state);
    state = next.copyWith(preset: AppearancePresets.detect(next));
    await _persist();
  }

  Future<void> applyPreset(AppearancePreset preset) async {
    state = AppearancePresets.apply(state, preset);
    await _persist();
  }

  Future<void> reset() async {
    state = const AppearanceSettings();
    await _repo.setValue(SettingsRepository.keyAppearanceSettings, '');
  }
}

class AppearanceResetController {
  AppearanceResetController(this._ref);
  final Ref _ref;

  Future<void> apply() =>
      _ref.read(appearanceSettingsProvider.notifier).reset();
}


final pinColorProvider = Provider<Color>(
  (ref) => ref.watch(appearanceSettingsProvider).pinColor,
);

final routeColorHexProvider = Provider<String>(
  (ref) => ref.watch(appearanceSettingsProvider).routeColorHex,
);

final routeLineStyleProvider = Provider<RouteLineStyle>(
  (ref) => ref.watch(appearanceSettingsProvider).routeLineStyle,
);


class _SyncedField<T> extends StateNotifier<T> {
  _SyncedField(this._ref, this._read, this._write)
    : super(_read(_ref.read(appearanceSettingsProvider))) {
    _sub = _ref.listen<AppearanceSettings>(appearanceSettingsProvider, (
      prev,
      next,
    ) {
      final v = _read(next);
      if (v != super.state) super.state = v;
    });
  }

  final Ref _ref;
  final T Function(AppearanceSettings) _read;
  final AppearanceSettings Function(AppearanceSettings, T) _write;
  late final ProviderSubscription<AppearanceSettings> _sub;

  @override
  set state(T value) {
    super.state = value;
    _ref
        .read(appearanceSettingsProvider.notifier)
        .update((s) => _write(s, value));
  }

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

final activeAppearanceTabProvider =
    StateNotifierProvider<_SyncedField<AppearanceTab>, AppearanceTab>(
      (ref) => _SyncedField(
        ref,
        (s) => s.activeTab,
        (s, v) => s.copyWith(activeTab: v),
      ),
    );

final carSizePercentProvider =
    StateNotifierProvider<_SyncedField<double>, double>(
      (ref) => _SyncedField(
        ref,
        (s) => s.carSizePercent,
        (s, v) => s.copyWith(carSizePercent: v.clamp(70.0, 150.0).toDouble()),
      ),
    );

final navigationCameraTiltProvider =
    StateNotifierProvider<_SyncedField<double>, double>(
      (ref) => _SyncedField(
        ref,
        (s) => s.navigationCameraTiltDegrees,
        (s, v) => s.copyWith(
          navigationCameraTiltDegrees: v.clamp(0.0, 90.0).toDouble(),
        ),
      ),
    );

final vehicleViewAngleProvider =
    StateNotifierProvider<_SyncedField<double>, double>(
      (ref) => _SyncedField(
        ref,
        (s) => s.vehicleViewAngleDegrees,
        (s, v) =>
            s.copyWith(vehicleViewAngleDegrees: v.clamp(0.0, 60.0).toDouble()),
      ),
    );

final pinShadowEnabledProvider =
    StateNotifierProvider<_SyncedField<bool>, bool>(
      (ref) => _SyncedField(
        ref,
        (s) => s.pinShadowEnabled,
        (s, v) => s.copyWith(pinShadowEnabled: v),
      ),
    );

final pinSizeProvider = StateNotifierProvider<_SyncedField<double>, double>(
  (ref) => _SyncedField(
    ref,
    (s) => s.pinSize,
    (s, v) => s.copyWith(pinSize: v.clamp(50.0, 150.0).toDouble()),
  ),
);

final mapTiltProvider = StateNotifierProvider<_SyncedField<double>, double>(
  (ref) =>
      _SyncedField(ref, (s) => s.mapTilt, (s, v) => s.copyWith(mapTilt: v)),
);

class _BoolSettingNotifier extends StateNotifier<bool> {
  _BoolSettingNotifier(this._ref, this._key, {required bool fallback})
    : super(fallback) {
    _load();
  }

  final Ref _ref;
  final String _key;

  Future<void> _load() async {
    final value = await _ref
        .read(settingsRepositoryProvider)
        .getBool(_key, fallback: state);
    if (mounted) state = value;
  }

  @override
  set state(bool value) {
    super.state = value;
    _ref.read(settingsRepositoryProvider).setBool(_key, value);
  }
}

final weatherWidgetEnabledProvider =
    StateNotifierProvider<_BoolSettingNotifier, bool>(
      (ref) => _BoolSettingNotifier(
        ref,
        SettingsRepository.keyWeatherEnabled,
        fallback: true,
      ),
    );

final airQualityWidgetEnabledProvider =
    StateNotifierProvider<_BoolSettingNotifier, bool>(
      (ref) => _BoolSettingNotifier(
        ref,
        SettingsRepository.keyAirQualityEnabled,
        fallback: true,
      ),
    );

final clockWidgetEnabledProvider =
    StateNotifierProvider<_BoolSettingNotifier, bool>(
      (ref) => _BoolSettingNotifier(
        ref,
        SettingsRepository.keyClockEnabled,
        fallback: true,
      ),
    );

final batteryWidgetEnabledProvider =
    StateNotifierProvider<_BoolSettingNotifier, bool>(
      (ref) => _BoolSettingNotifier(
        ref,
        SettingsRepository.keyBatteryEnabled,
        fallback: true,
      ),
    );


