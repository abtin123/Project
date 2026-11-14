#!/usr/bin/env python3
"""Decide whether a country really needs to be rebuilt (weekly workflow helper).

A country is SKIPPED (not downloaded, not rebuilt, not re-uploaded) only when ALL hold:
  * the previous release has a complete manifest entry for it,
  * every file of that entry still exists in the release with the same size,
  * the builder code / regions config did not change since that entry was built,
  * the OSM source is unchanged (ETag, else Last-Modified, else SHA-256 of the PBF).

The header check happens BEFORE the (multi-GB) PBF download, so unchanged countries cost
one HEAD request. The result is exported as SRC_CHANGED=true|false|unknown through
$GITHUB_ENV ("unknown" = the server sends no usable validator -> download and hash).

  check_source.py check    CODE --url URL --previous-manifest M [--assets-json A] [--regions-config R] [--force]
  check_source.py finalize CODE --pbf P --headers H --previous-manifest M --dist DIR [--regions-config R]
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILDER_GLOBS = ('build_abm.py', 'abm_builder/*.py', 'extractors/*.py', 'routing/*.py',
                 'search/*.py', 'release_packaging/create_abm.py', 'tools/*.py')


def builder_hash(regions_config: str = '') -> str:
    """Fingerprint of everything that changes the produced .abm besides the OSM data."""
    h = hashlib.sha256()
    for p in sorted({p for g in BUILDER_GLOBS for p in ROOT.glob(g)}):
        h.update(p.relative_to(ROOT).as_posix().encode() + b'\0' + p.read_bytes() + b'\0')
    if regions_config:
        for cand in (Path(regions_config), ROOT / regions_config, ROOT / 'sample' / regions_config):
            if cand.is_file():
                h.update(b'regions\0' + cand.read_bytes())
                break
    return h.hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def load_json(path: str | Path | None):
    if not path or not Path(path).exists():
        return None
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return None


def entries_for(manifest, code: str) -> list[dict]:
    """The country's own entry, or every region entry (US-NE, US-SW, ...) of a split country."""
    items = manifest.get('countries', []) if isinstance(manifest, dict) else []
    return [e for e in items if isinstance(e, dict)
            and (str(e.get('code', '')) == code or str(e.get('country_code', '')).upper() == code)]


def assets_map(data) -> dict[str, int] | None:
    if data is None:
        return None
    items = data.get('assets', []) if isinstance(data, dict) else data
    return {a['name']: int(a.get('size', -1)) for a in items if isinstance(a, dict) and 'name' in a}


def head_headers(url: str, timeout: int = 60) -> dict[str, str]:
    """Lower-cased response headers of a HEAD request ({} on any failure)."""
    try:
        req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'abtin-maps-builder'})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return {k.lower(): v.strip() for k, v in r.headers.items()}
    except Exception as exc:  # network trouble must not break the build: fall back to hashing
        print(f'HEAD {url} failed: {exc}', file=sys.stderr)
        return {}


def parse_header_dump(path: Path) -> dict[str, str]:
    """Headers of the LAST response in a `curl -D` dump (earlier blocks are redirects)."""
    headers: dict[str, str] = {}
    if not path.exists():
        return headers
    for line in path.read_text(errors='ignore').splitlines():
        if line.startswith('HTTP/'):
            headers = {}
        elif ':' in line:
            k, v = line.split(':', 1)
            headers[k.strip().lower()] = v.strip()
    return headers


