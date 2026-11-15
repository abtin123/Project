# GPS removal
Removed: location_service impl, Kalman (1D/joint), speed_fusion, road_snapper algo, vehicle_position_animator,
last_location_repository, gps_debug, gps_report_screen (+route, +settings row), geolocator dep,
road-snap query loop in online_map_view.
Kept as inert stubs (same API, UI unchanged): LocationService, VehiclePosition, LocationRepository,
gps_providers, NavigationPositionController, RoadSnapper (leftHandTraffic only), LocationReadiness enum.
All stubs marked TODO(gps-rewrite). DB table lastKnownLocation kept (generated drift file untouched).
Run: flutter pub get
