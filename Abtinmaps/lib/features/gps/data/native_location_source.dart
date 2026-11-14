import 'dart:async';

import 'package:flutter/services.dart';

/// Thin wrapper over the native GPS + network (Wi-Fi / cell) location bridge.
class NativeLocationSource {
  static const MethodChannel _method = MethodChannel('ir.avash.maps/location');
  static const EventChannel _events =
      EventChannel('ir.avash.maps/location_events');

  Stream<dynamic> events() => _events.receiveBroadcastStream();

  Future<bool> start({required bool navigation}) async {
    try {
      return await _method
              .invokeMethod<bool>('start', {'navigation': navigation}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setNavigation(bool navigation) async {
    try {
      await _method.invokeMethod<void>('setNavigation', {'navigation': navigation});
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> openLocationSettings() async {
    try {
      await _method.invokeMethod<void>('openSettings');
    } catch (_) {}
  }
}
