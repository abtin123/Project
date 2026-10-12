import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/bottom_nav.dart';
import '../../../shared/widgets/page_header.dart';
import '../../settings/presentation/appearance/shared_widgets.dart'
    show ColorPickerSheet;
import '../domain/hud_maneuver_icon.dart';
import 'hud_settings_providers.dart';
import 'hud_styles.dart';
import 'package:abtin_maps/shared/widgets/app_icon.dart';

class HudSettingsScreen extends ConsumerWidget {
  const HudSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.primaryAccent(context);
    final settings = ref.watch(hudSettingsProvider);
    final notifier = ref.read(hudSettingsProvider.notifier);
    String t(String key) => AppStrings.get(context, ref, key);

    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: PageHeader(
        title: t('hud_title'),
        actions: [
          _InfoButton(color: accent, text: t('hud_note')),
        ],
      ),
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
                _HudGlassCard(
                  child: _SwitchRow(
                    icon: Icons.view_in_ar_rounded,
                    iconColor: accent,
                    title: t('hud_enable'),
                    value: settings.enabled,
                    onChanged: (v) =>
                        notifier.update((s) => s.copyWith(enabled: v)),
                  ),
                ),
                const SizedBox(height: 14),
                Opacity(
                  opacity: settings.enabled ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !settings.enabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _HudGlassCard(
                          child: _NavRow(
                            icon: Icons.dashboard_customize_rounded,
                            iconColor: Color.lerp(accent, Colors.cyan, 0.5)!,
                            title: t('hud_style'),
                            subtitle: AppStrings.getWithParams(
                                context,
                                ref,
                                'hud_style_type',
                                {'n': settings.style.index + 1}),
                            onTap: () => _showStyleDialog(context, ref, t),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: _PercentSlider(
                            icon: Icons.brightness_6_rounded,
                            iconColor: Color.lerp(accent, Colors.amber, 0.55)!,
                            title: t('hud_brightness'),
                            value: settings.brightnessPercent,
                            min: 10,
                            max: 100,
                            onChanged: (v) => notifier.update(
                                (s) => s.copyWith(brightnessPercent: v)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: _SwitchRow(
                            icon: Icons.flip_rounded,
                            iconColor: Color.lerp(accent, Colors.purple, 0.55)!,
                            title: t('hud_mirror'),
                            subtitle: t('hud_mirror_desc'),
                            value: settings.mirrorImage,
                            onChanged: (v) => notifier
                                .update((s) => s.copyWith(mirrorImage: v)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: _PercentSlider(
                            icon: Icons.aspect_ratio_rounded,
                            iconColor: Color.lerp(accent, Colors.blue, 0.55)!,
                            title: t('hud_scale'),
                            value: settings.scalePercent,
                            min: 50,
                            max: 130,
                            onChanged: (v) => notifier
                                .update((s) => s.copyWith(scalePercent: v)),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: _NavRow(
                            icon: Icons.open_with_rounded,
                            iconColor: Color.lerp(accent, Colors.green, 0.55)!,
                            title: t('hud_position'),
                            subtitle: t('hud_position_desc'),
                            onTap: () =>
                                _showPositionSheet(context, ref, t, accent),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  t('hud_visible_info'),
                                  style: TextStyle(
                                    color: AppColors.textPrimary(context),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _InfoToggleGrid(
                                accent: accent,
                                settings: settings,
                                notifier: notifier,
                                t: t,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudGlassCard(
                          child: _ColorsSection(
                            settings: settings,
                            notifier: notifier,
                            t: t,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _HudPreviewCard(
                          settings: settings,
                          t: t,
                          sampleDistance: AppStrings.getWithParams(
                              context, ref, 'route_distance_m',
                              {'value': 500}),
                        ),
                      ],
                    ),
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

  void _showStyleDialog(
      BuildContext context, WidgetRef ref, String Function(String) t) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (ctx, dialogRef, _) {
          final settings = dialogRef.watch(hudSettingsProvider);
          final notifier = dialogRef.read(hudSettingsProvider.notifier);
          final accent = AppColors.primaryAccent(ctx);
          return Dialog(
            backgroundColor: AppColors.glassPanel(ctx),
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    child: Text(
                      t('hud_style'),
                      style: TextStyle(
                        color: AppColors.textPrimary(ctx),
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final style in HudStyle.values)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        notifier.update((s) => s.copyWith(style: style));
                        Navigator.of(dialogContext).pop();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            AppIcon(
                              settings.style == style
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              color: settings.style == style
                                  ? accent
                                  : AppColors.textMuted(ctx),
                            ),
                            const SizedBox(width: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 150,
                                height: 150 * kHudCanvasH / kHudCanvasW,
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: HudStyleView(
                                    settings: settings,
                                    styleOverride: style,
                                    data: _sampleFrame(ctx, dialogRef),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                AppStrings.getWithParams(ctx, dialogRef,
                                    'hud_style_type', {'n': style.index + 1}),
                                style: TextStyle(
                                  color: AppColors.textPrimary(ctx),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPositionSheet(BuildContext context, WidgetRef ref,
      String Function(String) t, Color accent) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Consumer(
        builder: (ctx, sheetRef, _) {
          final settings = sheetRef.watch(hudSettingsProvider);
          final notifier = sheetRef.read(hudSettingsProvider.notifier);
          return _HudGlassCard(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    t('hud_position'),
                    style: TextStyle(
                      color: AppColors.textPrimary(ctx),
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _AxisPad(
                  accent: accent,
                  x: settings.horizontalOffset,
                  y: settings.verticalOffset,
                  onChanged: (dx, dy) => notifier.update((s) =>
                      s.copyWith(horizontalOffset: dx, verticalOffset: dy)),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => notifier.update((s) =>
                        s.copyWith(horizontalOffset: 0, verticalOffset: 0)),
                    child: AppIcon(Icons.restart_alt_rounded,
                        color: accent, size: 26),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}


class _HudGlassCard extends StatelessWidget {
  const _HudGlassCard({required this.child, this.margin});
  final Widget child;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) => Padding(
        padding: margin ?? EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.glassPanelSoft(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: AppColors.glassBorder(context), width: 0.7),
              ),
              child: child,
            ),
          ),
        ),
      );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Switch.adaptive(
            value: value,
            activeColor: AppColors.primaryAccent(context),
            onChanged: onChanged,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _Badge(icon: icon, color: iconColor),
        ],
      );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            AppIcon(Icons.chevron_left_rounded,
                color: AppColors.textMuted(context)),
            const SizedBox(width: 4),
            _Badge(icon: Icons.center_focus_strong_rounded, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: AppColors.textMuted(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _Badge(icon: icon, color: iconColor),
          ],
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: color.withOpacity(0.16)),
        child: AppIcon(icon, size: 17, color: color),
      );
}

class _PercentSlider extends StatelessWidget {
  const _PercentSlider({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primaryAccent(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _Badge(icon: icon, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.center,
                child: Text(
                  '$value%',
                  style: TextStyle(
                    color: iconColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: iconColor,
                  inactiveTrackColor: accent.withOpacity(0.18),
                  thumbColor: iconColor,
                  overlayColor: iconColor.withOpacity(0.12),
                  trackHeight: 4,
                ),
                child: Slider(
                  value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  onChanged: (v) => onChanged(v.round()),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$min%',
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11)),
                  Text('$max%',
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoToggleGrid extends StatelessWidget {
  const _InfoToggleGrid({
    required this.accent,
    required this.settings,
    required this.notifier,
    required this.t,
  });

  final Color accent;
  final HudSettings settings;
  final HudSettingsNotifier notifier;
  final String Function(String) t;

  @override
  Widget build(BuildContext context) {
    final items = <_InfoToggleItem>[
      _InfoToggleItem(
        icon: Icons.speed_rounded,
        color: Color.lerp(accent, Colors.tealAccent, 0.4)!,
        label: t('hud_info_speed'),
        value: settings.showSpeed,
        onChanged: (v) => notifier.update((s) => s.copyWith(showSpeed: v)),
      ),
      _InfoToggleItem(
        icon: Icons.speed_rounded,
        color: Color.lerp(accent, Colors.redAccent, 0.55)!,
        label: t('hud_info_speed_limit'),
        value: settings.showSpeedLimit,
        onChanged: (v) => notifier.update((s) => s.copyWith(showSpeedLimit: v)),
      ),
      _InfoToggleItem(
        icon: Icons.turn_right_rounded,
        color: Color.lerp(accent, Colors.orangeAccent, 0.5)!,
        label: t('hud_info_maneuver'),
        value: settings.showNextManeuver,
        onChanged: (v) =>
            notifier.update((s) => s.copyWith(showNextManeuver: v)),
      ),
      _InfoToggleItem(
        icon: Icons.location_on_rounded,
        color: Color.lerp(accent, Colors.purpleAccent, 0.5)!,
        label: t('hud_info_distance'),
        value: settings.showDistanceToManeuver,
        onChanged: (v) =>
            notifier.update((s) => s.copyWith(showDistanceToManeuver: v)),
      ),
      _InfoToggleItem(
        icon: Icons.explore_rounded,
        color: Color.lerp(accent, Colors.blueAccent, 0.5)!,
        label: t('hud_info_heading'),
        value: settings.showCompassHeading,
        onChanged: (v) =>
            notifier.update((s) => s.copyWith(showCompassHeading: v)),
      ),
      _InfoToggleItem(
        icon: Icons.warning_rounded,
        color: Color.lerp(accent, Colors.redAccent, 0.7)!,
        label: t('hud_info_route_alerts'),
        value: settings.showRouteAlerts,
        onChanged: (v) =>
            notifier.update((s) => s.copyWith(showRouteAlerts: v)),
      ),
      _InfoToggleItem(
        icon: Icons.schedule_rounded,
        color: Color.lerp(accent, Colors.yellowAccent, 0.5)!,
        label: t('hud_info_clock'),
        value: settings.showClock,
        onChanged: (v) => notifier.update((s) => s.copyWith(showClock: v)),
      ),
      _InfoToggleItem(
        icon: Icons.more_horiz_rounded,
        color: accent,
        label: t('hud_info_other'),
        value: settings.showOtherInfo,
        onChanged: (v) => notifier.update((s) => s.copyWith(showOtherInfo: v)),
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
      ),
      itemBuilder: (context, i) => items[i],
    );
  }
}

class _InfoToggleItem extends StatelessWidget {
  const _InfoToggleItem({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: value
                  ? color.withOpacity(0.6)
                  : AppColors.glassBorder(context),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.16),
                ),
                child: AppIcon(icon, size: 18, color: color),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              AppIcon(
                value ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 15,
                color: value ? color : AppColors.textMuted(context),
              ),
            ],
          ),
        ),
      );
}

HudFrameData _sampleFrame(BuildContext context, WidgetRef ref) {
  String t(String key) => AppStrings.get(context, ref, key);
  return HudFrameData(
    speedKmh: 115,
    speedUnit: t('hud_speed_unit'),
    speedLimit: 90,
    distanceLabel: AppStrings.getWithParams(
        context, ref, 'route_distance_m', {'value': 500}),
    maneuverIcon: hudManeuverIcon('turn', 'right'),
    arrivedLabel: t('hud_arrived'),
    clockText: '12:00',
    compassLabel: t('hud_dir_ne'),
    alertAsset: 'assets/sprites/route_camera.png',
    remainingLabel: '${t('hud_remaining')}: 12.4',
    noNavigationLabel: t('hud_no_active_navigation'),
  );
}

class _HudPreviewCard extends ConsumerWidget {
  const _HudPreviewCard({
    required this.settings,
    required this.t,
    required this.sampleDistance,
  });
  final HudSettings settings;
  final String Function(String) t;
  final String sampleDistance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.primaryAccent(context);
    return _HudGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              t('hud_preview'),
              style: TextStyle(
                color: AppColors.textPrimary(context),
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: accent.withOpacity(0.35)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: AspectRatio(
                aspectRatio: kHudCanvasW / kHudCanvasH,
                child: Opacity(
                  opacity:
                      (settings.brightnessPercent / 100).clamp(0.35, 1.0),
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: HudStyleView(
                      settings: settings,
                      data: _sampleFrame(context, ref),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorsSection extends StatelessWidget {
  const _ColorsSection({
    required this.settings,
    required this.notifier,
    required this.t,
  });
  final HudSettings settings;
  final HudSettingsNotifier notifier;
  final String Function(String) t;

  @override
  Widget build(BuildContext context) {
    final palette = settings.palette;
    final defaults = HudPalette.defaultFor(settings.style);
    Widget row(
      String title,
      Color current,
      Color fallback,
      bool custom,
      HudSettings Function(HudSettings s, int? argb) apply,
    ) =>
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final picked = await ColorPickerSheet.show(context, current);
            if (picked != null) {
              await notifier.update((s) => apply(s, picked.value));
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                if (custom)
                  IconButton(
                    tooltip: t('hud_color_default'),
                    icon: AppIcon(Icons.restart_alt_rounded,
                        color: AppColors.textMuted(context)),
                    onPressed: () => notifier.update((s) =>
                        apply(s.copyWith(), null)),
                  ),
                const Spacer(),
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: current,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54, width: 1.5),
                  ),
                ),
              ],
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            t('hud_colors'),
            style: TextStyle(
              color: AppColors.textPrimary(context),
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
        const SizedBox(height: 6),
        row(t('hud_color_arrow'), palette.arrow, defaults.arrow,
            settings.arrowColor != null, _setArrow),
        row(t('hud_color_distance'), palette.distance, defaults.distance,
            settings.distanceColor != null, _setDistance),
        row(t('hud_color_speed'), palette.speed, defaults.speed,
            settings.speedColor != null, _setSpeed),
        row(t('hud_color_info'), palette.info, defaults.info,
            settings.infoColor != null, _setInfo),
        if (settings.hasCustomColors) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () =>
                notifier.update((s) => s.copyWith(resetColors: true)),
            icon: const AppIcon(Icons.restart_alt_rounded, size: 18),
            label: Text(t('hud_color_reset')),
          ),
        ],
      ],
    );
  }

  static HudSettings _clone(HudSettings s,
          {int? arrow, int? distance, int? speed, int? info}) =>
      HudSettings(
        enabled: s.enabled,
        brightnessPercent: s.brightnessPercent,
        mirrorImage: s.mirrorImage,
        scalePercent: s.scalePercent,
        showSpeed: s.showSpeed,
        showSpeedLimit: s.showSpeedLimit,
        showNextManeuver: s.showNextManeuver,
        showDistanceToManeuver: s.showDistanceToManeuver,
        showCompassHeading: s.showCompassHeading,
        showRouteAlerts: s.showRouteAlerts,
        showOtherInfo: s.showOtherInfo,
        horizontalOffset: s.horizontalOffset,
        verticalOffset: s.verticalOffset,
        style: s.style,
        showClock: s.showClock,
        arrowColor: arrow,
        distanceColor: distance,
        speedColor: speed,
        infoColor: info,
      );

  static HudSettings _setArrow(HudSettings s, int? v) => _clone(s,
      arrow: v,
      distance: s.distanceColor,
      speed: s.speedColor,
      info: s.infoColor);
  static HudSettings _setDistance(HudSettings s, int? v) => _clone(s,
      arrow: s.arrowColor, distance: v, speed: s.speedColor, info: s.infoColor);
  static HudSettings _setSpeed(HudSettings s, int? v) => _clone(s,
      arrow: s.arrowColor,
      distance: s.distanceColor,
      speed: v,
      info: s.infoColor);
  static HudSettings _setInfo(HudSettings s, int? v) => _clone(s,
      arrow: s.arrowColor,
      distance: s.distanceColor,
      speed: s.speedColor,
      info: v);
}

class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: AppIcon(Icons.info_outline_rounded, color: color),
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(text)),
          );
        },
      );
}

class _AxisPad extends StatefulWidget {
  const _AxisPad({
    required this.accent,
    required this.x,
    required this.y,
    required this.onChanged,
  });

  final Color accent;
  final double x;
  final double y;
  final void Function(double dx, double dy) onChanged;

  @override
  State<_AxisPad> createState() => _AxisPadState();
}

class _AxisPadState extends State<_AxisPad> {
  static const double _size = 180;

  void _handle(Offset local) {
    final dx = ((local.dx / _size) * 2 - 1).clamp(-1.0, 1.0);
    final dy = ((local.dy / _size) * 2 - 1).clamp(-1.0, 1.0);
    widget.onChanged(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onPanStart: (d) => _handle(d.localPosition),
        onPanUpdate: (d) => _handle(d.localPosition),
        onTapDown: (d) => _handle(d.localPosition),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.glassBorder(context)),
          ),
          child: Align(
            alignment: Alignment(widget.x, widget.y),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accent,
                boxShadow: [
                  BoxShadow(
                      color: widget.accent.withOpacity(0.5), blurRadius: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
