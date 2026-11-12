# ABM v2 builder fixes

- Schema 7 / graph version 2.
- Routing graph is partition-aware using 0.25° geographic cells.
- `node_data.cell_id` and `segments.cell_id` plus indexes support lazy cell loading.
- `node_index` R-tree supports nearest-road candidate lookup without scanning all nodes.
- `way_geometry` stores compressed route geometry separately from graph/search records.
- `way_data` stores speed, lanes, access, one-way and bridge/tunnel/toll/ferry flags.
- `hierarchy_edges` materializes local/primary/trunk/motorway levels for long-route engines.
- `roundabout_info` records roundabout ways and route context fields.
- ABM metadata advertises the new routing contract.
- Builder validation now requires the new routing structures.
- Added geometry codec tests and expanded routing-index tests.

The existing `<archive-name>.sqlite` + `map.mbtiles` package contract is preserved; no existing runtime
table/view names such as `edges`, `nodes`, `ways`, `places`, or `poi` were removed.
