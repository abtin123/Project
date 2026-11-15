#!/usr/bin/env python3
"""Generate generic first-level regional build configs from Natural Earth Admin-1.

The builder uses these configs only to partition OSM data into downloadable
country regions. Routing continuity is handled separately by build_abm.py:
regional routing uses an overlap corridor and never clips an OSM way.
"""
from __future__ import annotations
import argparse, hashlib, json, os, urllib.request
from pathlib import Path

DEFAULT_URL = "https://datahub.io/core/geo-ne-admin1/_r/-/data/admin1.geojson"

def bbox_of_geometry(geometry):
    coords=[]
    def walk(v):
        if isinstance(v,(list,tuple)):
            if len(v)>=2 and all(isinstance(x,(int,float)) for x in v[:2]):
                coords.append((float(v[0]),float(v[1])))
            else:
                for x in v: walk(x)
    walk(geometry.get('coordinates', []))
    if not coords: return None
    xs=[p[0] for p in coords]; ys=[p[1] for p in coords]
    return [min(xs),min(ys),max(xs),max(ys)]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--country', required=True)
    ap.add_argument('--countries', type=Path, default=Path('countries.json'))
    ap.add_argument('--output', type=Path, default=Path('generated_regions'))
    ap.add_argument('--source-url', default=DEFAULT_URL)
    args=ap.parse_args()
    countries=json.loads(args.countries.read_text(encoding='utf-8'))
    code=args.country.upper()
    cfg=countries.get(code)
    if not cfg: raise SystemExit(f'Unknown country: {code}')
    iso3=(cfg.get('iso3') or '').upper()
    if not iso3: raise SystemExit(f'{code}: countries.json requires iso3')

    args.output.mkdir(parents=True, exist_ok=True)
    out=args.output/f'{code}.json'
    cache=Path(os.environ.get('ADMIN1_CACHE','')) if os.environ.get('ADMIN1_CACHE') else None
    if cache and cache.exists():
        raw=cache.read_bytes()
    else:
        with urllib.request.urlopen(args.source_url, timeout=120) as r:
            raw=r.read()
        if cache:
            cache.parent.mkdir(parents=True, exist_ok=True); cache.write_bytes(raw)
    data=json.loads(raw)
    regions=[]
    for feature in data.get('features',[]):
        p=feature.get('properties') or {}
        if str(p.get('adm0_a3','')).upper()!=iso3: continue
        code2=str(p.get('iso_3166_2') or '').strip()
        name=str(p.get('name') or '').strip()
        if not name: continue
        bbox=bbox_of_geometry(feature.get('geometry') or {})
        if not bbox: continue
        # Prefer ISO-3166-2. A small number of Admin-1 records have no code;
        # use a deterministic name hash so they are still downloadable and
        # keep a stable ID across workflow runs.
        rid=(code2.replace('-','_').upper() if code2 else
             'ADM1_' + hashlib.sha1(f'{code}:{name.casefold()}'.encode('utf-8')).hexdigest()[:10].upper())
        regions.append({
            'code': rid,
            'name_fa': name,
            'name_en': name,
            'bbox': [round(x,7) for x in bbox],
            'geometry': feature.get('geometry'),
            'routing_overlap_degrees': 0.25,
        })
    # Natural Earth sometimes gives two Admin-1 records the same ISO-3166-2
    # code (or a record shares a code with a hashed ID). build_abm.py rejects
    # duplicate codes, which aborts the whole country. Disambiguate every
    # colliding record with a deterministic name hash so IDs stay stable and do
    # not depend on feature order.
    counts={}
    for r in regions:
        counts[r['code']]=counts.get(r['code'],0)+1
    for r in regions:
        if counts[r['code']]>1:
            tag=hashlib.sha1(f"{code}:{r['name_en'].casefold()}".encode('utf-8')).hexdigest()[:4].upper()
            print(f"{code}: duplicate Admin-1 code {r['code']} for {r['name_en']!r}; using {r['code']}_{tag}")
            r['code']=f"{r['code']}_{tag}"
    if len({r['code'] for r in regions})!=len(regions):
        raise SystemExit(f'{code}: could not make Admin-1 region codes unique')
    regions.sort(key=lambda r:r['name_en'].casefold())
    if not regions:
        out.unlink(missing_ok=True)
        print(f'{code}: no Admin-1 regions found; builder will use whole-country ABM')
        return
    payload={
        'country_code': code,
        'country_name_fa': cfg.get('name_fa',''),
        'country_name_en': cfg.get('name_en',''),
        'source': 'Natural Earth Admin-1 via DataHub',
        'source_url': args.source_url,
        'region_level': 'admin1',
        'routing_overlap_degrees': 0.25,
        'regions': regions,
    }
    out.write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'{code}: generated {len(regions)} regions -> {out}')

if __name__=='__main__': main()
