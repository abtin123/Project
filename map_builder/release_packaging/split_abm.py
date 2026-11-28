from __future__ import annotations
import hashlib, json, math
from pathlib import Path

def split_file(source: Path, output_dir: Path, part_size_gib: float = 1.8) -> list[Path]:
    if part_size_gib <= 0: raise ValueError('part_size_gib must be positive')
    part_size = int(part_size_gib * 1024**3)
    output_dir.mkdir(parents=True, exist_ok=True)
    parts=[]
    with source.open('rb') as src:
        index=0
        while True:
            chunk=src.read(part_size)
            if not chunk: break
            path=output_dir / f'{source.stem}.part{index:03d}'
            path.write_bytes(chunk); parts.append(path); index += 1
    manifest={'format':'ABM-PARTS','file':source.name,'size':source.stat().st_size,'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'parts':[{'name':p.name,'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in parts]}
    (output_dir/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return parts

def join_parts(manifest: Path, output: Path) -> Path:
    data=json.loads(manifest.read_text()); digest=hashlib.sha256(); output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('wb') as dst:
        for item in data['parts']:
            p=manifest.parent/item['name']; chunk=p.read_bytes()
            if len(chunk)!=item['size'] or hashlib.sha256(chunk).hexdigest()!=item['sha256']: raise ValueError(f'Invalid part: {p}')
            dst.write(chunk); digest.update(chunk)
    if digest.hexdigest()!=data['sha256'] or output.stat().st_size!=data['size']: raise ValueError('Reassembled ABM checksum mismatch')
    return output

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Split or join large ABM archives')
    sub = parser.add_subparsers(dest='command', required=True)
    split = sub.add_parser('split'); split.add_argument('source', type=Path); split.add_argument('--output', type=Path, required=True); split.add_argument('--part-size-gib', type=float, default=1.8)
    join = sub.add_parser('join'); join.add_argument('manifest', type=Path); join.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'split': split_file(args.source, args.output, args.part_size_gib)
    else: join_parts(args.manifest, args.output)
