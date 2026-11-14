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
- App id / namespace / Kotlin package / channels / iOS bundle id -> `ir.avash.maps` (installs as a NEW app; old data is not migrated).
- Dart flight recorder: `lib/core/debug/app_debugger.dart` (all prints, Flutter/async/isolate errors, lifecycle, memory pressure, slow frames, navigation, provider failures, heartbeat, previous-session verdict).
- Android flight recorder: `NativeDebug.kt` (uncaught exceptions, main-thread stalls, lifecycle, trim-memory, ApplicationExitInfo = why the OS closed the app), `DebugBridge.kt`, `AvashApplication.kt`.
- Screen: Settings -> «دیباگر و گزارش خطا» (route `/debug`); red bug badge appears on top of the app after an error / abnormal exit.
- Logs on disk: `Android/data/ir.avash.maps/files/debug/` (dart.log, native.log, last_crash.txt, report_*.txt).
