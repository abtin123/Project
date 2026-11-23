#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, shutil, tempfile, urllib.request, unicodedata, re
from pathlib import Path
from abm_builder.core import setup_logging, records_bbox, LOG
from abm_builder.tiles import build_mbtiles
from extractors.loader import load, extract_all, clip_dataset
from extractors.osm import ROAD_CLASSES
from search.create_search_db import create_search_db
from search.map_db import finalize_map_db
from routing.graph_builder import build_graph, build_graph_from_pbf, merge_graph
from release_packaging.create_abm import create_abm, verify_abm

BBOX_LAYERS = ('roads.bin', 'buildings.bin', 'landuse.bin', 'water.bin', 'boundaries.bin', 'places.bin')


def _load_region_geometries(config_path: Path, cfg: dict, boundaries_path: Path | None = None) -> dict[str, object]:
    """Load real Admin-1 polygons keyed by region code.

    The GeoJSON can be supplied explicitly with --boundaries or via the config's
    ``boundaries_file``. A FeatureCollection may identify regions with either
    ISO-3166-2 (``iso_3166_2``) or a configured ``region_code_property``.
    """
    source = boundaries_path or (Path(cfg['boundaries_file']) if cfg.get('boundaries_file') else None)
    # Generated/curated configs may embed their exact GeoJSON geometry. This is
    # preferred for reproducible builds because no external boundary download
    # is needed.
    inline = {}
    try:
        from shapely.geometry import shape
        from shapely.ops import unary_union
    except ImportError as e:
        raise SystemExit('Polygon regional builds require shapely>=2; install requirements.txt') from e
    for r in cfg.get('regions', []):
        if r.get('geometry'):
            code = str(r['code']).strip().replace('-', '_').upper()
            g = shape(r['geometry'])
            if not g.is_valid:
                g = g.buffer(0)
            inline[code] = g if code not in inline else unary_union([inline[code], g])
    if inline and len(inline) == len(cfg.get('regions', [])):
        return inline
    if source is None:
        raise SystemExit(
            f'{config_path}: regional builds now require real admin polygons. '
            'Pass --boundaries <admin1.geojson>, set boundaries_file in the config, '
            'or generate the config with embedded geometry.'
        )
    if not source.is_absolute():
        source = config_path.parent / source
    if not source.exists():
        raise SystemExit(f'{config_path}: boundaries file not found: {source}')
    try:
        from shapely.geometry import shape
        from shapely.ops import unary_union
    except ImportError as e:
        raise SystemExit('Polygon regional builds require shapely>=2; install requirements.txt') from e
    data = json.loads(source.read_text(encoding='utf-8'))
    if data.get('type') != 'FeatureCollection':
        raise SystemExit(f'{source}: expected a GeoJSON FeatureCollection')
    prop = str(cfg.get('region_code_property', 'iso_3166_2'))
    by_code = {}
    for feature in data.get('features', []):
        props = feature.get('properties') or {}
        raw = props.get(prop) or props.get('iso_3166_2')
        if raw is None:
            continue
        code = str(raw).strip().replace('-', '_').upper()
        geom = feature.get('geometry')
        if not geom:
            continue
        try:
            g = shape(geom)
            if not g.is_valid:
                g = g.buffer(0)
            if not g.is_empty:
                by_code[code] = g if code not in by_code else unary_union([by_code[code], g])
        except Exception as e:
            raise SystemExit(f'{source}: invalid geometry for {code}: {e}') from e
    return by_code


def _max_corridor_km(overlap_degrees: float) -> float:
    # Conservative diagonal bound for a degree-expanded routing corridor.
    return round(max(0.0, overlap_degrees) * 111.32 * (2.0 ** 0.5), 3)



