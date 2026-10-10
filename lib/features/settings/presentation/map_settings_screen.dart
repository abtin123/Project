import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../abtinmap/abm_models.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../../../shared/providers/abm_poi_visibility_providers.dart';
import '../../../shared/providers/app_settings_providers.dart';
import '../../../shared/providers/map_style_providers.dart';
import '../../../shared/widgets/bottom_nav.dart';
import '../../../shared/widgets/page_header.dart';
import '../../language_settings_hub/language_hub_models.dart';
import '../../language_settings_hub/language_hub_providers.dart';
import '../../offline_maps/presentation/download_map_screen.dart';
import '../../routing/data/routing_provider.dart';
import '../data/settings_repository.dart';
import '../domain/appearance_settings.dart';
import 'appearance_settings_providers.dart';
import 'map_palette_editor.dart';
import 'settings_repository_provider.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

const Map<int, (String, IconData, Color)> _poiInfo = {
  AbmKlass.poiFuel: (
    'poi_fuel',
    Icons.local_gas_station_rounded,
    Color(0xFFFFB454)
  ),
  AbmKlass.poiParking: (
    'poi_parking',
    Icons.local_parking_rounded,
    Color(0xFF69B8FF)
  ),
  AbmKlass.poiSpeedCamera: (
    'poi_speed_camera',
    Icons.speed_rounded,
    Color(0xFFFF6680)
  ),
  AbmKlass.poiSpeedBump: (
    'poi_speed_bump',
    Icons.warning_amber_rounded,
    Color(0xFFFFC247)
  ),
  AbmKlass.poiTrafficLight: (
    'poi_traffic_light',
    Icons.traffic_rounded,
    Color(0xFF62D78D)
  ),
  AbmKlass.poiHospital: (
    'poi_health',
    Icons.local_hospital_rounded,
    Color(0xFFFF7F7F)
  ),
  AbmKlass.poiRestaurant: (
    'poi_public',
    Icons.place_rounded,
    Color(0xFFB68CFF)
  ),
};

const Map<int, String> _poiAsset = {
  AbmKlass.poiSpeedCamera: 'assets/sprites/route_camera.png',
  AbmKlass.poiSpeedBump: 'assets/sprites/route_speed_bump.png',
  AbmKlass.poiTrafficLight: 'assets/sprites/route_traffic_light.png',
};

class MapSettingsScreen extends ConsumerStatefulWidget {
  const MapSettingsScreen({super.key});

