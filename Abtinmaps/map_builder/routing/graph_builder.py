from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import struct
import tempfile
from pathlib import Path
from typing import Iterable

try:
    from shapely.geometry import LineString
except ImportError:
    LineString = None

from abm_builder.core import tags_dict, way_geometry, entity_id, haversine_m, name_triple, geometry_intersects_bbox
from routing.geometry import encode_geometry

PIECE = 8  # segments per road_index (snap) entry
CELL_DEG = 0.25  # routing partition; runtime opens this cell plus a small neighborhood
GEOM_SCALE = 100000
GRAPH_VERSION = 2
# Service roads and tracks are routable on purpose: campus loops, hospital and
# university internal roads, terminals and driveways are mostly highway=service.
# Without them a destination inside such a compound had no road to snap to and
# the route stopped (or was never drawn) at the compound's outer street. The
# app's engine already treats them as "minor" ways (see routing_engine.dart:
# they are only searched near the route endpoints in the pruned tiers).
MINOR_ROAD_CLASSES = {"service", "track"}
ROAD_CLASSES = {
    "motorway", "motorway_link", "trunk", "trunk_link",
    "primary", "primary_link", "secondary", "secondary_link",
    "tertiary", "tertiary_link", "unclassified", "residential",
    "living_street", "road",
} | MINOR_ROAD_CLASSES
# service=* values that are never useful as a route: they only bloat the graph
# and let the router cut through parking lots.
EXCLUDED_SERVICE_KINDS = {"parking_aisle", "drive-through"}


def is_routable_way(tags: dict[str, str]) -> bool:
    highway = tags.get("highway")
    if highway not in ROAD_CLASSES:
        return False
    if highway in MINOR_ROAD_CLASSES:
        # Closed to cars entirely -> never routable. (access=private stays in
        # the graph; the app drops it when "avoid restricted zones" is on.)
        if str(tags.get("access", "")).lower() == "no":
            return False
        if str(tags.get("motor_vehicle", "")).lower() in {"no", "private"}:
            return False
        if str(tags.get("service", "")).lower() in EXCLUDED_SERVICE_KINDS:
            return False
    return True
DEFAULT_SPEED = {
    "motorway": 110, "motorway_link": 70, "trunk": 90, "trunk_link": 65,
    "primary": 70, "primary_link": 55, "secondary": 60, "secondary_link": 50,
    "tertiary": 50, "tertiary_link": 40, "unclassified": 40,
    "residential": 30, "living_street": 20, "service": 20, "track": 15, "road": 40,
}

def _cell_id(lon: float, lat: float) -> int:
    x = int((float(lon) + 180.0) / CELL_DEG)
    y = int((float(lat) + 90.0) / CELL_DEG)
    return (y << 20) | x


def _speed(tags: dict[str, str]) -> float:
    raw = str(tags.get("maxspeed", ""))
    num = ""
    for ch in raw:
        if ch.isdigit() or ch == ".":
            num += ch
        elif num:
            break
    try:
        value = float(num) if num else float(DEFAULT_SPEED[tags["highway"]])
    except (ValueError, KeyError):
        value = float(DEFAULT_SPEED.get(tags.get("highway", ""), 30))
    if "mph" in raw.lower():
        value *= 1.609344
    return value


def _is_oneway(tags: dict[str, str]) -> bool:
    return str(tags.get("oneway", "")).lower() in {"yes", "1", "true"}


def _restriction_rows(relations: Iterable) -> list[tuple[int, str, list[int], list[int], list[int]]]:
    rows = []
    for rel in relations:
        t = tags_dict(rel)
        kind = t.get("restriction", "")
        if t.get("type") != "restriction" and not kind.startswith(("only_", "no_")):
            continue
        members = rel.get("members", []) if isinstance(rel, dict) else list(getattr(rel, "members", []))
        role_refs = {"from": [], "via": [], "to": []}
        for m in members:
            role = m.get("role", "") if isinstance(m, dict) else getattr(m, "role", "")
            ref = m.get("ref") if isinstance(m, dict) else getattr(m, "ref", None)
            if role in role_refs and ref is not None:
                try:
                    role_refs[role].append(int(ref))
                except (TypeError, ValueError):
                    pass
        rows.append((entity_id(rel), kind, role_refs["from"], role_refs["via"], role_refs["to"]))
    return rows


