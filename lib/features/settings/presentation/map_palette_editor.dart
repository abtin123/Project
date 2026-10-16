import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/providers/app_settings_providers.dart' show languageProvider;
import '../../../shared/providers/map_style_providers.dart';
import 'appearance/shared_widgets.dart' show AppColorSwatch, ColorPickerSheet;
import 'package:abtin_maps/shared/widgets/app_icon.dart';

class MapPaletteEditor extends ConsumerStatefulWidget {
  const MapPaletteEditor({super.key});

  @override
  ConsumerState<MapPaletteEditor> createState() => _MapPaletteEditorState();
}

class _MapPaletteEditorState extends ConsumerState<MapPaletteEditor> {
  int? _zoom;

  @override
  Widget build(BuildContext context) {
    String t(String key) => AppStrings.get(context, ref, key);
    final mode = ref.watch(mapStyleModeProvider);
    final palette = mode == MapStyleMode.day
        ? ref.watch(offlineLightPaletteProvider)
        : ref.watch(offlineDarkPaletteProvider);
    final notifier = mode == MapStyleMode.day
        ? ref.read(offlineLightPaletteProvider.notifier)
        : ref.read(offlineDarkPaletteProvider.notifier);
    final presets = mode == MapStyleMode.day
        ? const <(MapPalettePreset, String, IconData)>[
            (
              MapPalettePreset.kartaDay,
              'map_preset_karta_day',
              Icons.wb_sunny_rounded
            ),
            (
              MapPalettePreset.sandstoneDay,
              'map_preset_sandstone_day',
              Icons.landscape_rounded
            ),
          ]
        : const <(MapPalettePreset, String, IconData)>[
            (
              MapPalettePreset.kartaNight,
              'map_preset_karta_night',
              Icons.dark_mode_rounded
            ),
            (
              MapPalettePreset.midnightNight,
              'map_preset_midnight_night',
              Icons.nightlight_round
            ),
          ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.glassPanelSoft(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.glassBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('map_palette_title'),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: AppColors.textPrimary(context),
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            t('map_palette_desc'),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary(context),
                  height: 1.4,
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                _PresetButton(
                  label: t(preset.$2),
                  icon: preset.$3,
                  onTap: () => notifier.applyPreset(preset.$1),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _PaletteGroup(
            title: t('map_palette_land_group'),
            items: <(OfflinePaletteField, String)>[
              (OfflinePaletteField.background, t('map_color_ground')),
              (OfflinePaletteField.urban, t('map_color_urban')),
              (OfflinePaletteField.green, t('map_color_green')),
              (OfflinePaletteField.water, t('map_color_water')),
              (OfflinePaletteField.label, t('map_color_labels')),
            ],
            palette: palette,
            onColor: notifier.setColor,
          ),
          const SizedBox(height: 14),
          _PaletteGroup(
            title: t('map_palette_roads_group'),
            items: <(OfflinePaletteField, String)>[
              (OfflinePaletteField.roadMotorway, t('map_color_motorway')),
              (OfflinePaletteField.roadTrunk, t('map_color_trunk')),
              (OfflinePaletteField.roadPrimary, t('map_color_primary')),
              (OfflinePaletteField.roadSecondary, t('map_color_secondary')),
              (OfflinePaletteField.roadLocal, t('map_color_local')),
            ],
            palette: palette,
            onColor: notifier.setColor,
          ),
          const SizedBox(height: 14),
          Text(
            t('map_road_width'),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppColors.textSecondary(context),
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            t('map_road_zoom_desc'),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary(context),
                  height: 1.4,
                ),
          ),
          const SizedBox(height: 10),
          _ZoomTabs(
            selected: _zoom,
            allLabel: t('map_road_zoom_all'),
            zoomLabelTemplate: t('map_road_zoom_label'),
            zoomRangeTemplate: t('map_road_zoom_range'),
            persianDigits: ref.watch(languageProvider) == 'fa',
            hasOverride: palette.hasRoadZoomOverride,
            onChanged: (z) => setState(() => _zoom = z),
          ),
          const SizedBox(height: 8),
          for (final entry in <(RoadWidthClass, String)>[
            (RoadWidthClass.motorway, t('map_color_motorway')),
            (RoadWidthClass.trunk, t('map_color_trunk')),
            (RoadWidthClass.primary, t('map_color_primary')),
            (RoadWidthClass.secondary, t('map_color_secondary')),
            (RoadWidthClass.local, t('map_color_local')),
          ])
            _RoadWidthControl(
              key: ValueKey(
                  'road-width-${mode.name}-${_zoom ?? 'all'}-${entry.$1.name}'),
              label: entry.$2,
              valueTemplate: t('map_road_width_value'),
              value: _zoom == null
                  ? palette.roadWidthOf(entry.$1)
                  : palette.roadWidthAt(entry.$1, _zoom!),
              onCommit: (v) => _zoom == null
                  ? notifier.setRoadWidth(entry.$1, v)
                  : notifier.setRoadWidthAtZoom(entry.$1, _zoom!, v),
            ),
          if (_zoom != null && palette.hasRoadZoomOverride(_zoom!))
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _PresetButton(
                label: t('map_road_zoom_reset'),
                icon: Icons.restart_alt_rounded,
                onTap: () => notifier.resetRoadZoom(_zoom!),
              ),
            ),
        ],
      ),
    );
  }
}

