import 'dart:convert';
import 'package:flutter/material.dart';

enum RouteLineStyle { solid, dotted, dashed, dotDash }

enum AppearanceTab { car, pin }

enum MapPerspective { threeD, twoD }

enum WeatherWidgetPosition { topLeft, topRight, bottomLeft, bottomRight }

enum AppearancePreset { minimal, neon, classic, custom }

enum BatteryIconOrientation { horizontal, vertical }

enum AppFontFamily { vazirmatn, sans, serif, monospace }

extension AppFontFamilyX on AppFontFamily {
  String? get flutterFamily => switch (this) {
    AppFontFamily.vazirmatn => 'Vazirmatn',
    AppFontFamily.sans => 'sans-serif',
    AppFontFamily.serif => 'serif',
    AppFontFamily.monospace => 'monospace',
  };
}

enum AppFontWeightOption {
  asDesigned,
  light,
  regular,
  medium,
  semiBold,
  bold,
  extraBold,
}

extension AppFontWeightOptionX on AppFontWeightOption {
  FontWeight? get flutterWeight {
    switch (this) {
      case AppFontWeightOption.asDesigned:
        return null;
      case AppFontWeightOption.light:
        return FontWeight.w300;
      case AppFontWeightOption.regular:
        return FontWeight.w400;
      case AppFontWeightOption.medium:
        return FontWeight.w500;
      case AppFontWeightOption.semiBold:
        return FontWeight.w600;
      case AppFontWeightOption.bold:
        return FontWeight.w700;
      case AppFontWeightOption.extraBold:
        return FontWeight.w800;
    }
  }
}

enum RoutePlanningMode { economic, fastest, shortest }

