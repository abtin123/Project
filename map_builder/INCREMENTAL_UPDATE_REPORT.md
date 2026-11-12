# Incremental update report — 2026-09-23

Runtime data split is now explicit:

1. `map.mbtiles` — cartographic offline map source for MapLibre (roads, buildings, landuse, water, boundaries).
2. `<archive-name>.sqlite` — direct on-disk query source for search, POI, routing, road metadata and viewport overlays such as local road names/places.

The app no longer configures a large SQLite mmap/page-cache budget. SQLite stays read-only and file-backed; normal SQLite query execution may use its small internal page cache, but the application does not copy/cache the complete country database.

ABM extraction requires and validates both runtime files. The extraction revision was bumped so an older one-file extraction is not silently reused.

The offline MapLibre MBTiles URL is generated as `mbtiles://file://<absolute-path>`, matching MapLibre Native's documented local-file pattern.
