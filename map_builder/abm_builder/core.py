"""Core types and utilities for the tile-free ABM builder."""
from __future__ import annotations

import json
import logging
import math
import re
import struct
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Iterable, Iterator

LOG = logging.getLogger("abm_builder")


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def norm_fa(value: str | None) -> str:
    if not value:
        return ""
    value = value.replace("ي", "ی").replace("ى", "ی").replace("ك", "ک")
    value = value.replace("\u200c", " ").replace("\u200f", " ")
    return re.sub(r"\s+", " ", value).strip().lower()


def name_triple(name: str | None, name_fa: str | None, name_en: str | None) -> tuple[str, str, str]:
    """The single canonical (name, name_fa, name_en) shape used by search AND
    routing, so identical names map to one row in `names`."""
    name, fa, en = name or "", name_fa or "", name_en or ""
    if name and name == fa:
        fa = ""
    if name and name == en:
        en = ""
    return name, norm_fa(fa), en


def tags_get(tags: Any, key: str, default: str = "") -> str:
    try:
        return str(tags.get(key, default) or default)
    except AttributeError:
        return default


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371008.8 * 2 * math.asin(math.sqrt(h))


def geometry_bbox(coords: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    lons = [c[0] for c in coords]; lats = [c[1] for c in coords]
    return min(lons), min(lats), max(lons), max(lats)


def records_bbox(record_lists: Iterable[Iterable[dict[str, Any]]]) -> tuple[float, float, float, float] | None:
    """Union bbox (minlon, minlat, maxlon, maxlat) across many feature-record lists.

    Returns None when there is no geometry at all (e.g. an empty test fixture),
    so callers can decide how to handle that instead of writing a bogus [0,0,0,0].
    """
    minlon = minlat = math.inf
    maxlon = maxlat = -math.inf
    found = False
    for records in record_lists:
        for rec in records:
            geom = rec.get("geometry") or []
            for pt in geom:
                if not pt or len(pt) < 2:
                    continue
                lon, lat = float(pt[0]), float(pt[1])
                found = True
                if lon < minlon: minlon = lon
                if lon > maxlon: maxlon = lon
                if lat < minlat: minlat = lat
                if lat > maxlat: maxlat = lat
    if not found:
        return None
    return (minlon, minlat, maxlon, maxlat)


def bbox_intersects(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> bool:
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


def _segment_intersects_bbox(
    a: tuple[float, float],
    b: tuple[float, float],
    bbox: tuple[float, float, float, float],
) -> bool:
    """Return True when a line segment touches or crosses an axis-aligned bbox.

    Liang-Barsky clipping is used instead of checking only vertices. This is
    important for regional OSM builds: a way can cross a province/region box
    even when both of its stored vertices are outside that box.
    """
    minx, miny, maxx, maxy = bbox
    x0, y0 = a
    x1, y1 = b
    dx, dy = x1 - x0, y1 - y0
    p = (-dx, dx, -dy, dy)
    q = (x0 - minx, maxx - x0, y0 - miny, maxy - y0)
    u0, u1 = 0.0, 1.0
    for pi, qi in zip(p, q):
        if pi == 0:
            if qi < 0:
                return False
            continue
        t = qi / pi
        if pi < 0:
            if t > u1:
                return False
            if t > u0:
                u0 = t
        else:
            if t < u0:
                return False
            if t < u1:
                u1 = t
    return u0 <= u1


def geometry_intersects_bbox(
    points: Iterable[tuple[float, float]],
    bbox: tuple[float, float, float, float],
) -> bool:
    """Return True when a polyline/polygon geometry touches the bbox.

    Unlike the old point-only test, this catches a road segment whose two
    endpoints are outside the region but whose segment passes through it.
    """
    pts = list(points)
    if not pts:
        return False
    if any(_point[0] >= bbox[0] and _point[0] <= bbox[2] and
           _point[1] >= bbox[1] and _point[1] <= bbox[3] for _point in pts):
        return True
    if len(pts) == 1:
        return False
    for a, b in zip(pts, pts[1:]):
        if _segment_intersects_bbox(a, b, bbox):
            return True
    return False


# --- Export-time geometry shrinking -----------------------------------------
# These run only when a feature's final geometry is written to a vector
# stream (never during bbox clipping/region-splitting, which still uses the
# full-precision geometry from way_geometry() so region membership stays
# exact). They are the single biggest lever on .abm size: raw OSM coordinates
# carry far more precision and far more points than a mobile map can ever
# show, and the JSON text encoding makes every extra digit and every extra
# point cost real, poorly-compressible bytes.

_METERS_PER_DEGREE = 111_320.0  # good enough for a simplification tolerance


def round_point(pt: tuple[float, float], precision: int = 5) -> tuple[float, float]:
    """Round a (lon, lat) pair to ``precision`` decimal digits (6 == ~11cm),
    which also collapses the long noisy float reprs (e.g. 35.68999999999999)
    that json.dumps would otherwise emit for perfectly ordinary OSM coords."""
    return (round(float(pt[0]), precision), round(float(pt[1]), precision))


def simplify_rdp(points: list[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker line simplification. ``tolerance`` is in the same
    units as the points (degrees here). Iterative to avoid recursion limits
    on very long ways (rivers, coastlines, long highways)."""
    if tolerance <= 0 or len(points) < 3:
        return points

    def seg_dist(pt, a, b) -> float:
        (x, y), (x1, y1), (x2, y2) = pt, a, b
        dx, dy = x2 - x1, y2 - y1
        if dx == 0 and dy == 0:
            return math.hypot(x - x1, y - y1)
        t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)
        t = max(0.0, min(1.0, t))
        return math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))

    keep = bytearray(len(points))
    keep[0] = keep[-1] = 1
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi - lo < 2:
            continue
        a, b = points[lo], points[hi]
        idx, dmax = -1, tolerance
        for i in range(lo + 1, hi):
            d = seg_dist(points[i], a, b)
            if d > dmax:
                idx, dmax = i, d
        if idx != -1:
            keep[idx] = 1
            stack.append((lo, idx))
            stack.append((idx, hi))
    return [p for p, k in zip(points, keep) if k]


def prepare_geometry(
    points: list[tuple[float, float]],
    *,
    tolerance_m: float = 0.0,
    precision: int = 5,
) -> list[tuple[float, float]]:
    """Round precision and (optionally) simplify a geometry for export. Safe
    to call on already-clipped/validated geometry; never used for bbox math."""
    if not points:
        return []
    pts = [round_point(p, precision) for p in points]
    if tolerance_m > 0 and len(pts) > 2:
        closed = pts[0] == pts[-1]
        pts = simplify_rdp(pts, tolerance_m / _METERS_PER_DEGREE)
        if closed and len(pts) > 1 and pts[0] != pts[-1]:
            pts.append(pts[0])
    # Drop consecutive duplicate points left over from rounding/simplifying.
    out = [pts[0]]
    for p in pts[1:]:
        if p != out[-1]:
            out.append(p)
    return out


def write_records(path: Path, records: Iterable[dict[str, Any]]) -> int:
    """Write a versioned length-prefixed ABM vector stream."""
    count = 0
    with path.open("wb") as f:
        f.write(b"ABMV1\n")
        for record in records:
            payload = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode()
            f.write(struct.pack("!I", len(payload)))
            f.write(payload)
            count += 1
    return count


def feature_bbox(record: dict[str, Any]) -> tuple[float, float, float, float] | None:
    geom = record.get("geometry") or []
    points = []
    for pt in geom:
        try:
            if len(pt) >= 2:
                points.append((float(pt[0]), float(pt[1])))
        except (TypeError, ValueError):
            continue
    return geometry_bbox(points) if points else None


def write_spatial_chunks(
    directory: Path,
    layer: str,
    records: Iterable[dict[str, Any]],
    chunk_size: int = 768,
) -> dict[str, Any]:
    """Write tightly localized spatial chunks and a compact layer index.

    Chunks are first grouped by a fixed geographic cell and only then split
    when a cell contains more than ``chunk_size`` features.  The previous
    implementation sorted globally and then batched every N features; that
    could put features from distant cells in the same chunk, causing a single
    viewport to decompress a large fraction of a country.  Keeping chunk
    bboxes tight is the key to fast mobile viewport reads.
    """
    cell_buckets: dict[tuple[int, int], list[tuple[tuple[float, float, float, float], dict[str, Any]]]] = {}

    def cell_key(b: tuple[float, float, float, float]) -> tuple[int, int]:
        cx = (b[0] + b[2]) * 0.5
        cy = (b[1] + b[3]) * 0.5
        gx = max(0, min(255, int(math.floor((cx + 180.0) / 360.0 * 256.0))))
        gy = max(0, min(127, int(math.floor((cy + 90.0) / 180.0 * 128.0))))
        return gx, gy

    for rec in records:
        bbox = feature_bbox(rec)
        if bbox is not None:
            cell_buckets.setdefault(cell_key(bbox), []).append((bbox, rec))

    out_dir = directory / layer
    out_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[dict[str, Any]] = []
    chunk_index = 0

    for cell in sorted(cell_buckets):
        items = cell_buckets[cell]
        items.sort(key=lambda item: (
            item[0][1], item[0][0], item[0][3], item[0][2]
        ))
        for start in range(0, len(items), max(1, chunk_size)):
            batch = items[start:start + max(1, chunk_size)]
            name = f"{chunk_index:06d}.bin"
            chunk_index += 1
            path = out_dir / name
            write_records(path, (rec for _, rec in batch))
            bboxes = [b for b, _ in batch]
            bbox = (
                min(b[0] for b in bboxes), min(b[1] for b in bboxes),
                max(b[2] for b in bboxes), max(b[3] for b in bboxes),
            )
            chunks.append({
                "path": f"vector/{layer}/{name}",
                "bbox": list(bbox),
                "count": len(batch),
                "cell": [cell[0], cell[1]],
            })

    if not chunks:
        name = "000000.bin"
        path = out_dir / name
        write_records(path, [])
        chunks.append({
            "path": f"vector/{layer}/{name}",
            "bbox": [180.0, 90.0, -180.0, -90.0],
            "count": 0,
            "cell": [-1, -1],
        })

    return {
        "version": 2,
        "layer": layer,
        "count": sum(c["count"] for c in chunks),
        "chunk_size": max(1, chunk_size),
        "chunks": chunks,
    }


def read_records(path: Path) -> Iterator[dict[str, Any]]:
    with path.open("rb") as f:
        if f.read(6) != b"ABMV1\n":
            raise ValueError(f"Invalid ABM vector stream header: {path}")
        while True:
            raw = f.read(4)
            if not raw: break
            if len(raw) != 4: raise ValueError(f"Truncated record length in {path}")
            size = struct.unpack("!I", raw)[0]
            payload = f.read(size)
            if len(payload) != size: raise ValueError(f"Truncated record in {path}")
            yield json.loads(payload)


def way_geometry(way: Any) -> list[tuple[float, float]]:
    nodes = getattr(way, "nodes", way.get("geometry", []) if isinstance(way, dict) else [])
    out = []
    for n in nodes:
        if isinstance(n, dict):
            if n.get("lon") is not None and n.get("lat") is not None: out.append((float(n["lon"]), float(n["lat"])))
        elif getattr(n, "lon", None) is not None and getattr(n, "lat", None) is not None: out.append((float(n.lon), float(n.lat)))
        elif isinstance(n, (list, tuple)) and len(n) >= 2: out.append((float(n[0]), float(n[1])))
    return out


def tags_dict(obj: Any) -> dict[str, str]:
    tags = getattr(obj, "tags", obj.get("tags", {}) if isinstance(obj, dict) else {})
    if isinstance(tags, dict):
        return {str(k): str(v) for k, v in tags.items()}
    # osmium's TagList (real .way()/.relation() objects during apply_file)
    # is a mapping-like C++ wrapper with no .items() method - only
    # iteration/keys()/__getitem__. dict(tags) is the same conversion
    # extractors/loader.py already uses successfully for this exact type.
    try:
        return {str(k): str(v) for k, v in dict(tags).items()}
    except (TypeError, ValueError):
        return {}


def entity_id(obj: Any) -> int:
    return int(getattr(obj, "id", obj.get("id", 0) if isinstance(obj, dict) else 0))


@dataclass
class Feature:
    id: int
    geometry: list[tuple[float, float]]
    tags: dict[str, str]

    def record(self) -> dict[str, Any]:
        return {"id": self.id, "geometry": self.geometry, "tags": self.tags}