  @override
  ConsumerState<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends ConsumerState<MapSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    final appearance = ref.watch(appearanceSettingsProvider);
    final mapTilt = ref.watch(mapTiltProvider);
    final poiVisible = ref.watch(abmPoiVisibilityProvider);
    final allPoiVisible = poiVisible == null;
    final routingEngine = ref.watch(routingEngineProvider);
    final mapStyleMode = ref.watch(mapStyleModeProvider);
    final offlineAtlasReady =
        ref.watch(offlineAtlasReadyProvider).valueOrNull ?? false;
    String t(String key) => AppStrings.get(context, ref, key);

    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: PageHeader(title: t('map_settings')),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.12,
            colors: [accent.withOpacity(0.15), AppColors.background(context)],
          ),
        ),
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, BottomNav.contentBottomPadding(context)),
              children: [
                _GlassSection(
                  icon: Icons.layers_rounded,
                  iconColor: const Color(0xFF5F9DFF),
                  title: t('map_display'),
                  expanded: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Caption(t('map_source')),
                      _ChoicePill(
                        label: t('offline_map'),
                        icon: Icons.offline_bolt_rounded,
                        selected: routingEngine == RoutingEngine.abtinmap,
                        enabled: offlineAtlasReady,
                        onTap: offlineAtlasReady
                            ? () => _setRoutingEngine(RoutingEngine.abtinmap)
                            : null,
                      ),
                      if (!offlineAtlasReady)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            AppStrings.literal(
                                'ابتدا یک نقشه را از بخش دانلود نقشه دریافت کنید؛ سپس حالت آفلاین فعال می‌شود.'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: AppColors.textMuted(context),
                              fontSize: 11,
                              height: 1.45,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      _ChoicePill(
                        label: AppStrings.literal('نقشه و مسیریابی آنلاین'),
                        icon: Icons.public_rounded,
                        selected: routingEngine == RoutingEngine.online,
                        onTap: () => _setRoutingEngine(RoutingEngine.online),
                      ),
                      if (routingEngine == RoutingEngine.online)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            AppStrings.literal(
                                'نقشه و مسیر از اینترنت دریافت می‌شوند؛ برای استفادهٔ تولیدیِ پرترافیک، endpoint اختصاصی مسیریابی تنظیم شود.'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: AppColors.textMuted(context),
                              fontSize: 11,
                              height: 1.45,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      _Caption(t('map_color_mode')),
                      Row(
                        children: [
                          Expanded(
                            child: _ChoicePill(
                              label: t('day_mode'),
                              icon: Icons.light_mode_rounded,
                              selected: mapStyleMode == MapStyleMode.day,
                              onTap: () => _setMapStyleMode(MapStyleMode.day),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ChoicePill(
                              label: t('night_mode'),
                              icon: Icons.dark_mode_rounded,
                              selected: mapStyleMode == MapStyleMode.night,
                              onTap: () => _setMapStyleMode(MapStyleMode.night),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _SettingSwitch(
                        icon: Icons.view_in_ar_rounded,
                        color: const Color(0xFFAF7BFF),
                        title: t('map_three_d'),
                        subtitle: t('map_three_d_desc'),
                        value: appearance.mapPerspective.name == 'threeD',
                        onChanged: (value) => ref
                            .read(appearanceSettingsProvider.notifier)
                            .update((settings) => settings.copyWith(
                                  mapPerspective: value
                                      ? MapPerspective.threeD
                                      : MapPerspective.twoD,
                                )),
                      ),
                      if (appearance.mapPerspective.name == 'threeD') ...[
                        const SizedBox(height: 8),
                        Text('${t('map_angle')}: ${mapTilt.round()}°',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                color: AppColors.textSecondary(context),
                                fontSize: 12)),
                        Slider(
                          value: mapTilt.clamp(0.0, 60.0),
                          min: 0,
                          max: 60,
                          divisions: 12,
                          activeColor: accent,
                          onChanged: (value) =>
                              ref.read(mapTiltProvider.notifier).state = value,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const MapPaletteEditor(),
                const SizedBox(height: 12),
                _GlassSection(
                  icon: Icons.location_on_rounded,
                  iconColor: const Color(0xFF49C7E7),
                  title: t('poi_map_title'),
                  expanded: true,
                  child: Column(
                    children: [
                      _SettingSwitch(
                        icon: Icons.visibility_rounded,
                        color: const Color(0xFF49C7E7),
                        title: t('show_all_categories'),
                        subtitle: t('poi_selection_desc'),
                        value: allPoiVisible,
                        onChanged: (value) {
                          if (value) {
                            ref
                                .read(abmPoiVisibilityProvider.notifier)
                                .showAll();
                          } else {
                            ref
                                .read(abmPoiVisibilityProvider.notifier)
                                .hideAll();
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      for (final klass in _poiInfo.keys)
                        _PoiToggle(
                          label: t(_poiInfo[klass]!.$1),
                          info: _poiInfo[klass]!,
                          asset: _poiAsset[klass],
                          value: allPoiVisible ||
                              (poiVisible?.contains(klass) ?? false),
                          visibleLabel: t('poi_visible'),
                          hiddenLabel: t('poi_hidden'),
                          onChanged: (value) => ref
                              .read(abmPoiVisibilityProvider.notifier)
                              .setKlassEnabled(klass, value),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const DownloadMapScreen()),
                    ),
                    icon: const AppIcon(Icons.download_rounded, size: 21),
                    label: Text(
                      AppStrings.literal('دانلود نقشه ها'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  t('poi_selection_desc'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textMuted(context),
                        height: 1.5,
                      ),
                ),
              ],
            ),
            const BottomNav(currentPage: NavKey.settings),
          ],
        ),
      ),
    );
  }

  Future<void> _setMapStyleMode(MapStyleMode mode) async {
    ref.read(mapStyleModeProvider.notifier).state = mode;
    await ref.read(settingsRepositoryProvider).setValue(
          SettingsRepository.keyMapDisplayMode,
          mode.name,
        );
  }

  Future<void> _setRoutingEngine(RoutingEngine engine) async {
    if (engine == RoutingEngine.abtinmap &&
        !await ref.read(offlineAtlasReadyProvider.future)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.literal(
                'برای حالت آفلاین ابتدا نقشه را دانلود کنید.')),
          ),
        );
      }
      return;
    }
    await setRoutingEngineFromWidget(ref, engine);
  }
}

class _GlassSection extends StatelessWidget {
  const _GlassSection({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.expanded,
    required this.child,
    this.onToggle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final bool expanded;
  final Widget child;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.glassPanelSoft(context),
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: AppColors.glassBorder(context), width: 0.7),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        AppIcon(
                          expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textMuted(context),
                        ),
                        const Spacer(),
                        Text(title,
                            textAlign: TextAlign.right,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  color: AppColors.textPrimary(context),
                                  fontWeight: FontWeight.w800,
                                )),
                        const SizedBox(width: 9),
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: iconColor.withOpacity(0.18)),
                          child: AppIcon(icon, color: iconColor, size: 17),
                        ),
                      ],
                    ),
                  ),
                ),
                if (expanded) ...[const SizedBox(height: 13), child],
              ],
            ),
          ),
        ),
      );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text,
            textAlign: TextAlign.right,
            style: TextStyle(
                color: AppColors.textSecondary(context), fontSize: 12)),
      );
}

class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    required this.label,
    required this.icon,
    required this.selected,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(13),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? accent.withOpacity(0.16)
                : Colors.black.withOpacity(enabled ? 0.10 : 0.05),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? accent.withOpacity(0.92)
                  : AppColors.glassBorder(context),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(
                icon,
                color: selected
                    ? accent
                    : (enabled
                        ? AppColors.textSecondary(context)
                        : AppColors.textMuted(context)),
                size: 17,
              ),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    color: selected
                        ? AppColors.textPrimary(context)
                        : (enabled
                            ? AppColors.textSecondary(context)
                            : AppColors.textMuted(context)),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.asset,
  });

  final String? asset;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Switch.adaptive(
                value: value, onChanged: onChanged, activeColor: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(title,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: AppColors.textPrimary(context),
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 9),
            if (asset != null)
              Image.asset(asset!,
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high)
            else
              AppIcon(icon, color: color, size: 20),
          ],
        ),
      );
}

class _PoiToggle extends StatelessWidget {
  const _PoiToggle({
    required this.label,
    required this.info,
    required this.value,
    required this.visibleLabel,
    required this.hiddenLabel,
    required this.onChanged,
    this.asset,
  });
  final String? asset;
  final String label;
  final (String, IconData, Color) info;
  final bool value;
  final String visibleLabel;
  final String hiddenLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _SettingSwitch(
        asset: asset,
        icon: info.$2,
        color: info.$3,
        title: label,
        subtitle: value ? visibleLabel : hiddenLabel,
        value: value,
        onChanged: onChanged,
      );
}
