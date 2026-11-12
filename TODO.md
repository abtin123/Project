# TODO

- Verify on device: small roundabouts / U-turns — car stays on route line, arrow shape + head direction correct (card icon too).
- If car still detaches: log `_routeMatchLastProgressM` vs animator `_routeProgressM` in roundabouts.
- Consider smoothing offline route geometry at creation (ManeuverGeometry.smoothRoute is unused) — needs instruction index remap.
- Mini-roundabouts: derive exit bearing from geometry instead of instruction modifier.
- Roundabout icon: entrance-only arms no longer drawn (only ring + exits + active path)
- Roundabout angles now measured from ring centroid (entrance/exit/branches), merge+match tolerance 16 deg; verify exit 3 on 4-exit roundabout points left, dual carriageways merge
- Lane guidance: needs maps rebuilt with new turn_lanes columns (abtin-maps-main builder); app shows LaneGuidanceStrip under card within 700 m when lanes useful
- Bridges: builder stores bridge kinds+layer (flags bits 4-7), style sorts bridges by layer, app emits 'bridge enter/exit' instructions (>=80 m); arrow start snaps to real corner (ManeuverGeometry.snapToCorner). Needs rebuilt maps.
- Ramps: non-highway _link entries now say normal turn (not 'highway exit'); ramp arrow limited to ~90 m
- Ramps: U-turn via ramp (net >=140 deg) -> 'uturn' with full-ramp shape; ramp onto bridge -> 'Take the ramp onto the bridge' text
- Nav buttons: road-block button now beside the close (X) button in one row

- Perf (v0_0_17_fix6): verify on device a 400 km offline route (Tehran->far city): time to first route, no 2nd search running after changing a cosmetic setting.
- Perf: edge SQL now single directional probe; if `segments` lacks index on (way_id,a,b) add it in map builder — would speed A* further.
- Perf: alternatives skipped when first route >120 km or >6 s; consider reusing open DB handles across alternatives (needs persistent worker isolate).
- HomeScreen still watches whole appearanceSettingsProvider (markerAppearance) for live marker preview; split into selects if rebuild cost still shows.
- Nav card: tap toggles step list under the card (`_navStepsExpandedProvider`); verify close button still works and list scrolls on small screens.

- GPS (v0_0_20): verify on device in a moving car: no more `DROP jump` loops; fix cadence ~1s in nav (else auto-switch to RAW LocationManager logs 'nav fix cadence'); speed no longer stuck at 0.
- GPS: setNavigationMode(true) still restarts the stream (resets filters); consider opening the stream with nav settings from the start.
- GPS: dump showed rawMgr=false although code defaults to raw on Android — check which build/flow toggles it (no-fix timeout toggle in _onStreamError).
