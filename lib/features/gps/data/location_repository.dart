import 'dart:async';

import '../../../core/permissions/location_permission_flow.dart';
import 'location_service.dart';

class LocationRepository {
  final LocationService _service;
  LocationRepository(this._service);

  /// Replays the latest position to late listeners, then forwards live ones.
  Stream<VehiclePosition> get positionStream async* {
    final l = _service.last;
    if (l != null) yield l;
    yield* _service.stream;
  }

  Stream<LocationState> get stateStream => _service.stateStream;
  LocationState get state => _service.state;
  VehiclePosition? get lastPosition => _service.last;
  int get satellitesUsed => _service.satellitesUsed;

  Future<LocationReadiness> start() async {
    final readiness = await LocationPermissionFlow.check();
    if (readiness == LocationReadiness.ready) _service.start();
    return readiness;
  }

  void pause() => _service.stop();
  void dispose() => _service.dispose();
}
