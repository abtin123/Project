from __future__ import annotations
from pathlib import Path
from .map_db import create_map_db, search

# Kept under the old import name so callers do not need a new module name.
def create_search_db(path: Path, pois: list[dict], places: list[dict], roads: list[dict]) -> int:
    return create_map_db(path, pois, places, roads)
