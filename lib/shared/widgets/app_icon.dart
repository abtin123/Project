import 'package:flutter/material.dart';

/// Drop-in replacement for [Icon]: uses the unified PNG icon set
/// (assets/icons) when one exists for the IconData, else falls back to Icon.
final Map<IconData, String> _kAppIcons = <IconData, String>{
  Icons.home_rounded: 'home',
  Icons.search_rounded: 'search',
  Icons.near_me_rounded: 'nav_arrow',
  Icons.navigation_rounded: 'nav_arrow',
  Icons.location_on_rounded: 'pin_red',
  Icons.my_location_rounded: 'target',
  Icons.explore_rounded: 'compass',
  Icons.directions_car_filled_rounded: 'car',
  Icons.palette_rounded: 'palette',
  Icons.layers_rounded: 'layers',
  Icons.warning_amber_rounded: 'warning',
  Icons.warning_rounded: 'warning',
  Icons.volume_up_rounded: 'sound',
  Icons.work_rounded: 'briefcase',
  Icons.route_rounded: 'route',
  Icons.alt_route_rounded: 'route',
  Icons.traffic_rounded: 'traffic_light',
  Icons.star_rounded: 'star',
  Icons.cloud_off_rounded: 'cloud_off',
  Icons.wifi_off_rounded: 'cloud_off',
  Icons.map_rounded: 'map',
  Icons.settings_rounded: 'gear',
  Icons.download_rounded: 'download_map',
  Icons.system_update_alt_rounded: 'download_map',
  Icons.turn_left_rounded: 'turn_left',
  Icons.turn_right_rounded: 'turn_right',
  Icons.turn_sharp_left_rounded: 'turn_sharp_left',
  Icons.turn_sharp_right_rounded: 'turn_sharp_left:flip',
  Icons.turn_slight_left_rounded: 'turn_slight_left',
  Icons.turn_slight_right_rounded: 'turn_slight_left:flip',
  Icons.u_turn_left_rounded: 'u_turn',
  Icons.u_turn_right_rounded: 'u_turn:flip',
  Icons.roundabout_left_rounded: 'roundabout',
  Icons.roundabout_right_rounded: 'roundabout',
};

class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.textDirection,
    this.shadows,
    this.fill,
    this.weight,
    this.grade,
    this.opticalSize,
    this.applyTextScaling,
    this.blendMode,
  });

  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;
  final TextDirection? textDirection;
  final List<Shadow>? shadows;
  final double? fill;
  final double? weight;
  final double? grade;
  final double? opticalSize;
  final bool? applyTextScaling;
  final BlendMode? blendMode;

  @override
  Widget build(BuildContext context) {
    final spec = icon == null ? null : _kAppIcons[icon!];
    if (spec == null) {
      return Icon(
        icon,
        key: key,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
        textDirection: textDirection,
        shadows: shadows,
        fill: fill,
        weight: weight,
        grade: grade,
        opticalSize: opticalSize,
        applyTextScaling: applyTextScaling,
        blendMode: blendMode,
      );
    }
    final parts = spec.split(':');
    final s = size ?? IconTheme.of(context).size ?? 24.0;
    Widget w = Image.asset(
      'assets/icons/${parts.first}.png',
      width: s,
      height: s,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      semanticLabel: semanticLabel,
    );
    if (parts.length > 1) {
      w = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: w,
      );
    }
    final a = color?.opacity ?? 1.0;
    if (a < 1.0) w = Opacity(opacity: a, child: w);
    return SizedBox(width: s, height: s, child: w);
  }
}
