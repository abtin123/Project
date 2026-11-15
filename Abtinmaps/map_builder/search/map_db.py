from __future__ import annotations
import math
import sqlite3
from pathlib import Path
from abm_builder.core import name_triple, norm_fa

KIND_POI, KIND_PLACE, KIND_ROAD = 0, 1, 2
SCHEMA_VERSION = 7
# Importance of a geographic place type (lower = more important). A typed city
# name must win over the nearest *street* that merely contains that word.
PLACE_RANK = {c: i for i, c in enumerate((
    "city", "town", "village", "suburb", "hamlet", "neighbourhood"))}
ROAD_RANK = {c: i for i, c in enumerate((
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    "living_street", "road"))}
_CELL = 0.05  # ~5 km: same-named road ways inside one cell collapse to one search row

# Stage schema. `nm` has a UNIQUE key only while building (dedup guard); it is
# rewritten into an index-free `names` table by finalize_map_db so the strings
# are stored exactly once.
_STAGE = """
PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
CREATE TABLE categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE nm(id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_fa TEXT NOT NULL,
                name_en TEXT NOT NULL, UNIQUE(name, name_fa, name_en));
CREATE TABLE features(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, name_id INTEGER,
                      category_id INTEGER NOT NULL, opening_hours TEXT NOT NULL DEFAULT '');
CREATE VIRTUAL TABLE spatial USING rtree(id, min_lon, max_lon, min_lat, max_lat);
"""

_FINAL = """
CREATE TABLE names(id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_fa TEXT NOT NULL, name_en TEXT NOT NULL);
INSERT INTO names SELECT id, name, name_fa, name_en FROM nm ORDER BY id;
DROP TABLE nm;
CREATE INDEX idx_features_name ON features(name_id);
CREATE INDEX idx_segments_a ON segments(a);
CREATE INDEX idx_segments_b ON segments(b);
CREATE INDEX idx_restriction_kind ON turn_restrictions(restriction);
CREATE INDEX idx_turn_lookup_route ON turn_restriction_lookup(from_way, via_node, to_way, restriction);
CREATE VIRTUAL TABLE search_fts USING fts5(
    name, name_fa, name_en, content='names', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2');
INSERT INTO search_fts(search_fts) VALUES('rebuild');
CREATE VIEW nodes AS SELECT id, lat_e7 * 1e-7 AS lat, lon_e7 * 1e-7 AS lon FROM node_data;
CREATE VIEW ways AS
SELECT w.way_id AS way_id, c.name AS road_class,
       COALESCE(NULLIF(n.name_fa,''), NULLIF(n.name,''), NULLIF(n.name_en,''), '') AS name,
       COALESCE(w.access,'') AS access, COALESCE(w.junction,'') AS junction,
       COALESCE(w.surface,'') AS surface, w.speed_kmh AS speed_kmh,
       w.lanes AS lanes, w.flags AS flags, w.oneway AS oneway,
       w.turn_lanes AS turn_lanes, w.turn_lanes_bwd AS turn_lanes_bwd
FROM way_data w JOIN categories c ON c.id = w.class_id LEFT JOIN names n ON n.id = w.name_id;
CREATE VIEW edges AS
-- The physical segment orientation is the stored geometry orientation.
-- oneway=-1 means only the reverse direction is routable.
SELECT s.id AS id, s.a AS start, s.b AS "end", s.dist_dm / 10.0 AS distance_m,
       w.speed_kmh AS speed_kmh, w.oneway AS oneway, w.lanes AS lanes, w.flags AS flags,
       s.way_id AS way_id, s.cell_id AS cell_id
FROM segments s JOIN way_data w ON w.way_id = s.way_id
WHERE COALESCE(w.oneway,0) <> -1
UNION ALL
-- Compact storage contract: a two-way physical segment is stored once.
-- Its reverse movement is synthesized here for runtime consumers.
SELECT -s.id, s.b, s.a, s.dist_dm / 10.0, w.speed_kmh,
       CASE WHEN w.oneway = -1 THEN 1 ELSE 0 END, w.lanes, w.flags,
       s.way_id, s.cell_id
FROM segments s JOIN way_data w ON w.way_id = s.way_id
WHERE COALESCE(w.oneway,0) IN (0,-1);
CREATE VIEW places AS
SELECT f.id AS id, COALESCE(n.name,'') AS name, COALESCE(n.name_fa,'') AS name_fa,
       COALESCE(n.name_en,'') AS name_en, c.name AS category,
       (s.min_lat + s.max_lat) / 2 AS lat, (s.min_lon + s.max_lon) / 2 AS lon,
       f.opening_hours AS opening_hours
FROM features f JOIN categories c ON c.id = f.category_id
LEFT JOIN names n ON n.id = f.name_id LEFT JOIN spatial s ON s.id = f.id;
CREATE VIEW poi AS
SELECT f.id AS id, f.id >> 2 AS source_id, COALESCE(n.name,'') AS name,
       COALESCE(n.name_fa,'') AS name_fa, COALESCE(n.name_en,'') AS name_en,
       c.name AS category, (s.min_lat + s.max_lat) / 2 AS lat,
       (s.min_lon + s.max_lon) / 2 AS lon, f.opening_hours AS opening_hours
FROM features f JOIN categories c ON c.id = f.category_id
LEFT JOIN names n ON n.id = f.name_id LEFT JOIN spatial s ON s.id = f.id WHERE f.kind = 0;
"""


