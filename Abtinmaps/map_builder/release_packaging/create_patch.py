from __future__ import annotations
import argparse, hashlib, json, struct, zipfile
from pathlib import Path

SCHEMA_V1 = 'ABTINMAP-CHUNK-PATCH/1'   # index-aligned chunks (what shipped apps understand)
SCHEMA_V2 = 'ABTINMAP-CHUNK-PATCH/2'   # member-aware copy/literal ops (survives shifted offsets)
SCHEMA = SCHEMA_V1                      # kept for backward-compatible imports
V2_MAX_RATIO = 0.5                      # use v2 only if it is much smaller than v1 (v1 works with shipped apps)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


# --------------------------------------------------------------------------- v1
def _build_v1(base: Path, target: Path, patch_path: Path, chunk_size: int) -> list[dict]:
    blocks, patch_offset = [], 0
    with base.open('rb') as old, target.open('rb') as new, patch_path.open('wb') as patch:
        index = 0
        while True:
            old_chunk, new_chunk = old.read(chunk_size), new.read(chunk_size)
            if not new_chunk:
                break
            if old_chunk != new_chunk:
                patch.write(new_chunk)
                blocks.append({'index': index, 'offset': patch_offset, 'size': len(new_chunk)})
                patch_offset += len(new_chunk)
            index += 1
    return blocks


# --------------------------------------------------------------------------- v2
def _members(path: Path) -> dict[str, tuple[int, int]] | None:
    """name -> (absolute data offset, stored size) for every member, or None if not a zip."""
    if not zipfile.is_zipfile(path):
        return None
    out: dict[str, tuple[int, int]] = {}
    with zipfile.ZipFile(path) as z, path.open('rb') as f:
        for info in z.infolist():
            if info.is_dir():
                continue
            f.seek(info.header_offset)
            hdr = f.read(30)
            if len(hdr) != 30 or hdr[:4] != b'PK\x03\x04':
                return None
            n, m = struct.unpack('<HH', hdr[26:30])
            out[info.filename] = (info.header_offset + 30 + n + m, info.compress_size)
    return out


def _build_v2(base: Path, target: Path, patch_path: Path, chunk_size: int) -> list[dict] | None:
    bm, tm = _members(base), _members(target)
    if bm is None or tm is None:
        return None
    tsize = target.stat().st_size
    # target data regions that have a same-named base member, in file order
    regions = sorted((t_off, size, bm[name][0], bm[name][1])
                     for name, (t_off, size) in tm.items() if name in bm and size > 0)
    ops: list[dict] = []

    def add(kind: str, length: int, offset: int):
        if length <= 0:
            return
        last = ops[-1] if ops else None
        if last and last['src'] == kind and kind == 'base' and last['offset'] + last['len'] == offset:
            last['len'] += length
        elif last and last['src'] == kind and kind == 'patch':
            last['len'] += length
        else:
            ops.append({'src': kind, 'offset': offset, 'len': length})

    with base.open('rb') as old, target.open('rb') as new, patch_path.open('wb') as patch:
        def literal(start: int, end: int):
            if end <= start:
                return
            new.seek(start)
            left = end - start
            while left:
                data = new.read(min(left, 1024 * 1024))
                add('patch', len(data), patch.tell())
                patch.write(data)
                left -= len(data)

        pos = 0
        for t_off, size, b_off, b_size in regions:
            if t_off < pos:
                return None
            literal(pos, t_off)                     # local header etc. of this member
            done = 0
            while done < size:
                n = min(chunk_size, size - done)
                same = False
                if done + n <= b_size:
                    old.seek(b_off + done)
                    new.seek(t_off + done)
                    same = old.read(n) == new.read(n)
                if same:
                    add('base', n, b_off + done)
                else:
                    literal(t_off + done, t_off + done + n)
                done += n
            pos = t_off + size
        literal(pos, tsize)                          # central directory / trailing bytes
    return ops


def apply_patch(base: Path, manifest: dict, patch_bin: Path, out: Path) -> None:
    """Reference implementation (the app must do the same)."""
    if manifest['schema'] == SCHEMA_V2:
        with base.open('rb') as b, patch_bin.open('rb') as p, out.open('wb') as o:
            for op in manifest['ops']:
                src = b if op['src'] == 'base' else p
                src.seek(op['offset'])
                left = op['len']
                while left:
                    data = src.read(min(left, 1024 * 1024))
                    if not data:
                        raise ValueError('patch/base truncated')
                    o.write(data)
                    left -= len(data)
        return
    cs, tsize = manifest['chunk_size'], manifest['target_size']
    changed = {b['index']: b for b in manifest['blocks']}
    with base.open('rb') as b, patch_bin.open('rb') as p, out.open('wb') as o:
        for i in range((tsize + cs - 1) // cs):
            n = min(cs, tsize - i * cs)
            if i in changed:
                p.seek(changed[i]['offset']); o.write(p.read(n))
            else:
                b.seek(i * cs); o.write(b.read(n))


# --------------------------------------------------------------------------- entry
def create_patch(base: Path, target: Path, code: str, output_dir: Path,
                 chunk_size: int = 4 * 1024 * 1024) -> tuple[Path, Path]:
    if chunk_size <= 0:
        raise ValueError('chunk_size must be positive')
    output_dir.mkdir(parents=True, exist_ok=True)
    patch_name, manifest_name = f'{code}.abmpatch.bin', f'{code}.abmpatch.json'
    patch_path = output_dir / patch_name

    blocks = _build_v1(base, target, patch_path, chunk_size)
    v1_size = patch_path.stat().st_size
    ops = None
    v2_tmp = output_dir / f'{code}.abmpatch.v2.tmp'
    try:
        ops = _build_v2(base, target, v2_tmp, chunk_size)
        if ops is not None and v2_tmp.stat().st_size < v1_size * V2_MAX_RATIO:
            v2_tmp.replace(patch_path)
        else:
            ops = None
    finally:
        v2_tmp.unlink(missing_ok=True)

    manifest = {
        'schema': SCHEMA_V2 if ops is not None else SCHEMA_V1, 'code': code,
        'base_sha256': sha256(base), 'target_sha256': sha256(target),
        'target_size': target.stat().st_size, 'chunk_size': chunk_size,
        'patch_sha256': sha256(patch_path),
        'blocks': [] if ops is not None else blocks,
    }
    if ops is not None:
        manifest['ops'] = ops
    manifest_path = output_dir / manifest_name
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    descriptor = {
        'base_sha256': manifest['base_sha256'], 'manifest_file': manifest_name,
        'bin_file': patch_name, 'size': patch_path.stat().st_size,
        'sha256': manifest['patch_sha256'],
    }
    (output_dir / 'patch-descriptor.json').write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + '\n')
    return manifest_path, patch_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Create an ABTINMAP patch')
    parser.add_argument('base', type=Path); parser.add_argument('target', type=Path)
    parser.add_argument('--code', required=True); parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chunk-size-mib', type=int, default=4)
    args = parser.parse_args()
    manifest, patch = create_patch(args.base, args.target, args.code, args.output, args.chunk_size_mib * 1024 * 1024)
    print(json.dumps({'manifest': str(manifest), 'patch': str(patch)}, indent=2))