class _ZoomTabs extends StatelessWidget {
  const _ZoomTabs({
    required this.selected,
    required this.allLabel,
    required this.zoomLabelTemplate,
    required this.zoomRangeTemplate,
    required this.persianDigits,
    required this.hasOverride,
    required this.onChanged,
  });

  final bool persianDigits;
  final int? selected;
  final String allLabel;
  final String zoomLabelTemplate;
  final String zoomRangeTemplate;
  final bool Function(int zoom) hasOverride;
  final ValueChanged<int?> onChanged;

  static String _fa(int n) {
    const d = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    return '$n'.split('').map((c) => d[int.parse(c)]).join();
  }

  @override
  Widget build(BuildContext context) {
    String num(int z) => persianDigits ? _fa(z) : '$z';
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: const Color(0xFF04132B).withValues(alpha: .85),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF2F5BFF), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5BFF).withValues(alpha: .18),
            blurRadius: 14,
          ),
        ],
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _ZoomTabButton(
                label: allLabel,
                selected: selected == null,
                marked: false,
                onTap: () => onChanged(null),
              ),
              for (final band in kRoadZoomBands) ...[
                const SizedBox(width: 4),
                _ZoomTabButton(
                  label: zoomRangeTemplate
                      .replaceAll('{a}', num(band.$1))
                      .replaceAll('{b}', num(band.$2)),
                  selected: selected == band.$1,
                  marked: hasOverride(band.$1),
                  onTap: () => onChanged(band.$1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomTabButton extends StatelessWidget {
  const _ZoomTabButton({
    required this.label,
    required this.selected,
    required this.marked,
    required this.onTap,
  });

  final String label;
  final bool selected;

  final bool marked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF4B2BD8), Color(0xFF2F7BFF)],
                  )
                : null,
            border: selected
                ? Border.all(color: const Color(0xFF4F8DFF), width: 1.2)
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF3F6BFF).withValues(alpha: .45),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (marked) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? Colors.white : const Color(0xFF4F8DFF),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: .82),
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
}

class _RoadWidthControl extends StatefulWidget {
  const _RoadWidthControl({
    super.key,
    required this.label,
    required this.valueTemplate,
    required this.value,
    required this.onCommit,
  });

  final String label;
  final String valueTemplate;
  final double value;
  final ValueChanged<double> onCommit;

  @override
  State<_RoadWidthControl> createState() => _RoadWidthControlState();
}

class _RoadWidthControlState extends State<_RoadWidthControl> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final current =
        (_drag ?? widget.value).clamp(kRoadWidthMin, kRoadWidthMax).toDouble();
    final valueLabel = widget.valueTemplate
        .replaceAll('{value}', '${(current * 100).round()}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              valueLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
            ),
            Text(
              widget.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppColors.textPrimary(context),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        Slider(
          min: kRoadWidthMin,
          max: kRoadWidthMax,
          divisions: 42,
          value: current,
          label: valueLabel,
          onChanged: (v) => setState(() => _drag = v),
          onChangeEnd: (v) {
            setState(() => _drag = null);
            widget.onCommit(v);
          },
        ),
      ],
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: AppIcon(icon, size: 17),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: BorderSide(color: accent.withValues(alpha: 0.7)),
      ),
    );
  }
}

class _PaletteGroup extends StatelessWidget {
  const _PaletteGroup({
    required this.title,
    required this.items,
    required this.palette,
    required this.onColor,
  });

  final String title;
  final List<(OfflinePaletteField, String)> items;
  final OfflineMapPalette palette;
  final Future<void> Function(OfflinePaletteField field, Color color) onColor;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppColors.textSecondary(context),
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            alignment: WrapAlignment.end,
            children: [
              for (final item in items)
                _ColorControl(
                  label: item.$2,
                  color: palette.colorOf(item.$1),
                  onColor: (color) => onColor(item.$1, color),
                ),
            ],
          ),
        ],
      );
}

class _ColorControl extends StatelessWidget {
  const _ColorControl({
    required this.label,
    required this.color,
    required this.onColor,
  });

  final String label;
  final Color color;
  final Future<void> Function(Color color) onColor;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 104,
        child: Column(
          children: [
            AppColorSwatch(
              color: color,
              selected: false,
              onTap: () async {
                final selected = await ColorPickerSheet.show(context, color);
                if (selected == null || !context.mounted) return;
                await onColor(selected);
              },
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
            ),
          ],
        ),
      );
}