def _fid(kind: int, source_id: int) -> int:
    # Namespaced id: OSM node/way ids overlap, so kind lives in the low 2 bits.
    return (int(source_id) << 2) | kind


def create_map_db(path: Path, pois: list[dict], places: list[dict], roads: list[dict]) -> int:
    """Stage features/names/spatial. Call merge_graph() then finalize_map_db()."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    con = sqlite3.connect(path)
    try:
        con.executescript(_STAGE)
        cats: dict[str, int] = {}
        names: dict[tuple[str, str, str], int] = {}
        used: set[int] = set()
        seen: set[tuple] = set()
        feats: list[tuple] = []
        spat: list[tuple] = []

        def cat_id(c: str) -> int:
            i = cats.get(c)
            if i is None:
                i = cats[c] = len(cats) + 1
            return i

        def name_id(t: tuple[str, str, str]):
            if not (t[0] or t[1] or t[2]):
                return None
            i = names.get(t)
            if i is None:
                i = names[t] = len(names) + 1
            return i

        def add(kind, source_id, t, category, lat, lon, hours=''):
            if lat is None or lon is None:
                return
            fid = _fid(kind, source_id)
            key = (kind, t, category, round(lat, 6), round(lon, 6))
            if fid in used or key in seen:  # same object twice / same place mapped twice
                return
            used.add(fid); seen.add(key)
            feats.append((fid, kind, name_id(t), cat_id(category or 'poi'), hours or ''))
            spat.append((fid, lon, lon, lat, lat))

        for p in pois:
            add(KIND_POI, p['id'], name_triple(p.get('name'), p.get('name_fa'), p.get('name_en')),
                p.get('category', 'poi'), p.get('latitude'), p.get('longitude'), p.get('opening_hours', ''))

        for p in places:
            t = p.get('tags', {})
            g = p.get('geometry', [])
            lat = sum(y for _, y in g) / len(g) if g else None
            lon = sum(x for x, _ in g) / len(g) if g else None
            add(KIND_PLACE, p['id'], name_triple(t.get('name', p.get('name')), t.get('name_fa', p.get('name_fa')),
                                                 t.get('name_en', p.get('name_en'))),
                t.get('place', p.get('place_type', 'place')), lat, lon)

        groups: dict[tuple, list] = {}
        for r in roads:
            t = r.get('tags', {})
            nt = name_triple(t.get('name', r.get('name')), t.get('name_fa', r.get('name_fa')),
                             t.get('name_en', r.get('name_en')))
            g = r.get('geometry', [])
            if not g or not (nt[0] or nt[1] or nt[2]):
                continue
            lat = sum(y for _, y in g) / len(g); lon = sum(x for x, _ in g) / len(g)
            cls = t.get('highway', r.get('road_class', 'road'))
            k = (nt, int(lat // _CELL), int(lon // _CELL))
            e = groups.get(k)
            if e is None:
                groups[k] = [1, lat, lon, cls, int(r['id'])]
            else:
                e[0] += 1; e[1] += lat; e[2] += lon
                if ROAD_RANK.get(cls, 99) < ROAD_RANK.get(e[3], 99):
                    e[3] = cls
                e[4] = min(e[4], int(r['id']))
        for (nt, _, _), (n, slat, slon, cls, sid) in groups.items():
            add(KIND_ROAD, sid, nt, cls, slat / n, slon / n)

        con.executemany("INSERT INTO categories VALUES (?,?)", [(i, c) for c, i in cats.items()])
        con.executemany("INSERT INTO nm VALUES (?,?,?,?)", [(i, *t) for t, i in names.items()])
        con.executemany("INSERT INTO features VALUES (?,?,?,?,?)", feats)
        con.executemany("INSERT INTO spatial VALUES (?,?,?,?,?)", spat)
        con.commit()
        return len(feats)
    finally:
        con.close()


def finalize_map_db(path: Path) -> None:
    con = sqlite3.connect(path)
    try:
        con.executescript(_FINAL)
        con.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        # Routing indexes are created by routing.graph_builder. Keep lightweight
        # compatibility indexes here for runtimes that inspect the finalized DB.
        con.execute("CREATE INDEX IF NOT EXISTS idx_way_data_class ON way_data(class_id)")
        con.execute("CREATE INDEX IF NOT EXISTS idx_way_data_name ON way_data(name_id)")
        con.commit()
        con.execute("PRAGMA analysis_limit=1000")
        con.execute("ANALYZE")
        con.commit()
        con.execute("VACUUM")
    finally:
        con.close()


def _distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in meters (Haversine)."""
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(min(1.0, a)))