def _build_one(
    dataset,
    country: str,
    output: Path,
    source: Path,
    region: dict | None = None,
    routing_bbox: tuple[float, float, float, float] | None = None,
    routing_dataset=None,
) -> Path:
    """Run the full extract -> search -> routing -> package pipeline once,
    against whichever dataset is handed in (the whole country, or one
    feature-selected for a region). Regional selection never cuts an OSM way.
    This is the single code path used
    both for ordinary countries and for each part of a geographically split
    large country, so region builds get exactly the same validation
    (bbox, no-tile-files check, required-file check) as a normal build.
    """
    build_id = str(region.get('code') if region else country).strip().upper().replace('-', '_')
    # Every build gets an isolated workspace, even when CI runs several provinces in parallel.
    work_root = Path(os.environ.get('ABM_WORK_ROOT', tempfile.gettempdir()))
    work = Path(tempfile.mkdtemp(prefix=f'abm-build-{build_id}-', dir=str(work_root)))
    try:
        LOG.info('[1/5] Extracting features for %s', region['code'] if region else country)
        all_data = extract_all(dataset)
        bbox = records_bbox(all_data[name] for name in BBOX_LAYERS)
        if region is not None:
            # Published bbox of a region archive is its configured bbox.
            bbox = tuple(region['bbox'])

        db_stem = str(region.get('code') if region else country).strip().upper()
        db_stem = re.sub(r'[^A-Z0-9_-]+', '_', db_stem)
        sqlite_name = f'{db_stem}.sqlite'
        mbtiles_name = f'{db_stem}.mbtiles'
        LOG.info('[2/5] Building vector tiles (%s)', mbtiles_name)
        tile_stats = build_mbtiles(work / mbtiles_name, all_data, bbox)
        LOG.info('  %d tiles (%d unique) %.1f MiB', tile_stats['tiles'], tile_stats['unique_tiles'],
                 tile_stats['tile_bytes'] / 2**20)

        LOG.info('[3/5] Building search/POI database (%s)', sqlite_name)
        # Render-only roads (service/footway/...) stay out of the search index.
        search_roads = [r for r in all_data['roads.bin'] if r['tags'].get('highway') in ROAD_CLASSES]
        create_search_db(work / sqlite_name, all_data['poi'], all_data['places.bin'], search_roads)

        LOG.info('[4/5] Building routing graph and finalizing %s', sqlite_name)
        graph_db = work / 'graph.sqlite'  # build-only staging, never packaged
        if source.suffix.lower() not in {'.jsonl', '.json'}:
            # Routing uses the region's continuity bbox, not the visual
            # footprint. The graph builder keeps complete OSM ways that touch
            # this bbox; it never cuts a way at the region boundary.
            graph_stats = build_graph_from_pbf(
                source,
                graph_db,
                bbox=routing_bbox if routing_bbox is not None else bbox,
                region_geometry=(region.get('_routing_geometry') if region else None),
            )
        else:
            route_data = routing_dataset if routing_dataset is not None else dataset
            graph_stats = build_graph(route_data.ways, route_data.relations, graph_db)
        merge_graph(work / sqlite_name, graph_db)
        graph_db.unlink(missing_ok=True)
        finalize_map_db(work / sqlite_name)

        LOG.info('[5/5] Packaging and validating ABM: %s', output)
        stats = {k: len(v) for k, v in all_data.items() if isinstance(v, list)}
        stats['routing'] = graph_stats
        stats['tiles'] = tile_stats
        create_abm(work, output, country, source, stats, bbox, region)
        result = verify_abm(output)
        LOG.info('ABM ready: %s (%d files)', output, result['files'])
        return output
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _norm_region_name(value: str) -> str:
    """Normalize admin names for matching a legacy config to Admin-1 GeoJSON."""
    text = unicodedata.normalize("NFKC", str(value or "")).casefold()
    text = re.sub(r"[\u200c\u200f\u200e]", "", text)
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return " ".join(text.split())


