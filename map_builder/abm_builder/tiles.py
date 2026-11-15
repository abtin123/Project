"""Build a spec-compliant MBTiles (gzip MVT) from extracted feature records.

Storage is the *normalized* MBTiles layout: ``map`` (z/x/y -> tile_id) +
``images`` (tile_id -> blob).  Byte-identical tiles (fully-covered forest /
water / empty-road tiles ...) are stored once.  Per-feature simplification
importance is computed once and reused for every zoom.
"""
from __future__ import annotations

import hashlib
import json
import math
import sqlite3
from pathlib import Path

from .mvt import (BUFFER, EXTENT, LINE, POLY, Layer, clip_lines, clip_rings, enc_lines,
                  enc_rings, encode_tile, importance, merc)

MAX_ZOOM = 14
TILE_LAYERS = ("roads", "buildings", "landuse", "water", "boundaries")
_ROAD_MINZ = {"motorway": 3, "trunk": 5, "primary": 6, "secondary": 8, "tertiary": 10,
              "unclassified": 11, "residential": 12, "road": 12, "living_street": 13,
              "service": 13, "pedestrian": 13, "track": 13, "busway": 13,
              "footway": 14, "path": 14, "cycleway": 14, "steps": 14, "bridleway": 14}
_MAJOR = {"motorway", "trunk", "primary", "secondary", "tertiary"}


class _F:
    __slots__ = ("layer", "fid", "gtype", "pts", "imp", "tags", "minz", "names", "name_z")


def _road_minz(cls: str) -> int:
    base = cls[:-5] if cls.endswith("_link") else cls
    z = _ROAD_MINZ.get(base, 12)
    return min(MAX_ZOOM, z + 2) if cls.endswith("_link") else z


def _flag(v) -> int:
    return 0 if v in ("", None, "no") else 1


def _roads(t):
    ow = str(t.get("oneway", "")).lower()
    tags = {"class": t.get("highway", "road")}
    if t.get("service"):
        tags["service"] = t["service"]
    if ow in ("yes", "true", "1"):
        tags["oneway"] = 1
    elif ow == "-1":
        tags["oneway"] = -1
    if _flag(t.get("bridge")):
        tags["bridge"] = 1
    if _flag(t.get("tunnel")):
        tags["tunnel"] = 1
    # Vertical level so the style can draw an upper bridge over a lower one
    # (multi-level interchanges). Only stored when it carries information.
    if tags.get("bridge") or tags.get("tunnel"):
        try:
            lay = max(-4, min(4, int(float(str(t.get("layer", "0")).split(";")[0]))))
        except ValueError:
            lay = 0
        if lay == 0 and tags.get("bridge"):
            lay = 1  # an unlabelled bridge still sits above ground-level roads
        if lay:
            tags["layer"] = lay
    minz = _road_minz(tags["class"])
    if tags.get("service") in ("parking_aisle", "driveway", "drive-through"):
        minz = MAX_ZOOM
    return tags, LINE, minz


def _road_names(t) -> dict:
    """Street-name attributes for the tile. `name` is the local (OSM) name,
    `name_fa` / `name_en` are written only when they differ from it."""
    name = (t.get("name") or "").strip()
    fa = (t.get("name_fa") or "").strip()
    en = (t.get("name_en") or "").strip()
    out = {}
    if name:
        out["name"] = name
    if fa and fa != name:
        out["name_fa"] = fa
    if en and en != name:
        out["name_en"] = en
    return out


def _meters(v):
    try:
        return float(str(v).lower().replace("m", "").replace(",", ".").strip())
    except ValueError:
        return None


def _levels_m(v):
    m = _meters(v)
    return None if m is None else m * 3.2


def _buildings(t):
    b = t.get("building", "yes")
    tags = {"building": b} if b != "yes" else {}
    h = _meters(t.get("height"))
    if h is None:
        lv = _levels_m(t.get("building:levels"))
        if lv is not None:
            h = lv + (_meters(t.get("roof:height")) or 0)
    base = _meters(t.get("min_height"))
    if base is None:
        base = _levels_m(t.get("building:min_level"))
    if h is not None and h > 0:
        tags["render_height"] = min(int(round(h)), 600)
        if base is not None and 0 < base < h:
            tags["render_min_height"] = int(round(base))
    return tags, POLY, 13


