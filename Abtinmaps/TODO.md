# TODO — build fixes (v0.0.22)

## Done
- home_screen.dart: added missing `degToRad` (fixes 5 analyzer errors, Android build).
- iOS: replacement unsigned-IPA step in `ios_unsigned_build_step.yml` (paste into workflow; prints real xcodebuild errors).

## Next
- Re-run CI; if iOS still fails, read the last 60 lines of xcodebuild output.
- Clean ~150 unused imports/variables (warnings only).

---

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