def _auto_attach_admin1_boundaries(config_path: Path, cfg: dict) -> dict:
    """Upgrade legacy bbox-only configs by attaching real Admin-1 geometry.

    This is intentionally a compatibility path for the existing CI workflow,
    which historically passed only sample/regions/<CC>.json. It downloads the
    Admin-1 FeatureCollection once, matches regions by ISO-3166-2 first and by
    normalized English/Farsi name second, and keeps the existing region IDs.
    """
    if all(r.get("geometry") for r in cfg.get("regions", [])):
        return cfg
    source = cfg.get("boundaries_file") or os.environ.get("ADMIN1_BOUNDARIES_URL")
    if source and not str(source).startswith(("http://", "https://")):
        path = config_path.parent / str(source)
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
        else:
            raise SystemExit(f"{config_path}: boundaries file not found: {path}")
    else:
        url = str(source or "https://datahub.io/core/geo-ne-admin1/_r/-/data/admin1.geojson")
        cache_raw = os.environ.get("ADMIN1_CACHE")
        cache = Path(cache_raw) if cache_raw else None
        try:
            if cache and cache.exists():
                data = json.loads(cache.read_text(encoding="utf-8"))
            else:
                with urllib.request.urlopen(url, timeout=120) as response:
                    raw = response.read()
                data = json.loads(raw)
                if cache:
                    cache.parent.mkdir(parents=True, exist_ok=True)
                    cache.write_bytes(raw)
        except Exception as exc:
            raise SystemExit(
                f"{config_path}: cannot load Admin-1 boundaries automatically: {exc}. "
                "Provide --boundaries <admin1.geojson> or populate ADMIN1_CACHE."
            ) from exc

    if data.get("type") != "FeatureCollection":
        raise SystemExit(f"{config_path}: Admin-1 boundary source must be a GeoJSON FeatureCollection")

    features = data.get("features", [])
    by_iso = {}
    by_name = {}
    feature_items = []
    def geom_bbox(geom):
        coords = []
        def walk(v):
            if isinstance(v, (list, tuple)):
                if len(v) >= 2 and all(isinstance(x, (int, float)) for x in v[:2]):
                    coords.append((float(v[0]), float(v[1])))
                else:
                    for item in v:
                        walk(item)
        walk((geom or {}).get("coordinates", []))
        if not coords:
            return None
        xs = [x for x, _ in coords]
        ys = [y for _, y in coords]
        return min(xs), min(ys), max(xs), max(ys)

    for feature in features:
        props = feature.get("properties") or {}
        geom = feature.get("geometry")
        if not geom:
            continue
        iso2 = str(props.get("iso_3166_2") or "").strip().replace("-", "_").upper()
        if iso2:
            by_iso[iso2] = geom
        for key in ("name", "name_en", "name_fa", "name_alt"):
            value = props.get(key)
            if value:
                by_name[_norm_region_name(value)] = geom
        feature_items.append((geom, geom_bbox(geom)))

    missing = []
    for region in cfg.get("regions", []):
        if region.get("geometry"):
            continue
        code = str(region.get("code", "")).strip().replace("-", "_").upper()
        geom = by_iso.get(code)
        if geom is None:
            for key in ("name_en", "name_fa"):
                geom = by_name.get(_norm_region_name(region.get(key, "")))
                if geom is not None:
                    break
        if geom is None:
            # Last-resort compatibility matching for historical configs whose
            # names/codes differ from the boundary provider. Pick the Admin-1
            # polygon with the largest bbox intersection over the configured
            # bbox. This is only used to identify the polygon; clipping itself
            # is still performed against the real polygon.
            try:
                a = tuple(float(x) for x in region["bbox"])
                best = (0.0, None)
                for candidate, cb in feature_items:
                    if cb is None:
                        continue
                    ix0, iy0 = max(a[0], cb[0]), max(a[1], cb[1])
                    ix1, iy1 = min(a[2], cb[2]), min(a[3], cb[3])
                    iw, ih = max(0.0, ix1 - ix0), max(0.0, iy1 - iy0)
                    inter = iw * ih
                    aw = max(1e-12, a[2] - a[0])
                    ah = max(1e-12, a[3] - a[1])
                    score = inter / (aw * ah)
                    if score > best[0]:
                        best = (score, candidate)
                if best[0] >= 0.50:
                    geom = best[1]
            except Exception:
                geom = None
        if geom is None:
            missing.append(region.get("code", "<unknown>"))
        else:
            region["geometry"] = geom

    if missing:
        raise SystemExit(
            f"{config_path}: no Admin-1 polygon matched region(s): {', '.join(map(str, missing))}. "
            "Provide a curated GeoJSON with matching ISO-3166-2 codes or names."
        )
    return cfg


