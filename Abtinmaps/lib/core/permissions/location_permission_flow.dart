import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum LocationReadiness {
  ready,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled
}

class LocationPermissionFlow {
  LocationPermissionFlow._();

  static const MethodChannel _ch = MethodChannel('ir.abtin.maps/location');

  static Future<({bool fine, bool coarse})> _nativePermission() async {
    final m = await _ch.invokeMapMethod<String, bool>('permission');
    return (fine: m?['fine'] == true, coarse: m?['coarse'] == true);
  }

  static Future<LocationReadiness> check() async {
    try {
      final perm = await _nativePermission();
      if (perm.fine) {
        final on = await _ch.invokeMethod<bool>('serviceEnabled') ?? false;
        return on ? LocationReadiness.ready : LocationReadiness.serviceDisabled;
      }
      final status = await Permission.locationWhenInUse.status;
      if (status.isPermanentlyDenied) {
        return LocationReadiness.permissionDeniedForever;
      }
      return LocationReadiness.permissionDenied;
    } catch (_) {
      return LocationReadiness.serviceDisabled;
    }
  }

  /// Asks for permission / opens the right settings page for the current state.
  static Future<LocationReadiness> resolve() async {
    var r = await check();
    switch (r) {
      case LocationReadiness.ready:
        return r;
      case LocationReadiness.serviceDisabled:
        try {
          await _ch.invokeMethod<void>('openSettings');
        } catch (_) {}
        return r;
      case LocationReadiness.permissionDeniedForever:
        await openAppSettings();
        return r;
      case LocationReadiness.permissionDenied:
        await Permission.locationWhenInUse.request();
        r = await check();
        if (r == LocationReadiness.permissionDenied) {
          // Only approximate location was granted: precise one needs settings.
          try {
            final perm = await _nativePermission();
            if (perm.coarse && !perm.fine) {
              return LocationReadiness.permissionDeniedForever;
            }
          } catch (_) {}
        }
        return r;
    }
  }
}