@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.preset = AppearancePreset.custom,
    this.activeTab = AppearanceTab.car,
    this.vehicleModelIndex = 0,
    this.carSizePercent = 80.0,
    this.navigationCameraTiltDegrees = 42.0,
    this.vehicleViewAngleDegrees = 0.0,
    this.pinColor = const Color(0xFF8A3FD0),
    this.pinShadowEnabled = true,
    this.pinSize = 100.0,
    this.routeColorIndex = -1,
    this.routeColorHex = '#00E5FF',
    this.routeColorGlowHex = '#7FF3FF',
    this.routeWidth = 8.0,
    this.routeGlowEnabled = true,
    this.routeGlowIntensity = 0.8,
    this.routeLineStyle = RouteLineStyle.solid,
    this.avoidTolls = false,
    this.avoidTraffic = false,
    this.avoidUnpavedRoads = false,
    this.avoidHighways = false,
    this.avoidFerries = false,
    this.showLiveTraffic = false,
    this.showRouteWarnings = false,
    this.autoRerouteEnabled = true,
    this.routePlanningMode = RoutePlanningMode.fastest,
    this.mapPerspective = MapPerspective.threeD,
    this.mapTilt = 45.0,
    this.elementMainRoadMinZoom = 14,
    this.elementSubRoadMinZoom = 9,
    this.elementAlleyMinZoom = 6,
    this.weatherPosition = WeatherWidgetPosition.topRight,
    this.weatherVerticalPercent = 0.0,
    this.weatherHorizontalPercent = 100.0,
    this.weatherSize = 100.0,
    this.weatherBgColor = Colors.black,
    this.weatherBgOpacity = 0.55,
    this.weatherContentAlign = 50.0,
    this.weatherTextColor = Colors.white,
    this.weatherTextSize = 100.0,
    this.weatherFontFamily = AppFontFamily.vazirmatn,
    this.systemInfoEnabled = false,
    this.systemInfoVerticalPercent = 100.0,
    this.systemInfoHorizontalPercent = 0.0,
    this.systemInfoSize = 100.0,
    this.systemInfoBgColor = Colors.black,
    this.systemInfoBgOpacity = 0.55,
    this.systemInfoContentAlign = 0.0,
    this.systemInfoTextColor = Colors.white,
    this.systemInfoBatteryTextColor = Colors.transparent,
    this.systemInfoBatteryTextWeight = AppFontWeightOption.bold,
    this.systemInfoClockFontSize = 100.0,
    this.systemInfoBatteryFontSize = 100.0,
    this.systemInfoClockFontFamily = AppFontFamily.vazirmatn,
    this.systemInfoBatteryFontFamily = AppFontFamily.vazirmatn,
    this.systemInfoBatteryOrientation = BatteryIconOrientation.horizontal,
    this.systemInfoBatterySizePercent = 100.0,
    this.systemInfoBatteryColor = Colors.transparent,
    this.routeCardHeight = 0.5,
    this.routeCardArrowSize = 0.5,
    this.routeCardArrowThickness = 0.72,
    this.routeCardArrowColor = const Color(0xFF0A90FB),
    this.routeCardArrowOutlineColor = Colors.white,
    this.routeCardArrowBorderColor = Colors.black,
    this.routeCardDistanceFontSize = 0.8,
    this.routeCardFontFamily = AppFontFamily.vazirmatn,
    this.routeCardFontWeight = AppFontWeightOption.extraBold,
    this.routeCardDistanceColor = const Color(0xFF34D058),
    this.routeCardStreetFontSize = 0.8,
    this.routeCardStreetColor = Colors.white,
    this.routeCardStatsFontSize = 0.5,
    this.routeCardStatsLabelFontSize = 0.5,
    this.routeCardStatsValueFontSize = 0.5,
    this.routeCardStatsColor = Colors.white,
    this.routeCardStatsIconColor = const Color(0xFF29A9FF),
    this.routeCardOpacity = 0.97,
    this.routeCardCornerRadius = 0.45,
    this.routeCardGlowIntensity = 0.18,
    this.routeCardBackgroundColor = const Color(0xFF0A1626),
    this.routeCardBorderColor = const Color(0xFF2E6FC9),
    this.routeCardGlowColor = const Color(0xFF1E63C9),
    this.roundaboutRingColor = const Color(0xFF0A90FB),
    this.roundaboutEntranceColor = const Color(0xFF0A90FB),
    this.roundaboutMainExitColor = const Color(0xFF0A90FB),
    this.roundaboutSecondaryExitColor = const Color(0xFF0A90FB),
    this.roundaboutLaneColor = Colors.white,
    this.roundaboutGlowColor = const Color(0xFF35D6D1),
    this.roundaboutOpacity = 1.0,
    this.roundaboutEntranceOpacity = .65,
    this.roundaboutSecondaryOpacity = .28,
    this.roundaboutLaneOpacity = .62,
    this.roundaboutGlowOpacity = .18,
    this.roundaboutSizePercent = 100.0,
    this.routeAlertSizePercent = 100.0,
    this.roadDirectionArrowSizePercent = 70.0,
    this.roadDirectionArrowColor = const Color(0xFF1F2937),
    this.bottomNavBackgroundColor = const Color(0xFF173080),
    this.bottomNavBorderColor = const Color(0xFF3D71F5),
    this.bottomNavGlowColor = const Color(0xFF305AFF),
    this.bottomNavIconColor = const Color(0xFF8FA7D8),
    this.bottomNavIconActiveColor = Colors.white,
    this.bottomNavHomeButtonColor = const Color(0xFF7A2FF0),
    this.bottomNavOpacity = 1.0,
    this.themeMode = ThemeMode.dark,
    this.primaryColor = const Color(0xFF8A3FD0),
    this.appFontSizePercent = 100.0,
    this.appFontColor = Colors.transparent,
    this.appFontWeightOption = AppFontWeightOption.asDesigned,
    this.appFontFamily = AppFontFamily.vazirmatn,
  });

  final AppearancePreset preset;

  final AppearanceTab activeTab;
  final int vehicleModelIndex;
  final double carSizePercent;

  final double navigationCameraTiltDegrees;

  final double vehicleViewAngleDegrees;

  final Color pinColor;
  final bool pinShadowEnabled;
  final double pinSize;

  final int routeColorIndex;
  final String routeColorHex;
  final String routeColorGlowHex;
  final double routeWidth;
  final bool routeGlowEnabled;
  final double routeGlowIntensity;
  final RouteLineStyle routeLineStyle;
  final bool avoidTolls;
  final bool avoidTraffic;
  final bool avoidUnpavedRoads;
  final bool avoidHighways;
  final bool avoidFerries;
  final bool showLiveTraffic;
  final bool showRouteWarnings;
  final bool autoRerouteEnabled;
  final RoutePlanningMode routePlanningMode;

  final MapPerspective mapPerspective;
  final double mapTilt;

  final int elementMainRoadMinZoom;
  final int elementSubRoadMinZoom;
  final int elementAlleyMinZoom;

  final WeatherWidgetPosition weatherPosition;
  final double weatherVerticalPercent;
  final double weatherHorizontalPercent;
  final double weatherSize;
  final Color weatherBgColor;
  final double weatherBgOpacity;

  final double weatherContentAlign;

  final Color weatherTextColor;
  final double weatherTextSize;
  final AppFontFamily weatherFontFamily;

  final bool systemInfoEnabled;
  final double systemInfoVerticalPercent;
  final double systemInfoHorizontalPercent;
  final double systemInfoSize;
  final Color systemInfoBgColor;
  final double systemInfoBgOpacity;
  final double systemInfoContentAlign;
  final Color systemInfoTextColor;

  final Color systemInfoBatteryTextColor;
  final AppFontWeightOption systemInfoBatteryTextWeight;
  final double systemInfoClockFontSize;
  final double systemInfoBatteryFontSize;
  final AppFontFamily systemInfoClockFontFamily;
  final AppFontFamily systemInfoBatteryFontFamily;

  final BatteryIconOrientation systemInfoBatteryOrientation;

  final double systemInfoBatterySizePercent;

  final Color systemInfoBatteryColor;


  final double routeCardHeight;

  final double routeCardArrowSize;

  final double routeCardArrowThickness;

  final Color routeCardArrowColor;

  final Color routeCardArrowOutlineColor;
  final Color routeCardArrowBorderColor;

  final double routeCardDistanceFontSize;

  final AppFontFamily routeCardFontFamily;
  final AppFontWeightOption routeCardFontWeight;

  final Color routeCardDistanceColor;

  final double routeCardStreetFontSize;

  final Color routeCardStreetColor;

  final double routeCardStatsFontSize;

  final double routeCardStatsLabelFontSize;

  final double routeCardStatsValueFontSize;

  final Color routeCardStatsColor;

  final Color routeCardStatsIconColor;

  final double routeCardOpacity;

  final double routeCardCornerRadius;

  final double routeCardGlowIntensity;

  final Color routeCardBackgroundColor;

  final Color routeCardBorderColor;

  final Color routeCardGlowColor;

  final Color roundaboutRingColor;
  final Color roundaboutEntranceColor;
  final Color roundaboutMainExitColor;
  final Color roundaboutSecondaryExitColor;
  final Color roundaboutLaneColor;
  final Color roundaboutGlowColor;
  final double roundaboutOpacity;
  final double roundaboutEntranceOpacity;
  final double roundaboutSecondaryOpacity;
  final double roundaboutLaneOpacity;
  final double roundaboutGlowOpacity;
  final double roundaboutSizePercent;

  final double routeAlertSizePercent;

  final double roadDirectionArrowSizePercent;

  final Color roadDirectionArrowColor;


  final Color bottomNavBackgroundColor;

  final Color bottomNavBorderColor;

  final Color bottomNavGlowColor;

  final Color bottomNavIconColor;

  final Color bottomNavIconActiveColor;

  final Color bottomNavHomeButtonColor;

  final double bottomNavOpacity;

  final ThemeMode themeMode;
  final Color primaryColor;

  final double appFontSizePercent;

  final Color appFontColor;

  final AppFontWeightOption appFontWeightOption;
  final AppFontFamily appFontFamily;

  AppearanceSettings copyWith({
    AppearancePreset? preset,
    AppearanceTab? activeTab,
    int? vehicleModelIndex,
    double? carSizePercent,
    double? navigationCameraTiltDegrees,
    double? vehicleViewAngleDegrees,
    Color? pinColor,
    bool? pinShadowEnabled,
    double? pinSize,
    int? routeColorIndex,
    String? routeColorHex,
    String? routeColorGlowHex,
    double? routeWidth,
    bool? routeGlowEnabled,
    double? routeGlowIntensity,
    RouteLineStyle? routeLineStyle,
    bool? avoidTolls,
    bool? avoidTraffic,
    bool? avoidUnpavedRoads,
    bool? avoidHighways,
    bool? avoidFerries,
    bool? showLiveTraffic,
    bool? showRouteWarnings,
    bool? autoRerouteEnabled,
    RoutePlanningMode? routePlanningMode,
    MapPerspective? mapPerspective,
    double? mapTilt,
    int? elementMainRoadMinZoom,
    int? elementSubRoadMinZoom,
    int? elementAlleyMinZoom,
    WeatherWidgetPosition? weatherPosition,
    double? weatherVerticalPercent,
    double? weatherHorizontalPercent,
    double? weatherSize,
    Color? weatherBgColor,
    double? weatherBgOpacity,
    double? weatherContentAlign,
    Color? weatherTextColor,
    double? weatherTextSize,
    AppFontFamily? weatherFontFamily,
    bool? systemInfoEnabled,
    double? systemInfoVerticalPercent,
    double? systemInfoHorizontalPercent,
    double? systemInfoSize,
    Color? systemInfoBgColor,
    double? systemInfoBgOpacity,
    double? systemInfoContentAlign,
    Color? systemInfoTextColor,
    Color? systemInfoBatteryTextColor,
    AppFontWeightOption? systemInfoBatteryTextWeight,
    double? systemInfoClockFontSize,
    double? systemInfoBatteryFontSize,
    AppFontFamily? systemInfoClockFontFamily,
    AppFontFamily? systemInfoBatteryFontFamily,
    BatteryIconOrientation? systemInfoBatteryOrientation,
    double? systemInfoBatterySizePercent,
    Color? systemInfoBatteryColor,
    double? routeCardHeight,
    double? routeCardArrowSize,
    double? routeCardArrowThickness,
    Color? routeCardArrowColor,
    Color? routeCardArrowOutlineColor,
    Color? routeCardArrowBorderColor,
    double? routeCardDistanceFontSize,
    AppFontFamily? routeCardFontFamily,
    AppFontWeightOption? routeCardFontWeight,
    Color? routeCardDistanceColor,
    double? routeCardStreetFontSize,
    Color? routeCardStreetColor,
    double? routeCardStatsFontSize,
    double? routeCardStatsLabelFontSize,
    double? routeCardStatsValueFontSize,
    Color? routeCardStatsColor,
    Color? routeCardStatsIconColor,
    double? routeCardOpacity,
    double? routeCardCornerRadius,
    double? routeCardGlowIntensity,
    Color? routeCardBackgroundColor,
    Color? routeCardBorderColor,
    Color? routeCardGlowColor,
    Color? roundaboutRingColor,
    Color? roundaboutEntranceColor,
    Color? roundaboutMainExitColor,
    Color? roundaboutSecondaryExitColor,
    Color? roundaboutLaneColor,
    Color? roundaboutGlowColor,
    double? roundaboutOpacity,
    double? roundaboutEntranceOpacity,
    double? roundaboutSecondaryOpacity,
    double? roundaboutLaneOpacity,
    double? roundaboutGlowOpacity,
    double? roundaboutSizePercent,
    double? routeAlertSizePercent,
    double? roadDirectionArrowSizePercent,
    Color? roadDirectionArrowColor,
    Color? bottomNavBackgroundColor,
    Color? bottomNavBorderColor,
    Color? bottomNavGlowColor,
    Color? bottomNavIconColor,
    Color? bottomNavIconActiveColor,
    Color? bottomNavHomeButtonColor,
    double? bottomNavOpacity,
    ThemeMode? themeMode,
    Color? primaryColor,
    double? appFontSizePercent,
    Color? appFontColor,
    AppFontWeightOption? appFontWeightOption,
    AppFontFamily? appFontFamily,
  }) {
    return AppearanceSettings(
      preset: preset ?? this.preset,
      activeTab: activeTab ?? this.activeTab,
      vehicleModelIndex: vehicleModelIndex ?? this.vehicleModelIndex,
      carSizePercent: carSizePercent ?? this.carSizePercent,
      navigationCameraTiltDegrees:
          navigationCameraTiltDegrees ?? this.navigationCameraTiltDegrees,
      vehicleViewAngleDegrees:
          vehicleViewAngleDegrees ?? this.vehicleViewAngleDegrees,
      pinColor: pinColor ?? this.pinColor,
      pinShadowEnabled: pinShadowEnabled ?? this.pinShadowEnabled,
      pinSize: pinSize ?? this.pinSize,
      routeColorIndex: routeColorIndex ?? this.routeColorIndex,
      routeColorHex: routeColorHex ?? this.routeColorHex,
      routeColorGlowHex: routeColorGlowHex ?? this.routeColorGlowHex,
      routeWidth: routeWidth ?? this.routeWidth,
      routeGlowEnabled: routeGlowEnabled ?? this.routeGlowEnabled,
      routeGlowIntensity: routeGlowIntensity ?? this.routeGlowIntensity,
      routeLineStyle: routeLineStyle ?? this.routeLineStyle,
      avoidTolls: avoidTolls ?? this.avoidTolls,
      avoidTraffic: avoidTraffic ?? this.avoidTraffic,
      avoidUnpavedRoads: avoidUnpavedRoads ?? this.avoidUnpavedRoads,
      avoidHighways: avoidHighways ?? this.avoidHighways,
      avoidFerries: avoidFerries ?? this.avoidFerries,
      showLiveTraffic: showLiveTraffic ?? this.showLiveTraffic,
      showRouteWarnings: showRouteWarnings ?? this.showRouteWarnings,
      autoRerouteEnabled: autoRerouteEnabled ?? this.autoRerouteEnabled,
      routePlanningMode: routePlanningMode ?? this.routePlanningMode,
      mapPerspective: mapPerspective ?? this.mapPerspective,
      mapTilt: mapTilt ?? this.mapTilt,
      elementMainRoadMinZoom:
          elementMainRoadMinZoom ?? this.elementMainRoadMinZoom,
      elementSubRoadMinZoom:
          elementSubRoadMinZoom ?? this.elementSubRoadMinZoom,
      elementAlleyMinZoom: elementAlleyMinZoom ?? this.elementAlleyMinZoom,
      weatherPosition: weatherPosition ?? this.weatherPosition,
      weatherVerticalPercent:
          weatherVerticalPercent ?? this.weatherVerticalPercent,
      weatherHorizontalPercent:
          weatherHorizontalPercent ?? this.weatherHorizontalPercent,
      weatherSize: weatherSize ?? this.weatherSize,
      weatherBgColor: weatherBgColor ?? this.weatherBgColor,
      weatherBgOpacity: weatherBgOpacity ?? this.weatherBgOpacity,
      weatherContentAlign: weatherContentAlign ?? this.weatherContentAlign,
      weatherTextColor: weatherTextColor ?? this.weatherTextColor,
      weatherTextSize: weatherTextSize ?? this.weatherTextSize,
      weatherFontFamily: weatherFontFamily ?? this.weatherFontFamily,
      systemInfoEnabled: systemInfoEnabled ?? this.systemInfoEnabled,
      systemInfoVerticalPercent:
          systemInfoVerticalPercent ?? this.systemInfoVerticalPercent,
      systemInfoHorizontalPercent:
          systemInfoHorizontalPercent ?? this.systemInfoHorizontalPercent,
      systemInfoSize: systemInfoSize ?? this.systemInfoSize,
      systemInfoBgColor: systemInfoBgColor ?? this.systemInfoBgColor,
      systemInfoBgOpacity: systemInfoBgOpacity ?? this.systemInfoBgOpacity,
      systemInfoContentAlign:
          systemInfoContentAlign ?? this.systemInfoContentAlign,
      systemInfoTextColor: systemInfoTextColor ?? this.systemInfoTextColor,
      systemInfoBatteryTextColor:
          systemInfoBatteryTextColor ?? this.systemInfoBatteryTextColor,
      systemInfoBatteryTextWeight:
          systemInfoBatteryTextWeight ?? this.systemInfoBatteryTextWeight,
      systemInfoClockFontSize: systemInfoClockFontSize ?? this.systemInfoClockFontSize,
      systemInfoBatteryFontSize: systemInfoBatteryFontSize ?? this.systemInfoBatteryFontSize,
      systemInfoBatteryOrientation:
          systemInfoBatteryOrientation ?? this.systemInfoBatteryOrientation,
      systemInfoBatterySizePercent:
          systemInfoBatterySizePercent ?? this.systemInfoBatterySizePercent,
      systemInfoBatteryColor:
          systemInfoBatteryColor ?? this.systemInfoBatteryColor,
      routeCardHeight: routeCardHeight ?? this.routeCardHeight,
      routeCardArrowSize: routeCardArrowSize ?? this.routeCardArrowSize,
      routeCardArrowThickness:
          routeCardArrowThickness ?? this.routeCardArrowThickness,
      routeCardArrowColor: routeCardArrowColor ?? this.routeCardArrowColor,
      routeCardArrowOutlineColor:
          routeCardArrowOutlineColor ?? this.routeCardArrowOutlineColor,
      routeCardArrowBorderColor:
          routeCardArrowBorderColor ?? this.routeCardArrowBorderColor,
      routeCardDistanceFontSize:
          routeCardDistanceFontSize ?? this.routeCardDistanceFontSize,
      routeCardFontFamily: routeCardFontFamily ?? this.routeCardFontFamily,
      routeCardFontWeight: routeCardFontWeight ?? this.routeCardFontWeight,
      routeCardDistanceColor:
          routeCardDistanceColor ?? this.routeCardDistanceColor,
      routeCardStreetFontSize:
          routeCardStreetFontSize ?? this.routeCardStreetFontSize,
      routeCardStreetColor: routeCardStreetColor ?? this.routeCardStreetColor,
      routeCardStatsFontSize:
          routeCardStatsFontSize ?? this.routeCardStatsFontSize,
      routeCardStatsLabelFontSize:
          routeCardStatsLabelFontSize ?? this.routeCardStatsLabelFontSize,
      routeCardStatsValueFontSize:
          routeCardStatsValueFontSize ?? this.routeCardStatsValueFontSize,
      routeCardStatsColor: routeCardStatsColor ?? this.routeCardStatsColor,
      routeCardStatsIconColor:
          routeCardStatsIconColor ?? this.routeCardStatsIconColor,
      routeCardOpacity: routeCardOpacity ?? this.routeCardOpacity,
      routeCardCornerRadius:
          routeCardCornerRadius ?? this.routeCardCornerRadius,
      routeCardGlowIntensity:
          routeCardGlowIntensity ?? this.routeCardGlowIntensity,
      routeCardBackgroundColor:
          routeCardBackgroundColor ?? this.routeCardBackgroundColor,
      routeCardBorderColor: routeCardBorderColor ?? this.routeCardBorderColor,
      routeCardGlowColor: routeCardGlowColor ?? this.routeCardGlowColor,
      roundaboutRingColor: roundaboutRingColor ?? this.roundaboutRingColor,
      roundaboutEntranceColor: roundaboutEntranceColor ?? this.roundaboutEntranceColor,
      roundaboutMainExitColor: roundaboutMainExitColor ?? this.roundaboutMainExitColor,
      roundaboutSecondaryExitColor: roundaboutSecondaryExitColor ?? this.roundaboutSecondaryExitColor,
      roundaboutLaneColor: roundaboutLaneColor ?? this.roundaboutLaneColor,
      roundaboutGlowColor: roundaboutGlowColor ?? this.roundaboutGlowColor,
      roundaboutOpacity: roundaboutOpacity ?? this.roundaboutOpacity,
      roundaboutEntranceOpacity: roundaboutEntranceOpacity ?? this.roundaboutEntranceOpacity,
      roundaboutSecondaryOpacity: roundaboutSecondaryOpacity ?? this.roundaboutSecondaryOpacity,
      roundaboutLaneOpacity: roundaboutLaneOpacity ?? this.roundaboutLaneOpacity,
      roundaboutGlowOpacity: roundaboutGlowOpacity ?? this.roundaboutGlowOpacity,
      roundaboutSizePercent: roundaboutSizePercent ?? this.roundaboutSizePercent,
      routeAlertSizePercent:
          routeAlertSizePercent ?? this.routeAlertSizePercent,
      roadDirectionArrowSizePercent:
          roadDirectionArrowSizePercent ?? this.roadDirectionArrowSizePercent,
      roadDirectionArrowColor:
          roadDirectionArrowColor ?? this.roadDirectionArrowColor,
      bottomNavBackgroundColor:
          bottomNavBackgroundColor ?? this.bottomNavBackgroundColor,
      bottomNavBorderColor: bottomNavBorderColor ?? this.bottomNavBorderColor,
      bottomNavGlowColor: bottomNavGlowColor ?? this.bottomNavGlowColor,
      bottomNavIconColor: bottomNavIconColor ?? this.bottomNavIconColor,
      bottomNavIconActiveColor:
          bottomNavIconActiveColor ?? this.bottomNavIconActiveColor,
      bottomNavHomeButtonColor:
          bottomNavHomeButtonColor ?? this.bottomNavHomeButtonColor,
      bottomNavOpacity: bottomNavOpacity ?? this.bottomNavOpacity,
      themeMode: themeMode ?? this.themeMode,
      primaryColor: primaryColor ?? this.primaryColor,
      appFontSizePercent: appFontSizePercent ?? this.appFontSizePercent,
      appFontColor: appFontColor ?? this.appFontColor,
      appFontWeightOption: appFontWeightOption ?? this.appFontWeightOption,
      appFontFamily: appFontFamily ?? this.appFontFamily,
    );
  }


  Map<String, dynamic> toJson() => {
        'activeTab': activeTab.name,
        'vehicleModelIndex': vehicleModelIndex,
        'carSizePercent': carSizePercent,
        'navigationCameraTiltDegrees': navigationCameraTiltDegrees,
        'vehicleViewAngleDegrees': vehicleViewAngleDegrees,
        'pinColor': pinColor.value,
        'pinShadowEnabled': pinShadowEnabled,
        'pinSize': pinSize,
        'routeColorIndex': routeColorIndex,
        'routeColorHex': routeColorHex,
        'routeColorGlowHex': routeColorGlowHex,
        'routeWidth': routeWidth,
        'routeGlowEnabled': routeGlowEnabled,
        'routeGlowIntensity': routeGlowIntensity,
        'routeLineStyle': routeLineStyle.name,
        'avoidTolls': avoidTolls,
        'avoidTraffic': avoidTraffic,
        'avoidUnpavedRoads': avoidUnpavedRoads,
        'avoidHighways': avoidHighways,
        'avoidFerries': avoidFerries,
        'showLiveTraffic': showLiveTraffic,
        'showRouteWarnings': showRouteWarnings,
        'autoRerouteEnabled': autoRerouteEnabled,
        'routePlanningMode': routePlanningMode.name,
        'mapPerspective': mapPerspective.name,
        'mapTilt': mapTilt,
        'elementMainRoadMinZoom': elementMainRoadMinZoom,
        'elementSubRoadMinZoom': elementSubRoadMinZoom,
        'elementAlleyMinZoom': elementAlleyMinZoom,
        'weatherPosition': weatherPosition.name,
        'weatherVerticalPercent': weatherVerticalPercent,
        'weatherHorizontalPercent': weatherHorizontalPercent,
        'weatherSize': weatherSize,
        'weatherBgColor': weatherBgColor.value,
        'weatherBgOpacity': weatherBgOpacity,
        'weatherContentAlign': weatherContentAlign,
        'weatherTextColor': weatherTextColor.value,
        'weatherTextSize': weatherTextSize,
        'weatherFontFamily': weatherFontFamily.name,
        'systemInfoEnabled': systemInfoEnabled,
        'systemInfoVerticalPercent': systemInfoVerticalPercent,
        'systemInfoHorizontalPercent': systemInfoHorizontalPercent,
        'systemInfoSize': systemInfoSize,
        'systemInfoBgColor': systemInfoBgColor.value,
        'systemInfoBgOpacity': systemInfoBgOpacity,
        'systemInfoContentAlign': systemInfoContentAlign,
        'systemInfoTextColor': systemInfoTextColor.value,
        'systemInfoBatteryTextColor': systemInfoBatteryTextColor.value,
        'systemInfoBatteryTextWeight': systemInfoBatteryTextWeight.name,
        'systemInfoClockFontSize': systemInfoClockFontSize,
        'systemInfoBatteryFontSize': systemInfoBatteryFontSize,
        'systemInfoClockFontFamily': systemInfoClockFontFamily.name,
        'systemInfoBatteryFontFamily': systemInfoBatteryFontFamily.name,
        'systemInfoBatteryOrientation': systemInfoBatteryOrientation.name,
        'systemInfoBatterySizePercent': systemInfoBatterySizePercent,
        'systemInfoBatteryColor': systemInfoBatteryColor.value,
        'routeCardHeight': routeCardHeight,
        'routeCardArrowSize': routeCardArrowSize,
        'routeCardArrowThickness': routeCardArrowThickness,
        'routeCardArrowColor': routeCardArrowColor.value,
        'routeCardArrowOutlineColor': routeCardArrowOutlineColor.value,
        'routeCardArrowBorderColor': routeCardArrowBorderColor.value,
        'routeCardDistanceFontSize': routeCardDistanceFontSize,
        'routeCardFontFamily': routeCardFontFamily.name,
        'routeCardFontWeight': routeCardFontWeight.name,
        'routeCardDistanceColor': routeCardDistanceColor.value,
        'routeCardStreetFontSize': routeCardStreetFontSize,
        'routeCardStreetColor': routeCardStreetColor.value,
        'routeCardStatsFontSize': routeCardStatsFontSize,
        'routeCardStatsLabelFontSize': routeCardStatsLabelFontSize,
        'routeCardStatsValueFontSize': routeCardStatsValueFontSize,
        'routeCardStatsColor': routeCardStatsColor.value,
        'routeCardStatsIconColor': routeCardStatsIconColor.value,
        'routeCardOpacity': routeCardOpacity,
        'routeCardCornerRadius': routeCardCornerRadius,
        'routeCardGlowIntensity': routeCardGlowIntensity,
        'routeCardBackgroundColor': routeCardBackgroundColor.value,
        'routeCardBorderColor': routeCardBorderColor.value,
        'routeCardGlowColor': routeCardGlowColor.value,
        'roundaboutRingColor': roundaboutRingColor.value,
        'roundaboutEntranceColor': roundaboutEntranceColor.value,
        'roundaboutMainExitColor': roundaboutMainExitColor.value,
        'roundaboutSecondaryExitColor': roundaboutSecondaryExitColor.value,
        'roundaboutLaneColor': roundaboutLaneColor.value,
        'roundaboutGlowColor': roundaboutGlowColor.value,
        'roundaboutOpacity': roundaboutOpacity,
        'roundaboutEntranceOpacity': roundaboutEntranceOpacity,
        'roundaboutSecondaryOpacity': roundaboutSecondaryOpacity,
        'roundaboutLaneOpacity': roundaboutLaneOpacity,
        'roundaboutGlowOpacity': roundaboutGlowOpacity,
        'roundaboutSizePercent': roundaboutSizePercent,
        'routeAlertSizePercent': routeAlertSizePercent,
        'roadDirectionArrowSizePercent': roadDirectionArrowSizePercent,
        'roadDirectionArrowColor': roadDirectionArrowColor.value,
        'bottomNavBackgroundColor': bottomNavBackgroundColor.value,
        'bottomNavBorderColor': bottomNavBorderColor.value,
        'bottomNavGlowColor': bottomNavGlowColor.value,
        'bottomNavIconColor': bottomNavIconColor.value,
        'bottomNavIconActiveColor': bottomNavIconActiveColor.value,
        'bottomNavHomeButtonColor': bottomNavHomeButtonColor.value,
        'bottomNavOpacity': bottomNavOpacity,
        'themeMode': themeMode.name,
        'primaryColor': primaryColor.value,
        'appFontSizePercent': appFontSizePercent,
        'appFontColor': appFontColor.value,
        'appFontWeightOption': appFontWeightOption.name,
        'appFontFamily': appFontFamily.name,
      };

  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    const fallback = AppearanceSettings();
    T enumOr<T>(List<T> values, dynamic raw, T fallback) {
      if (raw is! String) return fallback;
      for (final v in values) {
        if ((v as Enum).name == raw) return v;
      }
      return fallback;
    }

    double numOr(dynamic raw, double fallback) =>
        raw is num ? raw.toDouble() : fallback;
    int intOr(dynamic raw, int fallback) => raw is int ? raw : fallback;
    Color colorOr(dynamic raw, Color fallback) =>
        raw is int ? Color(raw) : fallback;
    final legacyWeatherPosition = enumOr(WeatherWidgetPosition.values,
        json['weatherPosition'], fallback.weatherPosition);
    double legacyVertical(WeatherWidgetPosition position) =>
        position == WeatherWidgetPosition.bottomLeft ||
                position == WeatherWidgetPosition.bottomRight
            ? 100.0
            : 0.0;
    double legacyHorizontal(WeatherWidgetPosition position) =>
        position == WeatherWidgetPosition.topRight ||
                position == WeatherWidgetPosition.bottomRight
            ? 100.0
            : 0.0;

    return AppearanceSettings(
      activeTab:
          enumOr(AppearanceTab.values, json['activeTab'], fallback.activeTab),
      vehicleModelIndex:
          intOr(json['vehicleModelIndex'], fallback.vehicleModelIndex),
      carSizePercent: numOr(json['carSizePercent'], fallback.carSizePercent)
          .clamp(50.0, 150.0)
          .toDouble(),
      navigationCameraTiltDegrees: numOr(json['navigationCameraTiltDegrees'],
              fallback.navigationCameraTiltDegrees)
          .clamp(0.0, 90.0)
          .toDouble(),
      vehicleViewAngleDegrees: numOr(json['vehicleViewAngleDegrees'], 0.0)
          .clamp(0.0, 60.0)
          .toDouble(),
      pinColor: colorOr(json['pinColor'], fallback.pinColor),
      pinShadowEnabled:
          json['pinShadowEnabled'] as bool? ?? fallback.pinShadowEnabled,
      pinSize: numOr(json['pinSize'], fallback.pinSize)
          .clamp(50.0, 150.0)
          .toDouble(),
      routeColorIndex: intOr(json['routeColorIndex'], fallback.routeColorIndex),
      routeColorHex: json['routeColorHex'] as String? ?? fallback.routeColorHex,
      routeColorGlowHex:
          json['routeColorGlowHex'] as String? ?? fallback.routeColorGlowHex,
      routeWidth: numOr(json['routeWidth'], fallback.routeWidth),
      routeGlowEnabled:
          json['routeGlowEnabled'] as bool? ?? fallback.routeGlowEnabled,
      routeGlowIntensity:
          numOr(json['routeGlowIntensity'], fallback.routeGlowIntensity),
      routeLineStyle: enumOr(RouteLineStyle.values, json['routeLineStyle'],
          fallback.routeLineStyle),
      avoidTolls: json['avoidTolls'] as bool? ?? fallback.avoidTolls,
      avoidTraffic: json['avoidTraffic'] as bool? ?? fallback.avoidTraffic,
      avoidUnpavedRoads:
          json['avoidUnpavedRoads'] as bool? ?? fallback.avoidUnpavedRoads,
      avoidHighways: json['avoidHighways'] as bool? ?? fallback.avoidHighways,
      avoidFerries: json['avoidFerries'] as bool? ?? fallback.avoidFerries,
      showLiveTraffic:
          json['showLiveTraffic'] as bool? ?? fallback.showLiveTraffic,
      showRouteWarnings:
          json['showRouteWarnings'] as bool? ?? fallback.showRouteWarnings,
      autoRerouteEnabled:
          json['autoRerouteEnabled'] as bool? ?? fallback.autoRerouteEnabled,
      routePlanningMode: enumOr(RoutePlanningMode.values,
          json['routePlanningMode'], fallback.routePlanningMode),
      mapPerspective: enumOr(MapPerspective.values, json['mapPerspective'],
          fallback.mapPerspective),
      mapTilt: numOr(json['mapTilt'], fallback.mapTilt),
      elementMainRoadMinZoom: intOr(
          json['elementMainRoadMinZoom'], fallback.elementMainRoadMinZoom),
      elementSubRoadMinZoom:
          intOr(json['elementSubRoadMinZoom'], fallback.elementSubRoadMinZoom),
      elementAlleyMinZoom:
          intOr(json['elementAlleyMinZoom'], fallback.elementAlleyMinZoom),
      weatherPosition: legacyWeatherPosition,
      weatherVerticalPercent: numOr(
        json['weatherVerticalPercent'],
        legacyVertical(legacyWeatherPosition),
      ).clamp(0.0, 100.0).toDouble(),
      weatherHorizontalPercent: numOr(
        json['weatherHorizontalPercent'],
        legacyHorizontal(legacyWeatherPosition),
      ).clamp(0.0, 100.0).toDouble(),
      weatherSize: numOr(json['weatherSize'], fallback.weatherSize),
      weatherBgColor: colorOr(json['weatherBgColor'], fallback.weatherBgColor),
      weatherBgOpacity:
          numOr(json['weatherBgOpacity'], fallback.weatherBgOpacity),
      weatherContentAlign:
          numOr(json['weatherContentAlign'], fallback.weatherContentAlign)
              .clamp(0.0, 100.0)
              .toDouble(),
      weatherTextColor:
          colorOr(json['weatherTextColor'], fallback.weatherTextColor),
      weatherTextSize: numOr(json['weatherTextSize'], fallback.weatherTextSize).clamp(60.0, 200.0).toDouble(),
      weatherFontFamily: enumOr(
        AppFontFamily.values, json['weatherFontFamily'], fallback.weatherFontFamily,
      ),
      systemInfoEnabled:
          json['systemInfoEnabled'] as bool? ?? fallback.systemInfoEnabled,
      systemInfoVerticalPercent: numOr(
        json['systemInfoVerticalPercent'],
        fallback.systemInfoVerticalPercent,
      ).clamp(0.0, 100.0).toDouble(),
      systemInfoHorizontalPercent: numOr(
        json['systemInfoHorizontalPercent'],
        fallback.systemInfoHorizontalPercent,
      ).clamp(0.0, 100.0).toDouble(),
      systemInfoSize: numOr(
        json['systemInfoSize'],
        fallback.systemInfoSize,
      ).clamp(70.0, 150.0).toDouble(),
      systemInfoBgColor:
          colorOr(json['systemInfoBgColor'], fallback.systemInfoBgColor),
      systemInfoBgOpacity: numOr(
        json['systemInfoBgOpacity'],
        fallback.systemInfoBgOpacity,
      ).clamp(0.0, 1.0).toDouble(),
      systemInfoContentAlign: numOr(
        json['systemInfoContentAlign'],
        fallback.systemInfoContentAlign,
      ).clamp(0.0, 100.0).toDouble(),
      systemInfoTextColor:
          colorOr(json['systemInfoTextColor'], fallback.systemInfoTextColor),
      systemInfoBatteryTextColor: colorOr(
        json['systemInfoBatteryTextColor'],
        fallback.systemInfoBatteryTextColor,
      ),
      systemInfoBatteryTextWeight: enumOr(
        AppFontWeightOption.values, json['systemInfoBatteryTextWeight'],
        fallback.systemInfoBatteryTextWeight,
      ),
      systemInfoClockFontSize: numOr(json['systemInfoClockFontSize'], fallback.systemInfoClockFontSize).clamp(60.0, 200.0).toDouble(),
      systemInfoBatteryFontSize: numOr(json['systemInfoBatteryFontSize'], fallback.systemInfoBatteryFontSize).clamp(60.0, 200.0).toDouble(),
      systemInfoClockFontFamily: enumOr(
        AppFontFamily.values, json['systemInfoClockFontFamily'], fallback.systemInfoClockFontFamily,
      ),
      systemInfoBatteryFontFamily: enumOr(
        AppFontFamily.values, json['systemInfoBatteryFontFamily'], fallback.systemInfoBatteryFontFamily,
      ),
      systemInfoBatteryOrientation: enumOr(
        BatteryIconOrientation.values,
        json['systemInfoBatteryOrientation'],
        fallback.systemInfoBatteryOrientation,
      ),
      systemInfoBatterySizePercent: numOr(
        json['systemInfoBatterySizePercent'],
        fallback.systemInfoBatterySizePercent,
      ).clamp(60.0, 160.0).toDouble(),
      systemInfoBatteryColor: colorOr(
        json['systemInfoBatteryColor'],
        fallback.systemInfoBatteryColor,
      ),
      routeCardHeight: numOr(json['routeCardHeight'], fallback.routeCardHeight)
          .clamp(0.0, 1.0)
          .toDouble(),
      routeCardArrowSize: numOr(
        json['routeCardArrowSize'],
        numOr(json['routeCardFontSize'], fallback.routeCardArrowSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardArrowThickness: numOr(
        json['routeCardArrowThickness'], fallback.routeCardArrowThickness,
      ).clamp(0.35, 1.5).toDouble(),
      routeCardArrowColor: colorOr(
        json['routeCardArrowColor'],
        colorOr(json['routeCardElementColor'], fallback.routeCardArrowColor),
      ),
      routeCardArrowOutlineColor: colorOr(
        json['routeCardArrowOutlineColor'],
        fallback.routeCardArrowOutlineColor,
      ),
      routeCardArrowBorderColor: colorOr(
        json['routeCardArrowBorderColor'],
        fallback.routeCardArrowBorderColor,
      ),
      routeCardDistanceFontSize: numOr(
        json['routeCardDistanceFontSize'],
        numOr(json['routeCardFontSize'], fallback.routeCardDistanceFontSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardFontFamily: enumOr(
        AppFontFamily.values, json['routeCardFontFamily'], fallback.routeCardFontFamily,
      ),
      routeCardFontWeight: enumOr(
        AppFontWeightOption.values, json['routeCardFontWeight'], fallback.routeCardFontWeight,
      ),
      routeCardDistanceColor: colorOr(
        json['routeCardDistanceColor'],
        colorOr(json['routeCardElementColor'], fallback.routeCardDistanceColor),
      ),
      routeCardStreetFontSize: numOr(
        json['routeCardStreetFontSize'],
        numOr(json['routeCardFontSize'], fallback.routeCardStreetFontSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardStreetColor: colorOr(
        json['routeCardStreetColor'],
        colorOr(json['routeCardElementColor'], fallback.routeCardStreetColor),
      ),
      routeCardStatsFontSize: numOr(
        json['routeCardStatsFontSize'],
        numOr(json['routeCardFontSize'], fallback.routeCardStatsFontSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardStatsLabelFontSize: numOr(
        json['routeCardStatsLabelFontSize'],
        numOr(json['routeCardStatsFontSize'], fallback.routeCardStatsLabelFontSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardStatsValueFontSize: numOr(
        json['routeCardStatsValueFontSize'],
        numOr(json['routeCardStatsFontSize'], fallback.routeCardStatsValueFontSize),
      ).clamp(0.0, 1.0).toDouble(),
      routeCardStatsColor: colorOr(
        json['routeCardStatsColor'],
        colorOr(json['routeCardElementColor'], fallback.routeCardStatsColor),
      ),
      routeCardStatsIconColor: colorOr(
        json['routeCardStatsIconColor'], fallback.routeCardStatsIconColor,
      ),
      routeCardOpacity:
          numOr(json['routeCardOpacity'], fallback.routeCardOpacity)
              .clamp(0.0, 1.0)
              .toDouble(),
      routeCardCornerRadius:
          numOr(json['routeCardCornerRadius'], fallback.routeCardCornerRadius)
              .clamp(0.0, 1.0)
              .toDouble(),
      routeCardGlowIntensity:
          numOr(json['routeCardGlowIntensity'], fallback.routeCardGlowIntensity)
              .clamp(0.0, 1.0)
              .toDouble(),
      routeCardBackgroundColor: colorOr(
        json['routeCardBackgroundColor'], fallback.routeCardBackgroundColor,
      ),
      routeCardBorderColor: colorOr(
        json['routeCardBorderColor'], fallback.routeCardBorderColor,
      ),
      routeCardGlowColor: colorOr(
        json['routeCardGlowColor'], fallback.routeCardGlowColor,
      ),
      roundaboutRingColor: colorOr(json['roundaboutRingColor'], fallback.roundaboutRingColor),
      roundaboutEntranceColor: colorOr(json['roundaboutEntranceColor'], fallback.roundaboutEntranceColor),
      roundaboutMainExitColor: colorOr(json['roundaboutMainExitColor'], fallback.roundaboutMainExitColor),
      roundaboutSecondaryExitColor: colorOr(json['roundaboutSecondaryExitColor'], fallback.roundaboutSecondaryExitColor),
      roundaboutLaneColor: colorOr(json['roundaboutLaneColor'], fallback.roundaboutLaneColor),
      roundaboutGlowColor: colorOr(json['roundaboutGlowColor'], fallback.roundaboutGlowColor),
      roundaboutOpacity: numOr(json['roundaboutOpacity'], fallback.roundaboutOpacity).clamp(0.0, 1.0).toDouble(),
      roundaboutEntranceOpacity: numOr(json['roundaboutEntranceOpacity'], fallback.roundaboutEntranceOpacity).clamp(0.0, 1.0).toDouble(),
      roundaboutSecondaryOpacity: numOr(json['roundaboutSecondaryOpacity'], fallback.roundaboutSecondaryOpacity).clamp(0.0, 1.0).toDouble(),
      roundaboutLaneOpacity: numOr(json['roundaboutLaneOpacity'], fallback.roundaboutLaneOpacity).clamp(0.0, 1.0).toDouble(),
      roundaboutGlowOpacity: numOr(json['roundaboutGlowOpacity'], fallback.roundaboutGlowOpacity).clamp(0.0, 1.0).toDouble(),
      roundaboutSizePercent: numOr(json['roundaboutSizePercent'], fallback.roundaboutSizePercent).clamp(50.0, 150.0).toDouble(),
      routeAlertSizePercent:
          numOr(json['routeAlertSizePercent'], fallback.routeAlertSizePercent)
              .clamp(70.0, 130.0)
              .toDouble(),
      roadDirectionArrowSizePercent: numOr(
        json['roadDirectionArrowSizePercent'],
        fallback.roadDirectionArrowSizePercent,
      ).clamp(30.0, 200.0).toDouble(),
      roadDirectionArrowColor: colorOr(
        json['roadDirectionArrowColor'],
        fallback.roadDirectionArrowColor,
      ),
      bottomNavBackgroundColor: colorOr(
        json['bottomNavBackgroundColor'], fallback.bottomNavBackgroundColor,
      ),
      bottomNavBorderColor: colorOr(
        json['bottomNavBorderColor'], fallback.bottomNavBorderColor,
      ),
      bottomNavGlowColor: colorOr(
        json['bottomNavGlowColor'], fallback.bottomNavGlowColor,
      ),
      bottomNavIconColor: colorOr(
        json['bottomNavIconColor'], fallback.bottomNavIconColor,
      ),
      bottomNavIconActiveColor: colorOr(
        json['bottomNavIconActiveColor'], fallback.bottomNavIconActiveColor,
      ),
      bottomNavHomeButtonColor: colorOr(
        json['bottomNavHomeButtonColor'], fallback.bottomNavHomeButtonColor,
      ),
      bottomNavOpacity: numOr(json['bottomNavOpacity'], fallback.bottomNavOpacity)
          .clamp(0.0, 1.0)
          .toDouble(),
      themeMode:
          enumOr(ThemeMode.values, json['themeMode'], fallback.themeMode),
      primaryColor: colorOr(json['primaryColor'], fallback.primaryColor),
      appFontSizePercent: numOr(
        json['appFontSizePercent'],
        fallback.appFontSizePercent,
      ).clamp(80.0, 140.0).toDouble(),
      appFontColor: colorOr(json['appFontColor'], fallback.appFontColor),
      appFontWeightOption: enumOr(
        AppFontWeightOption.values,
        json['appFontWeightOption'],
        fallback.appFontWeightOption,
      ),
      appFontFamily: enumOr(
        AppFontFamily.values, json['appFontFamily'], fallback.appFontFamily,
      ),
    );
  }

  String serialize() => jsonEncode(toJson());

  static AppearanceSettings deserialize(String? raw) {
    if (raw == null || raw.isEmpty) return const AppearanceSettings();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return AppearanceSettings.fromJson(map);
    } catch (_) {
      return const AppearanceSettings();
    }
  }
}

class AppearancePresets {
  const AppearancePresets._();

  static AppearanceSettings apply(
      AppearanceSettings base, AppearancePreset preset) {
    switch (preset) {
      case AppearancePreset.minimal:
        return base.copyWith(
          preset: AppearancePreset.minimal,
          routeColorIndex: -1,
          routeColorHex: '#2F6FD6',
          routeColorGlowHex: '#2F6FD6',
          routeGlowEnabled: false,
          routeGlowIntensity: 0.0,
          routeLineStyle: RouteLineStyle.solid,
          pinColor: const Color(0xFF2F6FD6),
          pinShadowEnabled: false,
          pinSize: 90,
        );
      case AppearancePreset.neon:
        return base.copyWith(
          preset: AppearancePreset.neon,
          routeColorIndex: -1,
          routeColorHex: '#3FD0E0',
          routeColorGlowHex: '#3FD0E0',
          routeGlowEnabled: true,
          routeGlowIntensity: 1.0,
          routeLineStyle: RouteLineStyle.solid,
          pinColor: const Color(0xFF3FD0E0),
          pinShadowEnabled: true,
          pinSize: 110,
        );
      case AppearancePreset.classic:
        return base.copyWith(
          preset: AppearancePreset.classic,
          routeColorIndex: -1,
          routeColorHex: '#8a3fd0',
          routeColorGlowHex: '#9d4fe0',
          routeGlowEnabled: true,
          routeGlowIntensity: 0.8,
          routeLineStyle: RouteLineStyle.solid,
          pinColor: const Color(0xFF8A3FD0),
          pinShadowEnabled: true,
          pinSize: 100,
        );
      case AppearancePreset.custom:
        return base.copyWith(preset: AppearancePreset.custom);
    }
  }

  static AppearancePreset detect(AppearanceSettings s) {
    for (final p in [
      AppearancePreset.minimal,
      AppearancePreset.neon,
      AppearancePreset.classic,
    ]) {
      final applied = apply(s, p);
      if (applied.routeColorHex == s.routeColorHex &&
          applied.routeColorGlowHex == s.routeColorGlowHex &&
          applied.routeGlowEnabled == s.routeGlowEnabled &&
          applied.routeGlowIntensity == s.routeGlowIntensity &&
          applied.routeLineStyle == s.routeLineStyle &&
          applied.pinColor.value == s.pinColor.value &&
          applied.pinShadowEnabled == s.pinShadowEnabled &&
          applied.pinSize == s.pinSize) {
        return p;
      }
    }
    return AppearancePreset.custom;
  }
}
