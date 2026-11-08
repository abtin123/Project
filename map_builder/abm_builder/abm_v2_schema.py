"""ABM v2 routing contract.

The builder materializes these tables in map.sqlite. Runtime must treat them
as read-only, spatially partitioned data: select routing_cells first, load only
the active cell/neighbours, run graph search on edges/segments, then fetch
way_geometry only for selected way IDs.
"""

SCHEMA_VERSION = 7
GRAPH_VERSION = 2
CELL_DEGREES = 0.25
GEOMETRY_ENCODING = "delta-zigzag-varint-e5"

ROUTING_TABLES = (
    "routing_cells", "node_data", "node_index", "way_data", "segments",
    "road_index", "way_geometry", "turn_restrictions",
    "turn_restriction_lookup", "hierarchy_edges", "roundabout_info",
)

REQUIRED_INDEXES = (
    "idx_node_data_cell", "idx_segments_cell", "idx_segments_a",
    "idx_segments_b", "idx_turn_lookup_route",
)
