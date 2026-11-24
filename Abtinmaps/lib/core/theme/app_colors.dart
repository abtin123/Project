import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static bool _isDark(BuildContext? context) =>
      context == null || Theme.of(context).brightness == Brightness.dark;

  static Color background([BuildContext? context]) {
    if (context == null) return const Color(0xFF0A0C10);
    return Theme.of(context).scaffoldBackgroundColor;
  }

  static Color frameBackground([BuildContext? context]) {
    if (context == null) return const Color(0xFF11151B);
    return Theme.of(context).colorScheme.surface;
  }

  static Color surfaceMuted(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _isDark(context)
        ? Color.lerp(scheme.surface, Colors.white, 0.055)!
        : Color.lerp(scheme.surface, Colors.black, 0.035)!;
  }

  static Color primaryAccent(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static Color primaryAccentLight(BuildContext context) =>
      Color.lerp(primaryAccent(context), Colors.white, 0.28)!;

  static Color primaryAccentDark(BuildContext context) =>
      Color.lerp(primaryAccent(context), Colors.black, 0.26)!;

  static Color primaryOnAccent(BuildContext context) =>
      Theme.of(context).colorScheme.onPrimary;

  static const danger = Color(0xFFE5544B);

  static Color glassPanel([BuildContext? context]) {
    if (context == null) return const Color(0xF014181D);
    final scheme = Theme.of(context).colorScheme;
    return _isDark(context)
        ? Color.lerp(scheme.surface, Colors.white, 0.045)!.withOpacity(0.96)
        : scheme.surface.withOpacity(0.97);
  }

  static Color glassPanelSoft([BuildContext? context]) {
    if (context == null) return const Color(0xD01A2026);
    final scheme = Theme.of(context).colorScheme;
    return _isDark(context)
        ? Color.lerp(scheme.surface, Colors.white, 0.085)!.withOpacity(0.88)
        : Color.lerp(scheme.surface, Colors.black, 0.025)!.withOpacity(0.95);
  }

  static Color glassBorder([BuildContext? context]) {
    if (context == null) return const Color(0x472FE6C4);
    final scheme = Theme.of(context).colorScheme;
    return _isDark(context)
        ? Color.lerp(scheme.outline, scheme.primary, 0.22)!.withOpacity(0.46)
        : scheme.outline.withOpacity(0.24);
  }

  static Color subAccentA(BuildContext context) => primaryAccent(context);
  static Color subAccentB(BuildContext context) => primaryAccent(context);
  static Color subGlassBg([BuildContext? context]) => glassPanel(context);
  static Color subGlassBgSoft([BuildContext? context]) =>
      glassPanelSoft(context);
  static Color subGlassBorder([BuildContext? context]) => glassBorder(context);

  static const speedLow = Color(0xFF3DDC84);
  static const speedMid = Color(0xFFFFD422);
  static const speedHigh = Color(0xFFFF4B4B);

  static LinearGradient primaryGradient(BuildContext context) {
    final primary = primaryAccent(context);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        primaryAccentLight(context),
        primary,
        primaryAccentDark(context)
      ],
      stops: const [0, 0.58, 1],
    );
  }

  static Color textPrimary([BuildContext? context]) {
    if (context == null) return Colors.white;
    return Theme.of(context).colorScheme.onSurface;
  }

  static Color textSecondary([BuildContext? context]) {
    if (context == null) return const Color(0xFFB7C0CC);
    final base = Theme.of(context).colorScheme.onSurfaceVariant;
    return _isDark(context) ? Color.lerp(base, Colors.white, 0.22)! : base;
  }

  static Color textMuted([BuildContext? context]) {
    if (context == null) return const Color(0xFFA9B3BF);
    final secondary = textSecondary(context);
    return _isDark(context)
        ? Color.lerp(secondary, Colors.white, 0.08)!
        : secondary.withOpacity(0.72);
  }
}
