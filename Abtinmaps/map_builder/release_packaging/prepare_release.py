#!/usr/bin/env python3
"""Per-archive release prep, run right after build_abm.py:

  * fetch the previously published CODE from the release (whole file, or its parts)
  * create a chunk patch old -> new (kept only if it is clearly smaller than the full file)
  * split the archive into byte parts when it exceeds the release asset cap
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from release_packaging.create_patch import create_patch, sha256  # noqa: E402
from release_packaging.split_abm import split_file  # noqa: E402

PATCH_MAX_RATIO = 0.9


def fetch_previous(code: str, prev_manifest: Path, tag: str, work: Path) -> Path | None:
    if not prev_manifest.exists():
        return None
    entry = next((c for c in json.loads(prev_manifest.read_text(encoding='utf-8')).get('countries', [])
                  if c.get('code') == code), None)
    if not entry or not entry.get('files') or not entry.get('sha256'):
        return None
    work.mkdir(parents=True, exist_ok=True)
    base = work / f'{code}.base'
    try:
        with base.open('wb') as out:
            for f in entry['files']:
                subprocess.run(['gh', 'release', 'download', tag, '--pattern', f['name'],
                                '--dir', str(work), '--clobber'], check=True)
                part = work / f['name']
                with part.open('rb') as src:
                    shutil.copyfileobj(src, out, 1024 * 1024)
                part.unlink()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f'{code}: previous release not downloadable ({exc}); no patch')
        base.unlink(missing_ok=True)
        return None
    if sha256(base) != entry['sha256']:
        print(f'{code}: downloaded base does not match published sha256; no patch')
        base.unlink(missing_ok=True)
        return None
    return base


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('code')
    ap.add_argument('--dist', type=Path, required=True)
    ap.add_argument('--previous-manifest', type=Path, required=True)
    ap.add_argument('--release-tag', required=True)
    ap.add_argument('--max-asset-bytes', type=int, default=int(1.8 * 1024 ** 3))
    ap.add_argument('--work', type=Path, default=Path('base-work'))
    args = ap.parse_args()

    abm = args.dist / f'{args.code}.abm'
    size = abm.stat().st_size

    base = fetch_previous(args.code, args.previous_manifest, args.release_tag, args.work)
    if base is not None:
        if sha256(base) == sha256(abm):
            print(f'{args.code}: unchanged since last release; no patch')
        else:
            out = args.dist / f'{args.code}-patch'
            _, patch = create_patch(base, abm, args.code, out)
            if patch.stat().st_size >= size * PATCH_MAX_RATIO:
                print(f'{args.code}: patch {patch.stat().st_size} B not worth it vs full {size} B; dropped')
                shutil.rmtree(out)
            else:
                print(f'{args.code}: patch {patch.stat().st_size} B vs full {size} B')
        base.unlink(missing_ok=True)

    if size > args.max_asset_bytes:
        parts_dir = args.dist / f'{args.code}-parts'
        parts = split_file(abm, parts_dir, args.max_asset_bytes / 1024 ** 3)
        print(f'{args.code}: {size} B over cap, split into {len(parts)} parts')


if __name__ == '__main__':
    main()