def _open_store() -> tuple[sqlite3.Connection, Path]:
    fd, name = tempfile.mkstemp(prefix="abm-routing-", suffix=".sqlite3")
    os.close(fd)
    path = Path(name)
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    con.execute("PRAGMA temp_store=FILE")
    # Staging only; map.sqlite gets the normalized form (see merge_graph).
    con.executescript("""
        CREATE TABLE node_data(id INTEGER PRIMARY KEY, lat_e7 INTEGER NOT NULL, lon_e7 INTEGER NOT NULL, cell_id INTEGER NOT NULL);
        CREATE TABLE way_data(way_id INTEGER PRIMARY KEY, class TEXT NOT NULL,
            name TEXT NOT NULL, name_fa TEXT NOT NULL, name_en TEXT NOT NULL,
            access TEXT NOT NULL, junction TEXT NOT NULL, surface TEXT NOT NULL,
            speed_kmh INTEGER NOT NULL, oneway INTEGER NOT NULL, lanes INTEGER NOT NULL DEFAULT 0,
            flags INTEGER NOT NULL DEFAULT 0,
            turn_lanes TEXT NOT NULL DEFAULT '', turn_lanes_bwd TEXT NOT NULL DEFAULT '');
        CREATE TABLE segments(id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b INTEGER NOT NULL,
            dist_dm INTEGER NOT NULL, way_id INTEGER NOT NULL, cell_id INTEGER NOT NULL);
        CREATE TABLE way_geometry(way_id INTEGER PRIMARY KEY, encoding TEXT NOT NULL, geometry BLOB NOT NULL);
        CREATE VIRTUAL TABLE road_index USING rtree(id, min_lon, max_lon, min_lat, max_lat,
            +seg_from INTEGER, +seg_to INTEGER);
        CREATE TABLE turn_restrictions(id INTEGER PRIMARY KEY, restriction TEXT NOT NULL,
            from_json TEXT NOT NULL, via_json TEXT NOT NULL, to_json TEXT NOT NULL);
    """)
    con.commit()
    return con, path


def _node_ids(way, geom: list[tuple[float, float]]) -> list[int]:
    raw = list(getattr(way, "nodes", []) or [])
    if isinstance(way, dict):
        raw = list(way.get("node_ids", raw) or [])
    ids = []
    for n in raw:
        if isinstance(n, int):
            ids.append(n)
        elif isinstance(n, dict) and n.get("ref") is not None:
            ids.append(int(n["ref"]))
        elif getattr(n, "ref", None) is not None:
            ids.append(int(n.ref))
    if len(ids) == len(geom):
        return ids
    # Stable fallback for JSON fixtures that have geometry but no node refs.
    result = []
    for lon, lat in geom:
        digest = hashlib.blake2b(f"{lon:.7f},{lat:.7f}".encode(), digest_size=8).digest()
        result.append(int.from_bytes(digest, "big") & ((1 << 63) - 1))
    return result


