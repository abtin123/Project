#!/usr/bin/env python3
import argparse, json, sys
from pathlib import Path

# Make this runnable both as a script (`python release_packaging/verify_abm.py`)
# and as a package import (`from release_packaging.verify_abm import ...`).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from release_packaging.create_abm import verify_abm
if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('abm',type=Path); a=p.parse_args(); print(json.dumps(verify_abm(a.abm),ensure_ascii=False,indent=2))
