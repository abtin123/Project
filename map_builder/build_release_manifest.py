#!/usr/bin/env python3
"""Compatibility shim: the implementation lives in release_packaging/build_release_manifest.py."""
import runpy
from pathlib import Path

if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).resolve().parent / 'release_packaging' / 'build_release_manifest.py'),
                   run_name='__main__')