_LANDUSE_MINZ = {"forest": 6, "farmland": 8, "grass": 9, "residential": 8, "park": 10, "scrub": 9,
                 "wetland": 9, "sand": 8, "rock": 9, "commercial": 11, "industrial": 10,
                 "military": 9, "cemetery": 12, "institutional": 12, "parking": 13,
                 "transport": 11, "pitch": 13}


def _landuse(t):
    cls = t.get("landuse", "")
    return {"landuse": cls}, POLY, _LANDUSE_MINZ.get(cls, 8)


def _water(t):
    ww, nat = t.get("waterway", ""), t.get("natural", "")
    if ww:
        return {"class": ww}, LINE, {"river": 5, "canal": 9}.get(ww, 12)
    if nat == "coastline":
        return {"class": "coastline"}, LINE, 0
    return {"class": "water"}, POLY, 0


def _boundaries(t):
    try:
        lvl = int(t.get("admin_level", "") or 99)
    except ValueError:
        lvl = 99
    tags = {"admin_level": lvl}
    if t.get("name"):
        tags["name"] = t["name"]
    return tags, LINE, 0 if lvl <= 2 else 3 if lvl <= 4 else 7 if lvl <= 6 else 10


_RULES = {"roads": _roads, "buildings": _buildings, "landuse": _landuse,
          "water": _water, "boundaries": _boundaries}


def _prepare(all_data: dict) -> list[_F]:
    feats: list[_F] = []
    for layer, rule in _RULES.items():
        for r in all_data.get(f"{layer}.bin", ()):
            g = r.get("geometry") or []
            if len(g) < 2:
                continue
            rt = r.get("tags") or {}
            tags, gtype, minz = rule(rt)
            pts = [merc(x, y) for x, y in g]
            if gtype == POLY:
                if pts[0] != pts[-1]:
                    pts.append(pts[0])
                if len(pts) < 4:
                    continue
            f = _F()
            f.layer, f.fid, f.gtype, f.pts, f.tags, f.minz = layer, int(r["id"]), gtype, pts, tags, minz
            f.names, f.name_z = {}, 99
            if layer == "roads":
                f.names = _road_names(rt)
                # Major roads are labelled as soon as they are drawn; minor
                # streets from z13 (labels below that are unreadable anyway,
                # and every extra attribute costs bytes in every tile).
                f.name_z = minz if tags["class"].replace("_link", "") in _MAJOR else max(minz, 13)
            f.imp = importance(pts)
            feats.append(f)
    return feats


def _split(gtype, X, tx0, tx1, ty0, ty1, b):
    parts = [X] if gtype == LINE else [X[:-1]]
    clip = clip_lines if gtype == LINE else clip_rings
    out = {}
    for ty in range(ty0, ty1 + 1):
        rows = clip(parts, 1, ty - b, ty + 1 + b)
        if not rows:
            continue
        if tx0 == tx1:
            out[(tx0, ty)] = rows
            continue
        for tx in range(tx0, tx1 + 1):
            cols = clip(rows, 0, tx - b, tx + 1 + b)
            if cols:
                out[(tx, ty)] = cols
    return out


def _q(v: float) -> int:
    return int(math.floor(v + 0.5))


def _encode(gtype, parts, tx, ty):
    if gtype == LINE:
        lines = []
        for ln in parts:
            pts, last = [], None
            for x, y in ln:
                p = (_q((x - tx) * EXTENT), _q((y - ty) * EXTENT))
                if p != last:
                    pts.append(p)
                    last = p
            if len(pts) >= 2:
                lines.append(pts)
        return (LINE, enc_lines(lines)) if lines else None
    rings = []
    for r in parts:
        pts, last = [], None
        for x, y in r:
            p = (_q((x - tx) * EXTENT), _q((y - ty) * EXTENT))
            if p != last:
                pts.append(p)
                last = p
        if len(pts) > 1 and pts[0] == pts[-1]:
            pts.pop()
        if len(pts) < 3:
            continue
        area = sum(pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1] for i in range(len(pts) - 1))
        area += pts[-1][0] * pts[0][1] - pts[0][0] * pts[-1][1]
        if area == 0:
            continue
        if area < 0:
            pts.reverse()
        rings.append(pts)
    return (POLY, enc_rings(rings)) if rings else None


