import 'package:flutter/services.dart';

/// Android foreground service that keeps navigation (GPS) alive in the
/// background on aggressive OEM ROMs such as MIUI.
class NavigationForegroundService {
  NavigationForegroundService._();

  static const MethodChannel _ch = MethodChannel('ir.abtin.abtin_maps/nav_service');
  static bool _running = false;

  static Future<void> start({
    String title = 'آبتین مپ',
    String text = 'مسیریابی فعال است',
  }) async {
    if (_running) return;
    _running = true;
    try {
      final ok = await _ch.invokeMethod<bool>('start', {'title': title, 'text': text});
      if (ok != true) _running = false;
    } catch (_) {
      _running = false;
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Opens the MIUI autostart page (or app settings on other devices).
  static Future<void> openAutostartSettings() async {
    try {
      await _ch.invokeMethod<bool>('openAutostart');
    } catch (_) {}
  }
}
