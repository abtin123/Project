import 'package:abtin_maps/core/geo/geo_types.dart';

import 'routing_service.dart';

enum RoutingEngine {
  abtinmap,

  online,
}

extension RoutingEngineX on RoutingEngine {
  String get storageValue => name;

  String get label => switch (this) {
        RoutingEngine.abtinmap => 'آبتین‌مپ (آفلاین)',
        RoutingEngine.online => 'نقشه و مسیریابی آنلاین',
      };

  static RoutingEngine parse(String? value) => RoutingEngine.values.firstWhere(
        (engine) => engine.storageValue == value,
        orElse: () => RoutingEngine.online,
      );
}

abstract class RoutingProvider {
  RoutingEngine get engine;

  String get displayName;

  bool get isOffline;

  Future<bool> isReady();

  String? get lastError;

  Future<RouteInfo?> calculateRoute({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
  });
}
