#!/usr/bin/env python3
"""Fingerprint OSM source data independently for each configured region.

The fingerprint is based on each region's published/routing bbox.  The PBF is
scanned exactly ONCE and objects are assigned to every region whose bbox they
intersect.  The previous implementation reopened/scanned the complete PBF
once per region, which made a country such as Iran (with many admin-1 regions)
appear to hang for a very long time.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def region_fingerprints(pbf: Path, config: Path) -> dict[str, dict]:
    try:
        import osmium
    except ImportError as exc:
        raise SystemExit(
            "pyosmium is required for regional source fingerprints"
        ) from exc

    cfg = json.loads(config.read_text(encoding="utf-8"))
    regions = cfg.get("regions") or []

    # Normalize once.  Keep the configured order so the JSON is deterministic.
    region_defs = []
    for r in regions:
        code = str(r["code"]).strip().upper()
        bbox = tuple(float(x) for x in r["bbox"])
        region_defs.append((code, bbox))

    hashes = {code: hashlib.sha256() for code, _ in region_defs}
    objects = {code: 0 for code, _ in region_defs}
    way_ids = {code: set() for code, _ in region_defs}

    def in_bbox(lon: float, lat: float, bbox) -> bool:
        minlon, minlat, maxlon, maxlat = bbox
        return minlon <= lon <= maxlon and minlat <= lat <= maxlat

    def intersects(bbox, obox) -> bool:
        minlon, minlat, maxlon, maxlat = bbox
        bx0, by0, bx1, by1 = obox
        return (
            bx1 >= minlon
            and bx0 <= maxlon
            and by1 >= minlat
            and by0 <= maxlat
        )

    def snapshot(kind: str, obj) -> list:
        # pyosmium objects are only valid inside the handler callback, so
        # copy everything needed for hashing while the object is alive.
        tags = sorted((str(k), str(v)) for k, v in obj.tags)
        return [kind, str(obj.id), str(getattr(obj, "version", "")), tags]

    def add(code: str, kind: str, obj) -> None:
        add_payload(code, snapshot(kind, obj))

    def add_payload(code: str, payload: list) -> None:
        hashes[code].update(
            json.dumps(
                payload, ensure_ascii=False, separators=(",", ":")
            ).encode()
        )
        hashes[code].update(b"\n")
        objects[code] += 1

    # Relations can appear before their member ways in a PBF.  Keep their
    # compact payloads until all ways have been seen, then associate them with
    # regions from the member-way IDs.
    relations: list[tuple[list, set[int]]] = []

    class Handler(osmium.SimpleHandler):
        def node(self, n):
            if not n.location.valid():
                return
            lon, lat = float(n.location.lon), float(n.location.lat)
            for code, bbox in region_defs:
                if in_bbox(lon, lat, bbox):
                    add(code, "node", n)

        def way(self, w):
            coords = []
            for n in w.nodes:
                if n.location.valid():
                    coords.append(
                        (float(n.location.lon), float(n.location.lat))
                    )
            if not coords:
                return

            bx0 = min(x for x, _ in coords)
            by0 = min(y for _, y in coords)
            bx1 = max(x for x, _ in coords)
            by1 = max(y for _, y in coords)
            obox = (bx0, by0, bx1, by1)

            wid = int(w.id)
            for code, bbox in region_defs:
                if intersects(bbox, obox):
                    way_ids[code].add(wid)
                    add(code, "way", w)

        def relation(self, rel):
            members = {
                int(m.ref)
                for m in rel.members
                if str(m.type) == "w"
            }
            if members:
                relations.append((snapshot("relation", rel), members))

    print(
        f"Fingerprinting {pbf} in one PBF pass for "
        f"{len(region_defs)} configured regions...",
        flush=True,
    )
    hnd = Handler()
    hnd.apply_file(str(pbf), locations=True, idx="flex_mem")

    # Preserve the intended relation contribution without requiring relation
    # ordering in the source PBF.
    for payload, members in relations:
        for code, _bbox in region_defs:
            if members & way_ids[code]:
                add_payload(code, payload)

    return {
        code: {
            "sha256": hashes[code].hexdigest(),
            "objects": objects[code],
            "bbox": list(bbox),
        }
        for code, bbox in region_defs
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pbf", type=Path)
    ap.add_argument("--regions-config", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()

    result = region_fingerprints(args.pbf, args.regions_config)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    for code, item in result.items():
        print(
            f'{code} {item["sha256"]} objects={item["objects"]}',
            flush=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
