import json
from pathlib import Path

from shapely.geometry import Polygon

from extractors.loader import Dataset, clip_dataset


def test_polygon_selection_rejects_bbox_false_positive_and_keeps_crossing_way():
    d = Dataset()
    # L-shaped polygon; bbox includes the top-right false-positive area.
    poly = Polygon([(0,0),(2,0),(2,1),(1,1),(1,2),(0,2)])
    d.nodes = [
        {"id": 1, "lon": 1.5, "lat": 1.5, "tags": {"name": "outside"}},
        {"id": 2, "lon": 0.5, "lat": 1.5, "tags": {"name": "inside"}},
    ]
    d.ways = [
        {"id": 10, "node_ids": [10,11], "geometry": [(0.5,1.5),(1.5,1.5)], "tags": {"highway":"primary"}},
        {"id": 20, "node_ids": [20,21], "geometry": [(1.2,1.2),(1.8,1.8)], "tags": {"highway":"primary"}},
    ]
    out = clip_dataset(d, region_geometry=poly)
    assert {n["id"] for n in out.nodes} == {2}
    assert {w["id"] for w in out.ways} == {10}


def test_polygon_config_is_json_serializable():
    poly = Polygon([(0,0),(1,0),(1,1),(0,1)])
    payload = {"code":"XX-A", "geometry": json.loads(json.dumps(poly.__geo_interface__))}
    assert payload["geometry"]["type"] == "Polygon"
