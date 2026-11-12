#!/usr/bin/env python3
"""Build / repair the release-level manifest.json consumed by the Abtin Maps app.

Sources of truth, in increasing priority:
  1. previous published manifest.json           (carried over, normalised)
  2. .abm files found in the release            (--asset-dir + --release-assets-json;
                                                 bbox/region are read from metadata.json
                                                 inside each archive)
  3. freshly built output                       (dist dir and/or --current-manifest
                                                 fragments produced by a build job)

Every entry is written in the canonical shape:
  code, name_fa, name_en, country_code, country_name_fa, country_name_en,
  region_name_fa, region_name_en, bbox, sha256, files[], total_size, source{}, [patch{}]

Entries that cannot be made valid (no bbox, files missing from the release)
are dropped with a warning instead of shipping a malformed catalog.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path

ORDER = ['code', 'name_fa', 'name_en', 'country_code', 'country_name_fa', 'country_name_en',
         'region_name_fa', 'region_name_en', 'bbox', 'sha256', 'files', 'total_size', 'source', 'patch']
LICENSE = {
    'attribution': 'Map data from OpenStreetMap, ODbL 1.0',
    'license_url': 'https://opendatacommons.org/licenses/odbl/1.0/',
    'copyright_url': 'https://www.openstreetmap.org/copyright',
}


def warn(msg: str) -> None:
    print(f'::warning::{msg}', file=sys.stderr)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def load_json(path: Path | None):
    if not path or not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc:
        warn(f'cannot read {path}: {exc}')
        return {}


def read_abm_metadata(abm: Path) -> dict:
    with zipfile.ZipFile(abm) as z:
        return json.loads(z.read('metadata.json'))


def valid_bbox(b) -> bool:
    try:
        x0, y0, x1, y1 = (float(v) for v in b)
    except (TypeError, ValueError):
        return False
    return len(b) == 4 and -180 <= x0 <= x1 <= 180 and -90 <= y0 <= y1 <= 90


def valid_files(files) -> bool:
    return (isinstance(files, list) and bool(files) and all(
        isinstance(f, dict) and f.get('name') and isinstance(f.get('size'), int) and f.get('sha256')
        for f in files))


def is_complete(entry: dict) -> bool:
    return valid_bbox(entry.get('bbox')) and valid_files(entry.get('files'))


def good_name(value, code: str) -> bool:
    return isinstance(value, str) and value.strip() != '' and value.strip() != code


def asset_map(path: Path | None) -> dict[str, int] | None:
    """name -> size from `gh release view --json assets` (None when not given)."""
    if not path:
        return None
    data = load_json(path)
    items = data.get('assets', []) if isinstance(data, dict) else data
    return {a['name']: int(a.get('size', -1)) for a in items if isinstance(a, dict) and 'name' in a}


def patch_names(entry: dict) -> list[str]:
    p = entry.get('patch') or {}
    return [n for n in (p.get('manifest_file'), p.get('bin_file')) if n]


def canonical(entry: dict, names: dict) -> dict:
    """Fill display names / source from countries.json and fix key order."""
    code = str(entry['code'])
    disp = names.get(code) or names.get(str(entry.get('country_code', ''))) or {}
    e = dict(entry)
    e['code'] = code
    e['name_fa'] = e['name_fa'] if good_name(e.get('name_fa'), code) else disp.get('name_fa', code)
    e['name_en'] = e['name_en'] if good_name(e.get('name_en'), code) else disp.get('name_en', code)
    e.setdefault('country_code', code)
    for k, src in (('country_name_fa', 'name_fa'), ('country_name_en', 'name_en'),
                   ('region_name_fa', 'name_fa'), ('region_name_en', 'name_en')):
        if not good_name(e.get(k), code):
            e[k] = e[src]
    files = e.get('files')
    if valid_files(files):
        e.setdefault('total_size', sum(f['size'] for f in files))
        if not e.get('sha256') and len(files) == 1:
            e['sha256'] = files[0]['sha256']
    src = dict(e.get('source') or {})
    if not src.get('url'):
        parent = names.get(str(e.get('country_code', ''))) or disp
        src['url'] = parent.get('pbf_url', '')
    src.setdefault('provider', 'Geofabrik / OpenStreetMap')
    for k, v in LICENSE.items():
        src.setdefault(k, v)
    # Keep source freshness metadata when the weekly workflow provides it.
    # The app ignores these fields, but the builder uses pbf_sha256 to avoid
    # rebuilding an unchanged OSM extract.
    source_keys = (
        'provider', 'url', 'attribution', 'license_url', 'copyright_url',
        'pbf_sha256', 'pbf_size', 'pbf_last_modified', 'pbf_etag',
        'source_checked_at',
    )
    e['source'] = {k: src[k] for k in source_keys if k in src}
    if not e.get('patch'):
        e.pop('patch', None)
    ordered = {k: e[k] for k in ORDER if k in e}
    ordered.update({k: v for k, v in e.items() if k not in ordered})
    return ordered


def build_entry(code: str, abm: Path, names: dict, parts_dir: Path | None = None,
                patch_dir: Path | None = None, source_meta: dict | None = None) -> tuple[dict | None, list[Path]]:
    """Entry (+ the local files it references) for one freshly built / downloaded .abm."""
    meta = read_abm_metadata(abm)
    bbox = meta.get('bbox')
    if not valid_bbox(bbox):
        return None, []
    region = meta.get('region')
    sources: list[Path]
    if parts_dir and (parts_dir / 'manifest.json').exists():
        pd = json.loads((parts_dir / 'manifest.json').read_text(encoding='utf-8'))
        files = [{'name': p['name'], 'size': p['size'], 'sha256': p['sha256']} for p in pd['parts']]
        total, whole = pd['size'], pd['sha256']
        sources = [parts_dir / p['name'] for p in pd['parts']]
    else:
        whole = sha256_file(abm)
        files = [{'name': abm.name, 'size': abm.stat().st_size, 'sha256': whole}]
        total, sources = abm.stat().st_size, [abm]

    if region:
        entry = {'code': code, 'name_fa': region['name_fa'], 'name_en': region['name_en'],
                 'country_code': region['country_code'],
                 'country_name_fa': region.get('country_name_fa', ''),
                 'country_name_en': region.get('country_name_en', ''),
                 'region_name_fa': region['name_fa'], 'region_name_en': region['name_en']}
    else:
        entry = {'code': code}
    entry.update({'bbox': list(bbox), 'sha256': whole, 'files': files, 'total_size': total})

    if source_meta:
        entry.setdefault('source', {})
        entry['source'].update(source_meta)
        entry = canonical(entry, names)

    if patch_dir and (patch_dir / 'patch-descriptor.json').exists():
        pd = json.loads((patch_dir / 'patch-descriptor.json').read_text(encoding='utf-8'))
        entry['patch'] = {k: pd[k] for k in ('base_sha256', 'manifest_file', 'bin_file', 'size', 'sha256')}
        sources += [patch_dir / pd['manifest_file'], patch_dir / pd['bin_file']]
    return canonical(entry, names), sources


def index(manifest) -> dict[str, dict]:
    out = {}
    for item in (manifest.get('countries', []) if isinstance(manifest, dict) else []) or []:
        if isinstance(item, dict) and str(item.get('code', '')).strip():
            out[str(item['code']).strip()] = item
    return out


def needs_inspection(code: str, prev: dict[str, dict], assets: dict[str, int] | None,
                     rebuilt: set[str]) -> bool:
    """True when the release's own CODE.abm must be opened to (re)build the entry."""
    if code in rebuilt or assets is None or f'{code}.abm' not in assets:
        return False
    e = prev.get(code)
    if not e or not is_complete(e):
        return True
    return any(assets.get(f['name']) != f['size'] for f in e['files'])


