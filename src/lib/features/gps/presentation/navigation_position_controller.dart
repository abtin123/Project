import 'dart:async';
import '../../../core/geo/geo_types.dart';
import '../data/location_service.dart';
import 'vehicle_position_animator.dart';

class NavigationPositionController {
  final VehiclePositionAnimator _animator = VehiclePositionAnimator();
  StreamSubscription<VehiclePosition>? _sub;
  int _latestFixSequence = 0;

  NavigationPositionController();

  Stream<VehiclePosition> get positionStream => _animator.stream;

  bool get isRouteDriven => _animator.isRouteDriven;

  void setActiveRoute(List<LatLng> geometry, {VehiclePosition? anchor}) {
    _animator.setRoute(geometry, anchor: anchor);
  }

  void clearActiveRoute() {
    _animator.clearRoute();
  }

  void resetToFreeDrive(VehiclePosition position) {
    _animator.resetToFreeDrive(position);
  }

  void adoptGpsAnchor(VehiclePosition position) {
    _animator.adoptGpsAnchor(position);
  }

  void attach(Stream<VehiclePosition> rawFiltered) {
    _latestFixSequence++;
    _sub?.cancel();
    _sub = rawFiltered.listen(_onFiltered);
  }

  void seed(VehiclePosition pos) => _animator.onRawFix(pos);

  void _onFiltered(VehiclePosition pos) {
    _latestFixSequence++;
    _animator.onRawFix(pos);
  }

  void dispose() {
    _latestFixSequence++;
    _sub?.cancel();
    _animator.dispose();
  }
}
