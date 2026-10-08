import 'dart:async';
import '../../../core/geo/geo_types.dart';
import '../data/location_service.dart';
import 'vehicle_position_animator.dart';

/// آخرین لایه‌ی pipeline موقعیت‌یابیِ ناوبری:
///
///   Raw GPS → Accuracy Check → Kalman Filter → Map Matching → Navigation Position
///
/// دو مرحله‌ی اول («Raw GPS» و «Accuracy Check + Kalman Filter») داخل
/// [LocationService] انجام می‌شوند (به [LocationRepository] نگاه کنید).
/// این کلاس فقط مرحله‌ی «Map Matching» (snap به نزدیک‌ترین یالِ گراف
/// جاده‌ی آفلاین) و تحویل نتیجه به [VehiclePositionAnimator] (که خروجیِ
/// نهاییِ ۶۰fps برای Map UI را می‌سازد) را اضافه می‌کند. UI نباید مستقیم
/// stream خام LocationService را بخواند — باید از [positionStream] این
/// کلاس (یا از animatedVehiclePositionProvider که این را wrap می‌کند)
/// استفاده کند.
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

  /// End navigation and synchronously restore the free-drive vehicle anchor.
  /// The caller supplies the latest raw GPS fix so the marker cannot remain at
  /// the last point of the completed route.
  void resetToFreeDrive(VehiclePosition position) {
    _animator.resetToFreeDrive(position);
  }

  /// Immediately leaves the planned route when the driver is confirmed to be
  /// on another road. The new GPS fix becomes the visual anchor while the
  /// route engine calculates the replacement route.
  void adoptGpsAnchor(VehiclePosition position) {
    _animator.adoptGpsAnchor(position);
  }

  void attach(Stream<VehiclePosition> rawFiltered) {
    // graph.snap ناهم‌زمان است. با اتصال به stream تازه، همهٔ snapshotهای
    // در حال پردازش از اتصال قبلی را نامعتبر می‌کنیم؛ وگرنه پاسخ دیررسِ آن‌ها
    // می‌تواند پس از بازشدن مجدد نقشه/تغییر گراف، خودرو را به جای قبلی بپراند.
    _latestFixSequence++;
    _sub?.cancel();
    _sub = rawFiltered.listen(_onFiltered);
  }

  void seed(VehiclePosition pos) => _animator.onRawFix(pos);

  void _onFiltered(VehiclePosition pos) {
    _latestFixSequence++;
    // Tile-based map matching has been removed. The Vector ABM routing graph
    // is consumed directly by the routing engine; the visual GPS pipeline
    // remains deterministic and never snaps to a legacy tile graph.
    _animator.onRawFix(pos);
  }

  void dispose() {
    _latestFixSequence++;
    _sub?.cancel();
    _animator.dispose();
  }
}