def _load_regions_config(path: Path) -> dict:
    cfg = json.loads(path.read_text(encoding='utf-8'))
    if 'regions' not in cfg or not cfg['regions']:
        raise SystemExit(f'--regions config {path} has no "regions" list')
    seen_codes: set[str] = set()
    for r in cfg['regions']:
        for key in ('code', 'name_fa', 'name_en', 'bbox'):
            if key not in r:
                raise SystemExit(f'--regions config {path}: region entry missing "{key}": {r}')
        code = str(r['code']).strip()
        if not code:
            raise SystemExit(f'--regions config {path}: region code cannot be empty')
        if code in seen_codes:
            raise SystemExit(f'--regions config {path}: duplicate region code {code}')
        seen_codes.add(code)
        if len(r['bbox']) != 4:
            raise SystemExit(f'--regions config {path}: region {r["code"]} bbox must be [minlon,minlat,maxlon,maxlat]')
        try:
            minlon, minlat, maxlon, maxlat = map(float, r['bbox'])
        except (TypeError, ValueError):
            raise SystemExit(f'--regions config {path}: region {r["code"]} bbox must contain numbers')
        if not (-180 <= minlon <= maxlon <= 180 and -90 <= minlat <= maxlat <= 90):
            raise SystemExit(f'--regions config {path}: invalid bbox for {r["code"]}: {r["bbox"]}')
        overlap = r.get('routing_overlap_degrees', cfg.get('routing_overlap_degrees', 0.25))
        try:
            overlap = float(overlap or 0.0)
        except (TypeError, ValueError):
            raise SystemExit(f'--regions config {path}: region {r["code"]} routing_overlap_degrees must be numeric')
        if overlap < 0:
            raise SystemExit(f'--regions config {path}: region {r["code"]} routing_overlap_degrees cannot be negative')
    return cfg