def _add_way(con: sqlite3.Connection, way, next_edge: int) -> tuple[int, int]:
    tags = tags_dict(way)
    highway = tags.get("highway")
    if not is_routable_way(tags):
        return next_edge, 0
    geom = way_geometry(way)
    if len(geom) < 2:
        return next_edge, 0
    ids = _node_ids(way, geom)
    ow = str(tags.get("oneway", "")).lower()
    oneway = int(ow in {"yes", "1", "true", "-1"})
    reverse = ow == "-1"
    # ONE row per segment: a two-way road is not mirrored into a second row
    # (the `edges` view derives the reverse direction), and speed/oneway/name
    # live once per way in way_data instead of on every segment.
    segs = []
    seen_pairs = set()
    for i, (a, b) in enumerate(zip(ids, ids[1:])):
        if a == b:
            continue
        # A way that revisits the same node pair (double-back / spur) would
        # create a duplicate physical segment and abort the whole build in
        # _validate_physical_graph. Keep only the first traversal.
        pair = (a, b) if a < b else (b, a)
        if pair in seen_pairs:
            continue
        seen_pairs.add(pair)
        (lon1, lat1), (lon2, lat2) = geom[i], geom[i + 1]
        # Two distinct OSM nodes can share a coordinate; keep the physical
        # connection with a minimal positive length instead of a 0 distance
        # (which the validator rejects).
        dist_dm = max(1, int(round(haversine_m((lat1, lon1), (lat2, lon2)) * 10)))
        # The stored from/to orientation is explicit. For OSM oneway=-1 it
        # points opposite to the source geometry, and the edges view exposes
        # only this routable direction.
        segs.append((b, a, dist_dm, i) if reverse else (a, b, dist_dm, i))
    if not segs:
        return next_edge, 0
    way_id = entity_id(way)
    n, fa, en = name_triple(tags.get("name"), tags.get("name:fa"), tags.get("name:en"))
    lanes_raw = str(tags.get("lanes", "")).split("-")[0]
    try:
        lanes = int(float(lanes_raw))
    except ValueError:
        lanes = 0
    # Per-lane turn arrows ("left|through|through;right"), in travel direction.
    # One-way roads use turn:lanes; two-way roads use :forward / :backward.
    def _tl(*keys: str) -> str:
        for k in keys:
            v = str(tags.get(k, "")).strip().lower().replace(" ", "")
            if v:
                return v
        return ""
    turn_fwd = _tl("turn:lanes:forward", "turn:lanes")
    turn_bwd = _tl("turn:lanes:backward")
    flags = 0
    for bit, key in enumerate(("bridge", "tunnel", "toll", "ferry")):
        val = str(tags.get(key, "")).strip().lower()
        if key == "bridge":
            # bridge=yes / viaduct / suspension / cantilever / movable ... all count.
            is_on = val not in {"", "no", "false", "0"}
        else:
            is_on = val in {"yes", "true", "1"}
        if is_on:
            flags |= 1 << bit
    # Vertical level of the way (OSM layer, clamped to -4..4) in bits 4..7 as
    # layer + 8, so the app can tell which of two crossing roads is the upper one.
    try:
        lay = max(-4, min(4, int(float(str(tags.get("layer", "0")).split(";")[0]))))
    except ValueError:
        lay = 0
    flags |= (lay + 8) << 4
    cur = con.execute(
        "INSERT OR IGNORE INTO way_data VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (way_id, highway, n, fa, en, tags.get("access", ""), tags.get("junction", ""),
         tags.get("surface", ""), int(round(_speed(tags))), oneway, lanes, flags, turn_fwd, turn_bwd))
    if cur.rowcount == 0:  # this way was already added: never insert it twice
        return next_edge, 0
    con.executemany(
        "INSERT OR IGNORE INTO node_data VALUES (?,?,?,?)",
        [(int(nid), int(round(lat * 1e7)), int(round(lon * 1e7)), _cell_id(lon, lat))
         for nid, (lon, lat) in zip(ids, geom)])
    con.executemany("INSERT INTO segments VALUES (?,?,?,?,?,?)",
                    [(next_edge + j, a, b, d, way_id,
                      _cell_id((geom[i][0] + geom[i + 1][0]) / 2.0,
                               (geom[i][1] + geom[i + 1][1]) / 2.0))
                     for j, (a, b, d, i) in enumerate(segs)])
    con.execute(
        "INSERT OR REPLACE INTO way_geometry VALUES (?,?,?)",
        (way_id, "delta-zigzag-varint-e5", encode_geometry(geom)),
    )
    pieces = []
    for st in range(0, len(segs), PIECE):
        chunk = segs[st:st + PIECE]
        pts = [geom[i] for *_, i in chunk] + [geom[chunk[-1][3] + 1]]
        pts += [geom[i + 1] for *_, i in chunk]
        pieces.append((next_edge + st, min(p[0] for p in pts), max(p[0] for p in pts),
                       min(p[1] for p in pts), max(p[1] for p in pts),
                       next_edge + st, next_edge + st + len(chunk) - 1))
    con.executemany("INSERT INTO road_index VALUES (?,?,?,?,?,?,?)", pieces)
    return next_edge + len(segs), len(segs)


