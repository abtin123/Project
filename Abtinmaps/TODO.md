# TODO — GPS rewrite (v0.0.22)

## Done
- Native Android bridge (`LocationBridge.kt`): GPS provider + Network provider (Wi-Fi/cell) + GNSS status, no Play Services needed.
- Native iOS bridge (in `AppDelegate.swift`): CoreLocation.
- 4-state Kalman filter (`kalman_filter.dart`): robust gating, adaptive Q, ZUPT, speed+bearing fusion.
- GPS-first source policy; network fixes seed / bridge outages / weak fusion when GPS is poor.
- Free-drive road snapper (`road_snapper.dart`): direction, one-way, speed/class plausibility, continuity, driving side.
- Road window loader from ABM sqlite (`offline_road_snap_service.dart`).
- Route projection + smooth animator (`navigation_position_controller.dart`).
- Permission/readiness flow + banner providers.

## Next
- Run `flutter pub get && flutter analyze`, then test on a real device (drive test).
- Verify ABM `categories.name` values match `_profileFor` in `road_snapper.dart`.
- Optional: use sensors_plus (gyro/accel) for dead-reckoning in tunnels.
- Optional: foreground service on Android for background navigation.
- Optional: drop unused `lastKnownLocation` table (needs drift regen).

## v0.0.23 — app id + debugger
- App id / namespace / Kotlin package / channels / iOS bundle id -> `ir.abtin.abtinmaps` (installs as a NEW app; old data is not migrated).

## 3D car: WebView -> native Filament (v0.0.24)
- Removed: `webview_flutter`, `model_viewer_plus` (and the local HTTP server / JS orbit pushes).
- Added: `android/app/src/main/kotlin/ir/abtin/abtinmaps/FilamentCar.kt` (Kotlin, Filament 1.56.0 via gradle (1.80.x needs compileSdk 37),
  NO flutter package). One shared Engine + render thread; each car renders into a Flutter `SurfaceProducer`
  surface and Dart shows it with `Texture(textureId)` (transparent, no PlatformView).
- Rendering is on-demand (only when heading/tilt/size/model change, <= ~22 fps) -> no more continuous
  `lockHardwareCanvas` + sync_file leak, RenderThread load and jank seen in the v0.0.23 debug report.
- Dart: `lib/features/vehicle/presentation/car_marker.dart` (`FilamentCarChannel`); falls back to the 2D arrow if the
  engine cannot start (non-Android or unsupported GPU) and logs why under tag `filament`.
- Debugger: native log tag `filament`; `perf` line ends with `filament{engine=.. backend=.. views=.. frames=..}`;
  report has a `filament (3D car)` line + `renderer3d`/`lastExit` in the Android snapshot; `fence` warning when
  sync_file >= 300; previous-session verdict now uses ApplicationExitInfo (swipe-away/MIUI cleaner is a note, not FATAL).
- If lighting looks off: tune SUN/FILL/IBL intensity constants in `FilamentHost.companion` (FilamentCar.kt).
