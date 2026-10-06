# TODO
## Done
- 3D buildings: height expr (render_height/height/levels, default 9m), height-based tint, vertical gradient, map light (`_apply3dBuildings` in abm_style_assets.dart); extrusion from z13; style revision v5.
## Left
- Test on device (offline + online); tune default height / light.
- If offline MBTiles lack height tags, add `height`/`levels` to buildings layer in Builder.
- Optional: raise default map pitch.

## Country SVGs (download screen)
- Done: assets/maps/countries/{iso2}.svg for all 37 countries in countries.json (Natural Earth 10m, simplified, single path each; ES has Canary inset, US has AK/HI inset, FR metropolitan only, UA includes Crimea).
- Optional: region-level SVGs for countries other than IR.

## Turn camera/car fix (2026-10-04)
- online_map_view.dart: camera target now lies along the commanded (smoothed) bearing instead of the route arc (removed lateral camera jump at corners); bearing target leads along the route by ~0.8s of travel; bearing rate limit 150->260 deg/s, deadband 1.5->0.6.
- Untested on device (no Flutter SDK). Step 2 done: vehicle screen projection EMA-smoothed (alpha 0.22) in follow+driving mode (_refreshScreenPositions).

## 2026-10-04 — Route modes
- Offline engine: fastest (highway-preferring class factors), shortest (pure distance, no hierarchy pruning), economic (50/50 time+distance). Online OSRM only re-ranks alternatives.
- `flutter analyze` not run here (no SDK); verify `main.dart` fireImmediately fix in CI.
- Camera: bearing held in tight curves/small roundabouts (route turns >100° in 60m); adaptive camera tick (500ms stopped / 66ms moving); road-snap timer 2.5s.
- Route card: street name split to 2nd line even without خیابان/بلوار prefix (generic به/در/روی boundary); subtitle size 0.55→0.7 of title.
- Free-drive: camera look-ahead 60dp (max 90m) instead of 150dp; RoadSnapper direction hysteresis (flip only ≥15km/h with GPS heading clearly opposite), robust oneway parsing (strings/bool/roundabout), road query 1s/5m/240px.
- Still unverified on device: whether rendered `abm-road-line` features carry `oneway` — if marker is still reversed on one-way streets, send /abm-log + short screen recording.
- Merged user's abtin-fixes (Oct 5): offline city names, "تهران" search ranking (place_search_service/offline_place_search_service), R-tree POI/places/hazard queries (battery). Python side (`map_db.py`, `tests/test_search_proximity.py`) belongs to the map-build-pipeline repo (abtin-maps-main) — not in this zip.
- Offline routing: primary route now shown immediately; alternatives stream in afterwards (calculateRoutesProvider is a StreamProvider, primary stays index 0). Fastest-mode class factors softened (0.90..1.10) to keep A* heuristic tight. Not measured on device.
- ROOT CAUSE free-drive snapping: road query rect used logical px (_vehicleScreen) but queryRenderedFeaturesInRect on Android needs physical px -> multiplied by devicePixelRatio. Raw GPS heading ignored below 6 km/h when not snapped.
- Offline turn detection: maneuver angle now from route polyline geometry (~22m before/after junction), added 'sharp' (>=120°), slight >=10°, same-way turns >=55° no longer forced straight.
- Offline highway entry/exit: class change to/from motorway/trunk(_link) now emits 'on ramp'/'off ramp' instructions with slight left/right arrow (default slight right). Unverified on device.

## 2026-10-05 — AR (Real View)
- New: lib/features/ar/presentation/ar_navigation_screen.dart (route /ar-navigation), button under the nav close button in home_screen. Live camera + maneuver/distance/street, speed limit + speed, alert chip, ETA. No road line by design. Added camera dep + CAMERA permission. Untested on device (no Flutter SDK); run flutter pub get.
- Alert sprites: route_{camera,police,speed_bump,traffic_light}.png replaced with new art (red ring). Map atlas abtin(@2x).png/json: abm-hz-* camera/speed_camera/bump/traffic updated + new abm-hz-police slot (422,242); RoadHazards 'police' spec; badge/map settings/AR chip use sprites. Unverified on device.
- Fixed CI analyze errors: removed 4 duplicate const-map keys (سریع‌ترین/کوتاه‌ترین with \u200c) in app_localizations.dart.
- assets/local/{fa,en}.json: removed 248 unused keys (767->519). Kept keys referenced by code, by _literalKeyAliases, by Persian-literal reverse lookup, or by dynamic prefixes (turn_/keep_/style_/lang_/entrance_/...). Dart _localizedValues untouched (generate_locales.py would re-add them).

- AR camera stretch fix: preview box now uses previewSize swapped for portrait (CameraPreview rotates itself; old SizedBox(100*ar,100) forced landscape box -> stretched). Untested on device.
- AR preview now follows device rotation: box aspect derived from controller deviceOrientation (same source as CameraPreview) via ValueListenableBuilder; AR forces all orientations. Untested on device.
- GPS disturbance (location_service.dart): poor-accuracy (>80m) fixes ignored while a good fix <20s old exists; 4 consecutive mutually-consistent rejected jumps => re-baseline filters (fixes permanent lock-out after a spoofed/bad baseline); stall watchdog now keyed on raw callbacks (no needless full restart while fixes arrive but are rejected); dead-reckoning gap 8->15s. Untested on device; no flutter analyze run.

## 2026-10-05 — Sprite refresh
- assets/sprites/abtin(@2x).png + route_*.png rebuilt from new icon sheet (same names/coords/sizes; route_* now 192px). abm-hz-uneven_road generated. JSON unchanged. Unverified on device.

## 2026-10-06 — OSM link restyle
- home_screen.dart: OSM link is now a small glass pill ("📍 OSM", 30px high, ~82% of speedometer width), centered under the speedometer with 12px gap (no overlap), tap opens openstreetmap.org/copyright. Untested on device; no flutter analyze run.

## 2026-10-06 — Louder audio
- voice_service.dart: AndroidLoudnessEnhancer (up to +9 dB, scaled by volume) on voice + beep players; AudioSession configured as navigation-guidance speech with ducking (music lowers, not stops); default volume 0.75 -> 1.0 (saved value kept); beep wav normalized to 95% peak. audio_session added as direct dep (0.1.25, already in lock). Untested on device; no flutter analyze run. If distortion: lower _maxBoostDb.

## 2026-10-06 — Myket link
- app_update_dialog.dart: update/download button now opens Myket (myket://details?id=ir.abtin.abtin_maps -> https://myket.ir/app/ir.abtin.abtin_maps -> GitHub release page fallback). Version check still reads GitHub Releases (app_update_service.dart). Manifest <queries> has myket scheme. Untested; app must be published on Myket under that package id.