def _validate_physical_graph(con: sqlite3.Connection) -> None:
    """Validate that routing is made only from physical OSM segments.

    The runtime must never have to infer a road connection from proximity.
    `segments` is the authoritative physical graph: every segment must belong
    to one real way, both endpoints must exist, its geometry must exist, and
    duplicate physical pairs for the same way are rejected.  The directed
    `edges` view is derived from these rows later, so this validation also
    guarantees that the builder cannot manufacture a cross-carriageway edge.
    """
    checks = [
        ("segments_missing_way", """
            SELECT COUNT(*) FROM segments s
            LEFT JOIN way_data w ON w.way_id=s.way_id
            WHERE w.way_id IS NULL
        """),
        ("segments_missing_node", """
            SELECT COUNT(*) FROM segments s
            LEFT JOIN node_data a ON a.id=s.a
            LEFT JOIN node_data b ON b.id=s.b
            WHERE a.id IS NULL OR b.id IS NULL
        """),
        ("segments_nonpositive_distance", "SELECT COUNT(*) FROM segments WHERE dist_dm <= 0"),
        ("segments_missing_geometry", """
            SELECT COUNT(*) FROM segments s
            LEFT JOIN way_geometry g ON g.way_id=s.way_id
            WHERE g.way_id IS NULL
        """),
        ("segments_duplicate_physical_pair", """
            SELECT COUNT(*) FROM (
              SELECT way_id,
                     CASE WHEN a < b THEN a ELSE b END lo,
                     CASE WHEN a < b THEN b ELSE a END hi,
                     COUNT(*) n
              FROM segments GROUP BY way_id, lo, hi HAVING COUNT(*) > 1
            )
        """),
        ("road_index_bad_segment_range", """
            SELECT COUNT(*) FROM road_index r
            WHERE r.seg_from > r.seg_to
               OR NOT EXISTS (SELECT 1 FROM segments s WHERE s.id=r.seg_from)
               OR NOT EXISTS (SELECT 1 FROM segments s WHERE s.id=r.seg_to)
        """),
    ]
    failures = []
    for name, sql in checks:
        count = int(con.execute(sql).fetchone()[0])
        if count:
            failures.append(f"{name}={count}")
    if failures:
        raise RuntimeError("Physical routing graph validation failed: " + ", ".join(failures))

def _write_graph(con: sqlite3.Connection, restrictions: list[tuple[int, str, list[int], list[int], list[int]]], out: Path) -> None:
    """Persist the staging graph as a standalone SQLite file for merge_graph()."""
    out.parent.mkdir(parents=True, exist_ok=True)
    con.executemany(
        "INSERT OR IGNORE INTO turn_restrictions VALUES (?,?,?,?,?)",
        [(rid, kind, json.dumps(fr), json.dumps(vi), json.dumps(to)) for rid, kind, fr, vi, to in restrictions],
    )
    con.commit()
    if out.exists():
        out.unlink()
    dst = sqlite3.connect(out)
    try:
        con.backup(dst)
        dst.commit()
    finally:
        dst.close()


