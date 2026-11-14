import 'package:drift/drift.dart';
import '../../../core/database/app_database.dart';

class SettingsRepository {
  final AppDatabase db;
  const SettingsRepository(this.db);

  static const keyVoiceEnabled = 'voice_enabled';
  static const keyVoiceVolume = 'voice_volume';
  static const keyVoiceRate = 'voice_rate';
  static const keyVoiceFirstAlertDistanceMeters =
      'voice_first_alert_distance_m';
  static const keyAlertsVoiceEnabled = 'alerts_voice_enabled';
  static const keyThemeMode = 'theme_mode';
  static const keyLanguage = 'language';
  static const keyActiveMapName = 'active_map_name';
  static const keyVehicleType = 'vehicle_type';

  static const keyVehicleModelIndex = 'vehicle_model_index';
  static const keyRouteColor = 'route_color';
  static const keyRouteWidth = 'route_width';
  static const keyRouteGlowEnabled = 'route_glow_enabled';
  static const keyRouteGlowIntensity = 'route_glow_intensity';
  static const keyAppColor = 'app_color';
  static const keyMapDisplayMode = 'map_display_mode';
  static const keyOfflinePaletteLight = 'offline_palette_light';
  static const keyOfflinePaletteDark = 'offline_palette_dark';

  static const keyMapPerspective = 'map_perspective';

  static const keyAppearanceSettings = 'appearance_settings_v2';


  static const keyPinColor = 'pin_color';

  static const keyPinShadow = 'pin_shadow';

  static const keyPinSize = 'pin_size';

  static const keyRouteLineStyle = 'route_line_style';

  static const keyMapTilt = 'map_tilt';

  static const keyElementMainRoadZoom = 'element_main_road_zoom';
  static const keyElementSubRoadZoom = 'element_sub_road_zoom';
  static const keyElementAlleyZoom = 'element_alley_zoom';

  static const keyRouteColorHex = 'route_color_hex';
  static const keyRouteColorGlowHex = 'route_color_glow_hex';

  static const keyRoutingEngine = 'routing_engine';

  static const keyLastMapCenterLat = 'last_map_center_lat';
  static const keyLastMapCenterLng = 'last_map_center_lng';
  static const keyLastMapZoom = 'last_map_zoom';
  static const keyLastMapBearing = 'last_map_bearing';
  static const keyLastMapTilt = 'last_map_tilt';
  static const keyLastMapFollowVehicle = 'last_map_follow_vehicle';

  static const keyVisiblePoiKlasses = 'visible_poi_klasses';

  static const keyWeatherEnabled = 'weather_enabled';
  static const keyAirQualityEnabled = 'air_quality_enabled';
  static const keyClockEnabled = 'clock_enabled';
  static const keyBatteryEnabled = 'battery_enabled';

  static const keyWeatherPosition = 'weather_position';

  static const keyWeatherSize = 'weather_size';

  static const keyWeatherBgColor = 'weather_bg_color';

  static const keyWeatherBgOpacity = 'weather_bg_opacity';

  static const keyUpdatePromptedVersion = 'update_prompted_version';

  Future<String?> getValue(String key) async {
    final row = await (db.select(
      db.appSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value) async {
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value),
        );
  }

  Future<bool> getBool(String key, {required bool fallback}) async {
    final v = await getValue(key);
    if (v == null) return fallback;
    return v == 'true';
  }

  Future<void> setBool(String key, bool value) =>
      setValue(key, value.toString());

  Future<double> getDouble(String key, {required double fallback}) async {
    final v = await getValue(key);
    if (v == null) return fallback;
    return double.tryParse(v) ?? fallback;
  }

  Future<void> setDouble(String key, double value) =>
      setValue(key, value.toString());
}