def validate(path: Path, previous: Path | None) -> int:
    entries = index(load_json(path))
    problems = []
    for code, e in entries.items():
        for k in ('code', 'name_fa', 'name_en', 'country_code', 'country_name_fa', 'country_name_en',
                  'region_name_fa', 'region_name_en', 'bbox', 'sha256', 'files', 'total_size', 'source'):
            if e.get(k) in (None, '', []):
                problems.append(f'{code}: missing {k}')
        if not valid_bbox(e.get('bbox')):
            problems.append(f'{code}: bad bbox')
        if not valid_files(e.get('files')):
            problems.append(f'{code}: bad files')
        elif e.get('total_size') != sum(f['size'] for f in e['files']):
            problems.append(f'{code}: total_size != sum(files)')
        if good_name(e.get('name_en'), code) is False:
            problems.append(f'{code}: name is just the code')
    for code, e in index(load_json(previous)).items():
        if is_complete(e) and code not in entries:
            problems.append(f'{code}: was in the previous manifest but disappeared')
    for p in problems:
        print(f'::error::{p}', file=sys.stderr)
    print(f'{path}: {len(entries)} entries, {len(problems)} problem(s)')
    return 1 if problems else 0


def load_source_meta(dist: Path | None, code: str) -> dict:
    if not dist:
        return {}
    # Split countries (for example US-NE) share the parent country source
    # extract, so fall back to the parent source metadata when no region-level
    # sidecar exists.
    candidates = [dist / f'{code}.source.json']
    parent = str(code).split('-', 1)[0]
    if parent != code:
        candidates.append(dist / f'{parent}.source.json')
    for path in candidates:
        data = load_json(path)
        if isinstance(data, dict) and data:
            return data
    return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dist', type=Path, nargs='?', help='directory with freshly built CC.abm / CC-parts / CC-patch')
    ap.add_argument('--release-tag', default='')
    ap.add_argument('--names', type=Path, help='countries.json (display names + pbf_url)')
    ap.add_argument('--previous-manifest', type=Path)
    ap.add_argument('--current-manifest', type=Path, action='append', default=[],
                    help='manifest fragment(s) from build jobs; repeatable')
    ap.add_argument('--asset-dir', type=Path, help='directory with .abm files downloaded from the release')
    ap.add_argument('--release-assets-json', type=Path, help='output of: gh release view TAG --json assets')
    ap.add_argument('--stage-dir', type=Path, help='copy every file referenced by fresh entries here (flat)')
    ap.add_argument('--stale-out', type=Path, help='write release assets superseded by this run')
    ap.add_argument('--list-incomplete', action='store_true',
                    help='print codes whose release CODE.abm must be downloaded to repair their entry')
    ap.add_argument('--validate', type=Path, metavar='MANIFEST',
                    help='check a finished manifest (schema of every entry; no previously complete '
                         'entry from --previous-manifest may have disappeared) and exit 1 on problems')
    ap.add_argument('-o', '--output', type=Path)
    args = ap.parse_args()

    if args.validate:
        return validate(args.validate, args.previous_manifest)

    names = load_json(args.names)
    prev = index(load_json(args.previous_manifest))
    assets = asset_map(args.release_assets_json)

    fresh: dict[str, dict] = {}
    staged: dict[str, list[Path]] = {}
    for frag in args.current_manifest:
        for code, e in index(load_json(frag)).items():
            fresh[code] = canonical(e, names)

    if args.dist:
        for abm in sorted(args.dist.glob('*.abm')):
            code = abm.stem
            entry, sources = build_entry(code, abm, names, args.dist / f'{code}-parts',
                                         args.dist / f'{code}-patch', load_source_meta(args.dist, code))
            if entry is None:
                raise SystemExit(f'{abm} has no valid bbox in metadata.json - rebuild with the current build_abm.py')
            fresh[code] = entry
            staged[code] = sources

    if args.list_incomplete:
        codes = sorted({n[:-4] for n in (assets or {}) if n.endswith('.abm')} |
                       {c for c in prev if assets and f'{c}.abm' in assets})
        for code in codes:
            if needs_inspection(code, prev, assets, set(fresh)):
                print(code)
        return 0

    if not args.output:
        ap.error('-o/--output is required')

    result = {code: canonical(e, names) for code, e in prev.items()}

    # Repair / discover from the .abm files that are really in the release.
    if args.asset_dir:
        for abm in sorted(args.asset_dir.glob('*.abm')):
            code = abm.stem
            if code in fresh:
                continue
            entry, _ = build_entry(code, abm, names)
            if entry is None:
                warn(f'{abm.name}: no valid bbox in metadata.json, cannot add {code} to the manifest '
                     f'(it is fixed by the next successful rebuild)')
                continue
            old = result.get(code)
            if old and old.get('patch') and old.get('sha256') == entry['sha256']:
                entry['patch'] = old['patch']
            result[code] = entry

    result.update(fresh)

    # The manifest must only reference files that exist in the release (or are about to be uploaded).
    for code in sorted(result):
        e = result[code]
        if code in fresh:
            continue
        problem = None
        if not is_complete(e):
            problem = 'missing bbox/files'
        elif assets is not None:
            gone = [f['name'] for f in e['files'] if f['name'] not in assets]
            wrong = [f['name'] for f in e['files'] if assets.get(f['name']) != f['size']]
            if gone:
                problem = f'files not in release: {gone}'
            elif wrong:
                problem = f'size differs from release asset: {wrong}'
            elif e.get('patch') and any(n not in assets for n in patch_names(e)):
                e.pop('patch')
        if problem:
            warn(f'dropping {code} from manifest: {problem}')
            del result[code]

    manifest = {
        'release_tag': args.release_tag or (load_json(args.previous_manifest) or {}).get('release_tag', ''),
        'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'countries': [result[c] for c in sorted(result)],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    if args.stage_dir:
        args.stage_dir.mkdir(parents=True, exist_ok=True)
        for code in fresh:
            for src in staged.get(code, []):
                shutil.copy2(src, args.stage_dir / src.name)

    if args.stale_out:
        referenced = {'manifest.json'}
        for e in result.values():
            referenced |= {f['name'] for f in e['files']} | set(patch_names(e))
        stale = []
        for code in sorted(fresh):
            pat = re.compile(rf'^{re.escape(code)}\.(abm|part\d{{3}}|abmpatch\.json|abmpatch\.bin)$')
            stale += [n for n in sorted(assets or {}) if pat.match(n) and n not in referenced]
        args.stale_out.write_text(''.join(f'{n}\n' for n in stale), encoding='utf-8')

    print(f'Wrote {args.output}: {len(manifest["countries"])} entries '
          f'({len(fresh)} fresh, {len(manifest["countries"]) - len(fresh)} carried/repaired)')
    for e in manifest['countries']:
        print(f'  {e["code"]:8} {e["name_en"]:22} {e["total_size"]:>12} B  '
              f'{"patch" if e.get("patch") else "-"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