def decide(headers: dict[str, str], entries: list[dict], assets: dict[str, int] | None,
           current_builder: str, force: bool = False) -> tuple[bool | None, str]:
    """(True = rebuild, False = skip, None = need the PBF hash to know), reason."""
    if force:
        return True, 'forced'
    if not entries:
        return True, 'no previous release entry'
    for e in entries:
        files = e.get('files') or []
        if not files or not e.get('sha256'):
            return True, f"previous entry {e.get('code')} is incomplete"
        if assets is not None:
            for f in files:
                if assets.get(f.get('name')) != f.get('size'):
                    return True, f"release asset {f.get('name')} is missing or has another size"
    src = entries[0].get('source') or {}
    old_builder = src.get('builder_hash') or ''
    if old_builder and old_builder != current_builder:
        return True, 'builder code or regions config changed since the last build'
    etag, last_modified = headers.get('etag', ''), headers.get('last-modified', '')
    if etag and src.get('pbf_etag'):
        return etag != src['pbf_etag'], 'ETag ' + ('changed' if etag != src['pbf_etag'] else 'unchanged')
    if last_modified and src.get('pbf_last_modified'):
        same = last_modified == src['pbf_last_modified']
        return (not same), 'Last-Modified ' + ('unchanged' if same else 'changed')
    return None, 'no comparable HTTP validators, content hash needed'


def source_meta(pbf: Path, headers: dict[str, str], builder: str) -> dict:
    return {
        'pbf_sha256': sha256_file(pbf),
        'pbf_size': pbf.stat().st_size,
        'pbf_last_modified': headers.get('last-modified', ''),
        'pbf_etag': headers.get('etag', ''),
        'builder_hash': builder,
        'source_checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def _export(changed: bool | None) -> None:
    value = 'unknown' if changed is None else str(changed).lower()
    print(f'SRC_CHANGED={value}')
    env_file = os.environ.get('GITHUB_ENV')
    if env_file:
        with open(env_file, 'a', encoding='utf-8') as f:
            f.write(f'SRC_CHANGED={value}\n')


def cmd_check(a) -> int:
    entries = entries_for(load_json(a.previous_manifest), a.code)
    assets = assets_map(load_json(a.assets_json))
    changed, reason = decide(head_headers(a.url), entries, assets,
                             builder_hash(a.regions_config), a.force)
    print(f'{a.code}: {reason}')
    _export(changed)
    return 0


def cmd_finalize(a) -> int:
    builder = builder_hash(a.regions_config)
    meta = source_meta(a.pbf, parse_header_dump(a.headers), builder)
    state = os.environ.get('SRC_CHANGED', 'unknown')
    if state == 'unknown':
        entries = entries_for(load_json(a.previous_manifest), a.code)
        old = ((entries[0].get('source') or {}).get('pbf_sha256') or '') if entries else ''
        changed = (not old) or old != meta['pbf_sha256']
        print(f"{a.code}: sha256 {'changed' if changed else 'unchanged'} "
              f"(new={meta['pbf_sha256'][:12]} old={old[:12] or 'none'})")
        _export(changed)
        state = 'true' if changed else 'false'
    if state == 'true':
        a.dist.mkdir(parents=True, exist_ok=True)
        if a.region_fingerprints and a.region_fingerprints.exists():
            fingerprints = json.loads(a.region_fingerprints.read_text(encoding='utf-8'))
            for region_code, fp in fingerprints.items():
                region_meta = dict(meta)
                region_meta['region_pbf_sha256'] = fp.get('sha256', '')
                region_meta['region_source_objects'] = fp.get('objects', 0)
                (a.dist / f'{region_code}.source.json').write_text(
                    json.dumps(region_meta, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        else:
            (a.dist / f'{a.code}.source.json').write_text(
                json.dumps(meta, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('check')
    c.add_argument('code'); c.add_argument('--url', required=True)
    c.add_argument('--previous-manifest'); c.add_argument('--assets-json')
    c.add_argument('--regions-config', default=''); c.add_argument('--force', action='store_true')
    f = sub.add_parser('finalize')
    f.add_argument('code'); f.add_argument('--pbf', type=Path, required=True)
    f.add_argument('--headers', type=Path, required=True)
    f.add_argument('--previous-manifest'); f.add_argument('--dist', type=Path, required=True)
    f.add_argument('--regions-config', default='')
    f.add_argument('--region-fingerprints', type=Path)
    a = ap.parse_args()
    return cmd_check(a) if a.cmd == 'check' else cmd_finalize(a)


if __name__ == '__main__':
    raise SystemExit(main())