def merge_graph(map_db: Path, graph_db: Path) -> None:
    """Fold the staged routing graph into map.sqlite in normalized form:
    names/categories are shared with search (no repeated strings), per-way data
    is stored once, coordinates are int e7, and road_index replaces the huge
    per-node rtree for snapping."""
    con = sqlite3.connect(map_db)
    try:
        con.execute("ATTACH DATABASE ? AS g", (str(graph_db),))
        con.executescript("""
            INSERT OR IGNORE INTO categories(name) SELECT DISTINCT class FROM g.way_data;
            INSERT OR IGNORE INTO nm(name, name_fa, name_en)
                SELECT DISTINCT name, name_fa, name_en FROM g.way_data
                WHERE name <> '' OR name_fa <> '' OR name_en <> '';
            CREATE TABLE node_data(id INTEGER PRIMARY KEY, lat_e7 INTEGER NOT NULL, lon_e7 INTEGER NOT NULL, cell_id INTEGER NOT NULL);
            CREATE TABLE way_data(way_id INTEGER PRIMARY KEY, class_id INTEGER NOT NULL, name_id INTEGER,
                access TEXT, junction TEXT, surface TEXT, speed_kmh INTEGER NOT NULL, oneway INTEGER NOT NULL,
                lanes INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0,
                turn_lanes TEXT, turn_lanes_bwd TEXT);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b INTEGER NOT NULL,
                dist_dm INTEGER NOT NULL, way_id INTEGER NOT NULL, cell_id INTEGER NOT NULL);
            CREATE TABLE way_geometry(way_id INTEGER PRIMARY KEY, encoding TEXT NOT NULL, geometry BLOB NOT NULL);
            CREATE VIRTUAL TABLE road_index USING rtree(id, min_lon, max_lon, min_lat, max_lat,
                +seg_from INTEGER, +seg_to INTEGER);
            CREATE TABLE turn_restrictions(id INTEGER PRIMARY KEY, restriction TEXT NOT NULL,
                from_json TEXT NOT NULL, via_json TEXT NOT NULL, to_json TEXT NOT NULL);
            CREATE TABLE turn_restriction_lookup(
                restriction_id INTEGER NOT NULL, restriction TEXT NOT NULL,
                from_way INTEGER NOT NULL, via_node INTEGER NOT NULL, to_way INTEGER NOT NULL,
                PRIMARY KEY(restriction_id, from_way, via_node, to_way)
            ) WITHOUT ROWID;
            INSERT INTO node_data SELECT id, lat_e7, lon_e7, cell_id FROM g.node_data ORDER BY id;
            INSERT INTO way_data
                SELECT w.way_id, c.id, n.id, NULLIF(w.access,''), NULLIF(w.junction,''),
                       NULLIF(w.surface,''), w.speed_kmh, w.oneway, w.lanes, w.flags,
                       NULLIF(w.turn_lanes,''), NULLIF(w.turn_lanes_bwd,'')
                FROM g.way_data w JOIN categories c ON c.name = w.class
                LEFT JOIN nm n ON n.name = w.name AND n.name_fa = w.name_fa AND n.name_en = w.name_en
                ORDER BY w.way_id;
            INSERT INTO segments SELECT id, a, b, dist_dm, way_id, cell_id FROM g.segments ORDER BY id;
            INSERT INTO way_geometry SELECT way_id, encoding, geometry FROM g.way_geometry ORDER BY way_id;
            INSERT INTO road_index(id, min_lon, max_lon, min_lat, max_lat, seg_from, seg_to)
                SELECT id, min_lon, max_lon, min_lat, max_lat, seg_from, seg_to FROM g.road_index ORDER BY id;
            INSERT INTO turn_restrictions SELECT id, restriction, from_json, via_json, to_json
                FROM g.turn_restrictions ORDER BY id;
        """)
        def refs(value: str) -> list[int]:
            try:
                parsed = json.loads(value)
                return [int(item) for item in parsed if isinstance(item, (int, float))]
            except (TypeError, ValueError, json.JSONDecodeError):
                return []

        def lookup_rows():
            for rid, restriction, from_json, via_json, to_json in con.execute(
                "SELECT id, restriction, from_json, via_json, to_json FROM g.turn_restrictions"
            ):
                for from_way in refs(from_json):
                    for via_node in refs(via_json):
                        for to_way in refs(to_json):
                            yield (rid, restriction, from_way, via_node, to_way)

        con.executemany(
            "INSERT OR IGNORE INTO turn_restriction_lookup VALUES (?,?,?,?,?)",
            lookup_rows(),
        )
        con.executescript("""
            CREATE INDEX IF NOT EXISTS idx_node_data_cell ON node_data(cell_id);
            CREATE INDEX IF NOT EXISTS idx_segments_cell ON segments(cell_id);
            CREATE TABLE IF NOT EXISTS routing_cells(
                cell_id INTEGER PRIMARY KEY,
                min_lon REAL NOT NULL, min_lat REAL NOT NULL,
                max_lon REAL NOT NULL, max_lat REAL NOT NULL,
                node_count INTEGER NOT NULL DEFAULT 0,
                edge_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_routing_cells_bbox
                ON routing_cells(min_lon, max_lon, min_lat, max_lat);
            CREATE VIRTUAL TABLE IF NOT EXISTS node_index USING rtree(
                id, min_lon, max_lon, min_lat, max_lat
            );
            CREATE TABLE IF NOT EXISTS hierarchy_edges(
                level INTEGER NOT NULL,
                edge_id INTEGER NOT NULL,
                PRIMARY KEY(level, edge_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS roundabout_info(
                way_id INTEGER PRIMARY KEY,
                junction TEXT NOT NULL,
                entry_edge INTEGER,
                exit_edge INTEGER,
                exit_number INTEGER,
                exit_count INTEGER
            );
        """)
        con.execute("DELETE FROM node_index")
        con.execute("""
            INSERT INTO node_index(id,min_lon,max_lon,min_lat,max_lat)
            SELECT id, lon_e7*1e-7, lon_e7*1e-7, lat_e7*1e-7, lat_e7*1e-7
            FROM node_data
        """)
        con.execute("DELETE FROM hierarchy_edges")
        con.execute("""
            INSERT INTO hierarchy_edges(level, edge_id)
            SELECT CASE
                WHEN c.name = 'motorway' THEN 3
                WHEN c.name IN ('trunk','motorway_link','trunk_link') THEN 2
                WHEN c.name IN ('primary','primary_link','secondary','secondary_link') THEN 1
                ELSE 0 END,
                s.id
            FROM segments s
            JOIN way_data w ON w.way_id=s.way_id
            JOIN categories c ON c.id=w.class_id
        """)
        con.execute("DELETE FROM roundabout_info")
        con.execute("""
            INSERT INTO roundabout_info(way_id,junction,entry_edge,exit_edge,exit_number,exit_count)
            SELECT w.way_id, COALESCE(w.junction,''), MIN(s.id), NULL, NULL, NULL
            FROM way_data w JOIN segments s ON s.way_id=w.way_id
            WHERE w.junction='roundabout'
            GROUP BY w.way_id
        """)
        con.execute("DELETE FROM routing_cells")
        con.execute("""
            INSERT INTO routing_cells(cell_id,min_lon,min_lat,max_lon,max_lat,node_count,edge_count)
            SELECT cell_id,
                   MIN(lon_e7*1e-7), MIN(lat_e7*1e-7),
                   MAX(lon_e7*1e-7), MAX(lat_e7*1e-7),
                   COUNT(*), 0
            FROM node_data GROUP BY cell_id
        """)
        con.execute("""
            INSERT INTO routing_cells(cell_id,min_lon,min_lat,max_lon,max_lat,node_count,edge_count)
            SELECT s.cell_id,
                   MIN(n1.lon_e7*1e-7), MIN(n1.lat_e7*1e-7),
                   MAX(n2.lon_e7*1e-7), MAX(n2.lat_e7*1e-7),
                   0, COUNT(*)
            FROM segments s
            JOIN node_data n1 ON n1.id=s.a
            JOIN node_data n2 ON n2.id=s.b
            GROUP BY s.cell_id
            ON CONFLICT(cell_id) DO UPDATE SET
              min_lon=MIN(routing_cells.min_lon,excluded.min_lon),
              min_lat=MIN(routing_cells.min_lat,excluded.min_lat),
              max_lon=MAX(routing_cells.max_lon,excluded.max_lon),
              max_lat=MAX(routing_cells.max_lat,excluded.max_lat),
              edge_count=routing_cells.edge_count+excluded.edge_count
        """)
        con.execute("PRAGMA user_version=2")
        con.commit()
        con.execute("DETACH DATABASE g")
    finally:
        con.close()