def _row_sql(where_extra: str = "") -> str:
    return (
        "SELECT f.id, f.kind, n.name, n.name_fa, n.name_en, c.name AS category, "
        "(s.min_lat+s.max_lat)/2 AS lat, (s.min_lon+s.max_lon)/2 AS lon, f.opening_hours, "
        "bm25(search_fts) AS rank FROM search_fts "
        "JOIN names n ON n.id = search_fts.rowid JOIN features f ON f.name_id = n.id "
        "JOIN categories c ON c.id = f.category_id JOIN spatial s ON s.id = f.id "
        "WHERE search_fts MATCH ? " + where_extra
    )


def search(path: Path, query: str, limit=20, latitude: float | None = None,
           longitude: float | None = None):
    """Search one regional DB.

    Geographic places (city/town/village/...) whose name matches the query are
    returned FIRST, ordered by place importance and then by distance. Only
    after them come streets/POIs: with GPS coordinates those are ordered by
    proximity, otherwise by FTS5 bm25 relevance.

    Places are queried separately so that a typed city name ("تهران") is never
    pushed out of the candidate window by thousands of nearby streets that
    merely contain the same word.
    """
    q = norm_fa(query).replace('"', ' ').strip()
    if not q or limit <= 0:
        return []
    has_gps = latitude is not None and longitude is not None
    con = sqlite3.connect(path); con.row_factory = sqlite3.Row
    try:
        # Fetch a wider candidate set before applying distance ordering. This is
        # important because the closest match may have a weaker FTS rank than
        # the first `limit` text matches.
        fetch_limit = max(limit * 20, 100) if has_gps else limit
        match = q + '*'
        place_rows = [dict(r) for r in con.execute(
            _row_sql("AND f.kind = ? ORDER BY rank LIMIT ?"),
            (match, KIND_PLACE, max(limit * 5, 30)))]
        rows = [dict(r) for r in con.execute(
            _row_sql("ORDER BY rank LIMIT ?"), (match, fetch_limit))]
        if has_gps:
            for item in place_rows + rows:
                item['distance_m'] = _distance_m(latitude, longitude, item['lat'], item['lon'])
            rows.sort(key=lambda x: (x['distance_m'], x['rank']))
        place_rows.sort(key=lambda x: (
            0 if norm_fa(x['name_fa'] or x['name']) == q or norm_fa(x['name']) == q else 1,
            PLACE_RANK.get(x['category'], 99),
            x.get('distance_m', 0.0), x['rank']))
        seen = {r['id'] for r in place_rows}
        return (place_rows + [r for r in rows if r['id'] not in seen])[:limit]
    finally:
        con.close()


def search_many(paths, query: str, limit=20, latitude: float | None = None,
                longitude: float | None = None):
    """Search all active regional DBs and rank globally by GPS distance.

    `paths` may be any iterable of SQLite paths. Every DB is searched; results
    are merged and then sorted globally. With GPS, the nearest feature across
    all active provinces is always returned first.
    """
    if limit <= 0:
        return []
    merged = []
    for path in paths:
        for item in search(path, query, limit=max(limit * 20, 100),
                           latitude=latitude, longitude=longitude):
            item = dict(item)
            item['database'] = str(path)
            merged.append(item)
    def key(x):
        is_place = 0 if x.get('kind') == KIND_PLACE else 1
        if latitude is not None and longitude is not None:
            if is_place == 0:
                return (0, PLACE_RANK.get(x['category'], 99), x['distance_m'], x['rank'])
            return (1, 0, x['distance_m'], x['rank'])
        return (is_place, PLACE_RANK.get(x['category'], 99) if is_place == 0 else 0, 0.0, x['rank'])
    merged.sort(key=key)
    return merged[:limit]