def main():
    ap = argparse.ArgumentParser(description='Build an Abtin Maps ABM country archive (MBTiles + SQLite)')
    ap.add_argument('input', type=Path, help='OSM .pbf or test .jsonl input')
    ap.add_argument('-o', '--output', type=Path, required=True,
                     help='Output .abm file (whole-country build), or output '
                          'directory when --regions is given')
    ap.add_argument('--country', required=True, help='ISO-3166 alpha-2 country code')
    ap.add_argument('--regions', type=Path, default=None,
                     help='Optional JSON config splitting a large country into real '
                          'geographic regions selected by real Admin-1 polygons, instead of one whole-country '
                          '.abm. Crossing ways are retained whole; routing can use an optional overlap corridor. See sample/regions/US.json for the format. This is '
                          'independent from release_packaging/split_abm.py, which only exists to '
                          'chop an already-built .abm into byte-sized parts for hosting '
                          'limits and knows nothing about geography.')
    ap.add_argument('--boundaries', type=Path, default=None, help='GeoJSON FeatureCollection containing real Admin-1 polygons; if omitted, the builder auto-loads Admin-1 data for legacy bbox-only configs')
    ap.add_argument('--only-regions', default='', help='Comma-separated region codes to build; all configured regions are built when omitted')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()
    setup_logging(args.verbose)

    if args.regions is None:
        LOG.info('Loading OSM input: %s', args.input)
        data = load(args.input)

        if args.output.suffix.lower() != '.abm':
            raise SystemExit('Output must end with .abm (use --regions for a multi-file, per-region build)')
        try:
            _build_one(data, args.country, args.output, args.input)
        except Exception:
            LOG.exception('ABM build failed')
            raise
        return

    cfg = _load_regions_config(args.regions)
    if args.boundaries is None and not cfg.get("boundaries_file") and not all(r.get("geometry") for r in cfg.get("regions", [])):
        cfg = _auto_attach_admin1_boundaries(args.regions, cfg)
    region_geometries = _load_region_geometries(args.regions, cfg, args.boundaries)
    args.output.mkdir(parents=True, exist_ok=True)
    requested_regions = {x.strip().upper() for x in args.only_regions.split(',') if x.strip()}
    unknown_requested = requested_regions - {str(r['code']).strip().upper() for r in cfg['regions']}
    if unknown_requested:
        raise SystemExit(f'--only-regions contains unknown code(s): {sorted(unknown_requested)}')
    built = []
    # For PBF input, load each region directly from the stream.  Never
    # materialize a whole-country PBF before clipping: large extracts can
    # otherwise exhaust the GitHub runner's RAM.
    is_pbf = args.input.suffix.lower() not in {'.jsonl', '.json'}
    data = None if is_pbf else load(args.input)
    try:
        for region_def in cfg['regions']:
            code = region_def['code']
            if requested_regions and str(code).strip().upper() not in requested_regions:
                LOG.info('Skipping region %s (--only-regions)', code)
                continue
            LOG.info('--- Region %s (%s) ---', code, region_def['name_en'])
            normalized_code = code.replace('-', '_').upper()
            region_geometry = region_geometries.get(normalized_code)
            if region_geometry is None:
                raise SystemExit(f'{args.regions}: no polygon found for region {code}')
            clipped = load(args.input, region_geometry=region_geometry) if is_pbf else clip_dataset(data, region_geometry=region_geometry)
            if not clipped.ways and not clipped.nodes:
                LOG.warning('Region %s has no data in %s - skipping (check bbox / input coverage)', code, args.input)
                continue
            out_path = args.output / f'{code}.abm'
            overlap = float(region_def.get('routing_overlap_degrees', cfg.get('routing_overlap_degrees', 0.25)) or 0.0)
            if overlap < 0:
                raise SystemExit(f'{args.regions}: region {code} routing_overlap_degrees cannot be negative')
            # The routing corridor follows the real region polygon, not its bbox.
            # A degree buffer preserves the existing configurable overlap contract.
            # The real Admin-1 polygon is authoritative.  The published
            # region bbox must therefore be derived from that polygon, rather
            # than copied from a legacy/configuration bbox that may be larger
            # than the actual administrative region.  The bbox remains useful
            # as an auxiliary/indexing envelope; it is not used for clipping.
            pb = region_geometry.bounds
            bbox = (
                max(-180.0, pb[0]), max(-90.0, pb[1]),
                min(180.0, pb[2]), min(90.0, pb[3]),
            )
            routing_geometry = region_geometry.buffer(overlap)
            rb = routing_geometry.bounds
            routing_bbox = (
                max(-180.0, rb[0]), max(-90.0, rb[1]),
                min(180.0, rb[2]), min(90.0, rb[3]),
            )
            routing_dataset = (
                None if is_pbf else clip_dataset(data, region_geometry=routing_geometry)
            )
            region_meta = {
                'code': code,
                'name_fa': region_def['name_fa'],
                'name_en': region_def['name_en'],
                'bbox': list(bbox),
                'routing_bbox': list(routing_bbox),
                'routing_overlap_degrees': overlap,
                'routing_geometry_policy': 'full_way_no_clip',
                'region_selection_policy': 'admin1_polygon_intersection',
                'max_offroute_corridor_km': _max_corridor_km(overlap),
                '_routing_geometry': routing_geometry,
                'routing_node_identity': 'osm_node_id',
                'country_code': args.country.upper(),
                'country_name_fa': cfg.get('country_name_fa', ''),
                'country_name_en': cfg.get('country_name_en', ''),
            }
            _build_one(
                clipped,
                args.country,
                out_path,
                args.input,
                region=region_meta,
                routing_bbox=routing_bbox,
                routing_dataset=routing_dataset,
            )
            built.append(code)
        LOG.info('Built %d region archives in %s: %s', len(built), args.output, ', '.join(built))
        if not built:
            raise SystemExit(f'No region in {args.regions} matched any data in {args.input}')
    except Exception:
        LOG.exception('Regional ABM build failed')
        raise


if __name__ == '__main__':
    main()