def build_graph(ways, relations, out: Path) -> dict:
    """Build the existing graph format with disk-backed intermediate storage."""
    con, db_path = _open_store()
    next_edge = 1
    try:
        for way in ways:
            next_edge, edge_count = _add_way(con, way, next_edge)
            if edge_count and next_edge % 100_000 < edge_count:
                con.commit()
        con.commit()
        restrictions = _restriction_rows(relations)
        _validate_physical_graph(con)
        _write_graph(con, restrictions, out)
        stats = {
            "nodes": int(con.execute("SELECT COUNT(*) FROM node_data").fetchone()[0]),
            "edges": int(con.execute("SELECT COUNT(*) FROM segments").fetchone()[0]),
            "turn_restrictions": len(restrictions),
        }
        if stats["nodes"] <= 0 or stats["edges"] <= 0:
            raise RuntimeError(
                f"Routing graph is empty: nodes={stats['nodes']} "
                f"edges={stats['edges']}"
            )
        return stats
    finally:
        con.close()
        db_path.unlink(missing_ok=True)


def build_graph_from_pbf(path: Path, out: Path, bbox: tuple[float, float, float, float] | None = None, region_geometry=None) -> dict:
    """Build routing directly from a PBF stream; ways are never materialized."""
    try:
        import osmium
    except ImportError as e:
        raise RuntimeError("PBF input requires osmium; install requirements.txt") from e

    con, db_path = _open_store()
    next_edge = 1
    way_count = 0
    highway_count = 0
    invalid_location_count = 0
    outside_bbox_count = 0
    crossing_way_count = 0
    relations = []

    class Handler(osmium.SimpleHandler):
        def way(self, o):
            nonlocal next_edge, way_count
            tags = tags_dict(o)
            if not is_routable_way(tags):
                return
            nonlocal highway_count, invalid_location_count, outside_bbox_count, crossing_way_count
            highway_count += 1

            # IMPORTANT: a regional routing graph must never contain a sliced
            # version of an OSM way. First collect the complete valid source
            # geometry, then decide whether the complete way touches the
            # routing bbox. If it does, keep ALL of its nodes and segments.
            # This preserves stable OSM node IDs at region boundaries and
            # prevents artificial dead-ends.
            points = []
            refs = []
            for n in o.nodes:
                if not n.location.valid():
                    invalid_location_count += 1
                    continue
                lon, lat = float(n.location.lon), float(n.location.lat)
                refs.append(int(n.ref))
                points.append((lon, lat))

            if len(points) < 2:
                return
            if region_geometry is not None:
                if LineString is None:
                    raise RuntimeError("Polygon regional routing requires shapely>=2; install requirements.txt")
                if not region_geometry.intersects(LineString(points)):
                    return
            elif bbox is not None and not geometry_intersects_bbox(points, bbox):
                return

            if bbox is not None:
                outside_bbox_count += sum(
                    not (bbox[0] <= lon <= bbox[2] and bbox[1] <= lat <= bbox[3])
                    for lon, lat in points
                )
                if any(not (bbox[0] <= lon <= bbox[2] and bbox[1] <= lat <= bbox[3])
                       for lon, lat in points):
                    crossing_way_count += 1

            class Node:
                def __init__(self, ref, lon, lat):
                    self.ref, self.lon, self.lat = ref, lon, lat
            class Way:
                pass
            w = Way()
            # The staging writer keys way_data by the real OSM way id.
            # Omitting this id made every streamed PBF way look like way 0;
            # INSERT OR IGNORE then kept only the first road in map.sqlite.
            w.id = int(o.id)
            w.tags = tags
            w.nodes = [Node(ref, lon, lat) for ref, (lon, lat) in zip(refs, points)]
            next_edge, edge_count = _add_way(con, w, next_edge)
            if edge_count > 0:
                way_count += 1
            if next_edge % 100_000 < 3:
                con.commit()

        def relation(self, o):
            tags = tags_dict(o)
            kind = tags.get("restriction", "")
            if tags.get("type") != "restriction" and not kind.startswith(("only_", "no_")):
                return
            relations.append({
                "id": int(o.id), "tags": tags,
                "members": [{"type": m.type, "ref": int(m.ref), "role": m.role} for m in o.members],
            })

    try:
        Handler().apply_file(str(path), locations=True)
        con.commit()
        restrictions = _restriction_rows(relations)
        _validate_physical_graph(con)
        _write_graph(con, restrictions, out)
        stats = {
            "nodes": int(con.execute("SELECT COUNT(*) FROM node_data").fetchone()[0]),
            "segments": int(con.execute("SELECT COUNT(*) FROM segments").fetchone()[0]),
            "edges": int(con.execute("SELECT COUNT(*) FROM segments").fetchone()[0]),
            "ways": int(con.execute("SELECT COUNT(*) FROM way_data").fetchone()[0]),
            "turn_restrictions": len(restrictions),
            "highway_ways_seen": highway_count,
            "invalid_locations": invalid_location_count,
            "outside_bbox_nodes": outside_bbox_count,
            "crossing_ways": crossing_way_count,
            "regional_geometry_policy": "full_way_no_clip",
        }
        # A streamed PBF must retain distinct OSM way ids. If the source contains
        # many routable ways but the staging DB contains only one, fail the build
        # before packaging a truncated country graph. Small fixtures are allowed.
        if stats["highway_ways_seen"] >= 10 and stats["ways"] < max(2, int(stats["highway_ways_seen"] * 0.01)):
            raise RuntimeError(
                "Routing graph lost most routable ways: "
                + ", ".join(f"{key}={value}" for key, value in stats.items())
            )
        if stats["nodes"] <= 0 or stats["edges"] <= 0:
            raise RuntimeError(
                "Routing graph is empty: "
                + ", ".join(f"{key}={value}" for key, value in stats.items())
            )
        return stats
    finally:
        con.close()
        db_path.unlink(missing_ok=True)
