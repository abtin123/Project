# Reliability fixes — Sep 26, 2026
- [x] **Renamed `packaging/` → `release_packaging/`.** The old name collided
      with the third-party PyPI `packaging` library (used internally by pip,
      setuptools, and pytest itself). Whichever one got imported first into
      `sys.modules` won for the rest of the process — so `import packaging`
      inside this repo's own code worked or silently broke depending on
      invocation order (plain `pytest` vs `python -m pytest`, IDE runners,
      CI runner Python version, etc.), which is exactly the "works
      sometimes, not others" behavior this pass was meant to eliminate. All
      internal imports, the `check_source.py` builder-fingerprint glob, and
      the two test files that referenced `packaging/...` paths were updated
      to the new name. Nothing in `sys.path`/import order can accidentally
      break this anymore since the name no longer collides with anything.
- [x] Added a root `conftest.py` that puts the project root on `sys.path`
      unconditionally. Several tests only resolved local imports (e.g.
      `from routing... import ...`) because the project root *happened* to
      already be on `sys.path` — not guaranteed by pytest itself.
- [x] **Regional builds for `IR`/`US` no longer need network access at build
      time.** `sample/regions/IR.json` and `sample/regions/US.json` had only
      a `bbox` per region and no `geometry`/`boundaries_file`, so every
      build silently fell through to `_auto_attach_admin1_boundaries()`,
      which fetches Admin-1 polygons from `datahub.io` over HTTP. On any
      offline run, or whenever that external host is unreachable/blocked
      (as it was during this check — `HTTP 403`), the regional build failed
      outright. Fixed by embedding a rectangular `geometry` Polygon (derived
      from the already-curated bbox) directly in each region entry, so the
      builder's existing "inline embedded geometry" fast path is used and
      the network call is never attempted. This is consistent with the
      already-documented caveat below that these bboxes are hand-entered
      rectangles, not exact admin boundaries.
- [x] Fixed `packaging/verify_abm.py`'s bare `from create_abm import
      verify_abm`, which only worked when the file was executed as a
      script directly (relying on Python auto-adding the script's own
      directory to `sys.path`) and broke if ever imported as
      `release_packaging.verify_abm`. Now uses the same
      root-on-sys.path + absolute-package-import convention as the rest of
      `release_packaging/`.

# Regional (province/state) builds — Sep 25, 2026
- [x] `IR` now has a curated `sample/regions/IR.json` (31 provinces, Persian
      names) instead of falling back to the generic English-only Admin-1
      generator. `countries.json` points `IR.regions_config` at it.
- [x] `US` `sample/regions/US.json` replaced: it previously split the country
      into 5 giant macro-regions (Northeast/Southeast/Midwest/Southwest/West),
      not actual states — that contradicted the app's per-state download UX.
      Now 50 states + DC, each its own downloadable `.abm`, Persian names.
- [x] Bumped `actions/checkout` v4→v5, `actions/setup-python` v5→v6,
      `actions/cache` v4→v5, `actions/upload-artifact` v4→v5 in every workflow
      — the Sep 25 build logs showed Node.js 20 deprecation warnings on all
      three jobs (Discover/Build/Publish) because these actions still ran on
      the old runtime.
- [x] Both new region files pass `build_abm.py`'s own `_load_regions_config`
      validator (unique codes, well-formed bbox, etc.) and `check_source.py`
      hashes them, so this change will correctly trigger a rebuild of every
      IR/US region on the next scheduled or manual run.
- [ ] Region bboxes for IR/US were hand-entered from general geographic
      knowledge (no network access in this session to pull authoritative
      province/state polygons). They're generous rectangles, not exact
      admin boundaries — fine for the builder (ways are never clipped, and
      routing uses an extra 0.25°/0.3° overlap corridor beyond the bbox), but
      worth spot-checking against a GADM/Natural Earth source before the
      next release if tight download sizes matter.
- [ ] The other ~35 countries in `countries.json` still rely on the generic
      Admin-1 auto-generator (`tools/generate_regions_from_admin1.py`), which
      only has English names (`name_fa` == `name_en`) and needs network
      access to DataHub at build time. Not fixed in this pass — curate more
      `sample/regions/<CC>.json` files the same way if/when needed.
- [ ] Intercity routing across two different downloaded regions (e.g. Tehran
      province → Fars province) still requires the user to have both
      province `.abm` files installed; the builder guarantees the graphs
      share OSM node IDs at the overlap corridor so the *app* can stitch
      them, but stitching logic itself lives in the Flutter app's routing
      engine, not in this builder repo (not in scope of this upload).

# Abtin Maps — final validation TODO

- [x] ABM runtime extracts exactly `map.mbtiles` and `<archive-name>.sqlite`.
- [x] `map.mbtiles` is the offline cartographic basemap consumed by MapLibre.
- [x] `<archive-name>.sqlite` remains the direct query store for search, POI, road metadata and routing.
- [x] No whole-`<archive-name>.sqlite` application cache or rebuild is used during viewport/search/routing queries.
- [x] Only targeted query results are materialized for the visible viewport.
- [x] Local MBTiles URI uses `mbtiles://file://...` for MapLibre Native compatibility.
- [x] Existing ABM extraction is reused only when the source archive signature matches; it is not a data-query cache.
- [ ] Run `flutter analyze` and `flutter test` in an environment with the Flutter SDK installed.
- [ ] Run a real Android offline-map smoke test with a downloaded `.abm` and verify the MBTiles source reaches `onStyleLoaded` and renders tiles.

# POI / sprite rendering
- [ ] Device check after rebuild: `adb logcat | grep -i -E "mbgl|maplibre"` must show no "Error setting filter", "Failed to load sprite", "Missing image".
- [ ] Armenian (AM) and `№` labels: Vazirmatn glyph ranges 1280-1535 / 8448-8703 are not bundled, those characters are not drawn.
- [ ] Rebuild IR/AM abm (see builder repo) - POI/search work, routing graph does not until rebuilt.

# Route guidance card
- [ ] Verify on device against the reference screenshot (886x304 design px, scale = width/886). Saved appearance settings override the new defaults (arrow #40F538, bg #01173D, border #91BCF2, radius .45, opacity .97): reset them once.
- [ ] Stat icons are Material (schedule/pin_drop/timer outlined), not the exact reference glyphs.


## ABM v2 routing partition contract
- [x] Geographic routing cells (0.25°) with per-node/per-segment cell IDs and indexed lookup.
- [x] Node spatial R-tree for nearest-road/map-matching candidate lookup.
- [x] Compressed way geometry separated from graph records (delta + ZigZag + Varint, 1e-5°).
- [x] Road metadata includes speed, lanes, access, one-way, bridge/tunnel/toll/ferry flags.
- [x] Hierarchy levels are materialized for local/primary/trunk/motorway routing.
- [x] Roundabout metadata table is materialized; exit count can be completed by runtime using the selected entry/exit context.
- [x] ABM metadata advertises schema 7 / graph 2 and the routing partition contract.

## 3D buildings (builder)
- Done: `extractors/osm.py` keeps height/min_height/building:levels/building:min_level/roof:height; `abm_builder/tiles.py::_buildings` emits int `render_height` / `render_min_height` (levels×3.2 m fallback).
- Left: rebuild all province MBTiles + re-release (old packages have no heights → app falls back to 9 m); run tests/test_pipeline.py.