def build_mbtiles(path: Path, all_data: dict, bbox=None, maxzoom: int = MAX_ZOOM) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    feats = _prepare(all_data)
    con = sqlite3.connect(path)
    con.executescript("""
        PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
        CREATE TABLE metadata(name TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
        CREATE TABLE map(zoom_level INTEGER NOT NULL, tile_column INTEGER NOT NULL,
            tile_row INTEGER NOT NULL, tile_id INTEGER NOT NULL,
            PRIMARY KEY(zoom_level, tile_column, tile_row)) WITHOUT ROWID;
        CREATE TABLE images(tile_id INTEGER PRIMARY KEY, tile_data BLOB NOT NULL);
        CREATE VIEW tiles AS SELECT zoom_level, tile_column, tile_row, tile_data
            FROM map JOIN images ON images.tile_id = map.tile_id;
    """)
    seen: dict[bytes, int] = {}
    n_tiles = n_bytes = 0
    fields: dict[str, dict[str, str]] = {l: {} for l in TILE_LAYERS}
    zooms: dict[str, list[int]] = {}
    b = BUFFER / EXTENT
    for z in range(maxzoom + 1):
        n = 1 << z
        tol = (0.5 if z == maxzoom else 1.5) / (EXTENT * n)
        tiles: dict[tuple[int, int], dict[str, Layer]] = {}
        for f in feats:
            if f.minz > z:
                continue
            pts = [p for p, i in zip(f.pts, f.imp) if i > tol]
            if len(pts) < (2 if f.gtype == LINE else 4):
                continue
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            mnx, mxx, mny, mxy = min(xs) * n, max(xs) * n, min(ys) * n, max(ys) * n
            lim = 2 if f.gtype == LINE else 4
            if (mxx - mnx) * EXTENT < lim and (mxy - mny) * EXTENT < lim:
                continue
            tx0, tx1 = max(0, math.floor(mnx - b)), min(n - 1, math.floor(mxx + b))
            ty0, ty1 = max(0, math.floor(mny - b)), min(n - 1, math.floor(mxy + b))
            if tx0 > tx1 or ty0 > ty1:
                continue
            X = [(x * n, y * n) for x, y in pts]
            for (tx, ty), parts in _split(f.gtype, X, tx0, tx1, ty0, ty1, b).items():
                enc = _encode(f.gtype, parts, tx, ty)
                if enc is None:
                    continue
                ls = tiles.setdefault((tx, ty), {})
                layer = ls.get(f.layer)
                if layer is None:
                    layer = ls[f.layer] = Layer(f.layer)
                tg = {**f.tags, **f.names} if (f.names and z >= f.name_z) else f.tags
                layer.add(f.fid, enc[0], enc[1], tg)
                for k, v in tg.items():
                    fields[f.layer][k] = "String" if isinstance(v, str) else "Number"
                zooms.setdefault(f.layer, [z, z])[1] = z
        rows, imgs = [], []
        for (tx, ty) in sorted(tiles):
            blob = encode_tile(tiles[(tx, ty)])
            h = hashlib.blake2b(blob, digest_size=16).digest()
            tid = seen.get(h)
            if tid is None:
                tid = seen[h] = len(seen) + 1
                imgs.append((tid, blob))
                n_bytes += len(blob)
            rows.append((z, tx, n - 1 - ty, tid))  # MBTiles rows are TMS (flipped y)
        n_tiles += len(rows)
        con.executemany("INSERT INTO images VALUES (?,?)", imgs)
        con.executemany("INSERT INTO map VALUES (?,?,?,?)", rows)
        del tiles
    bounds = ",".join(f"{v:.6f}" for v in (bbox if bbox else (-180, -85.0511, 180, 85.0511)))
    layers_meta = [{"id": l, "fields": fields[l], "minzoom": zooms.get(l, [0, 0])[0],
                    "maxzoom": maxzoom} for l in TILE_LAYERS]
    meta = {"name": "abtin-maps", "format": "pbf", "type": "baselayer", "version": "2",
            "minzoom": "0", "maxzoom": str(maxzoom), "bounds": bounds,
            "compression": "gzip", "json": json.dumps({"vector_layers": layers_meta}, separators=(",", ":"))}
    con.executemany("INSERT INTO metadata VALUES (?,?)", meta.items())
    con.commit()
    con.execute("VACUUM")
    con.close()
    return {"tiles": n_tiles, "unique_tiles": len(seen), "tile_bytes": n_bytes,
            "minzoom": 0, "maxzoom": maxzoom, "extent": EXTENT, "layers": list(TILE_LAYERS)}
