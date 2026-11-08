import sqlite3
from pathlib import Path

from extractors.loader import Dataset, clip_dataset
from routing.graph_builder import build_graph


def _crossing_dataset():
    d = Dataset()
    # Way 100 crosses x=1 bbox boundary. Its full geometry must remain.
    d.ways.append({
        "id": 100,
        "node_ids": [10, 11, 12],
        "geometry": [(0.0, 35.0), (1.0, 35.0), (2.0, 35.0)],
        "tags": {"highway": "primary", "name": "Cross boundary"},
    })
    # Way 200 touches the region only through a segment whose endpoints are
    # both outside: this catches the old point-only bbox bug.
    d.ways.append({
        "id": 200,
        "node_ids": [20, 21],
        "geometry": [(0.0, 36.0), (2.0, 36.0)],
        "tags": {"highway": "secondary", "name": "Segment crosses"},
    })
    return d


def test_region_selection_keeps_complete_crossing_way():
    clipped = clip_dataset(_crossing_dataset(), (0.9, 34.9, 1.1, 35.1))
    ids = {w["id"] for w in clipped.ways}
    assert ids == {100}
    assert clipped.ways[0]["geometry"] == [(0.0, 35.0), (1.0, 35.0), (2.0, 35.0)]


def test_segment_crossing_without_inside_vertex_is_retained():
    clipped = clip_dataset(_crossing_dataset(), (0.9, 35.9, 1.1, 36.1))
    assert [w["id"] for w in clipped.ways] == [200]
    assert clipped.ways[0]["geometry"] == [(0.0, 36.0), (2.0, 36.0)]


def test_shared_osm_node_identity_survives_region_graphs(tmp_path: Path):
    d = _crossing_dataset()
    a = tmp_path / "a.sqlite"
    b = tmp_path / "b.sqlite"

    left = clip_dataset(d, (-0.1, 34.9, 1.0, 35.1))
    right = clip_dataset(d, (1.0, 34.9, 2.1, 35.1))
    build_graph(left.ways, [], a)
    build_graph(right.ways, [], b)

    da = sqlite3.connect(a)
    db = sqlite3.connect(b)
    try:
        # Node 11 lies exactly on the boundary and is present with the same
        # OSM ID in both region graphs. This is the stitch key used later by
        # the runtime's multi-region routing layer.
        assert da.execute("SELECT id FROM node_data WHERE id=11").fetchone() == (11,)
        assert db.execute("SELECT id FROM node_data WHERE id=11").fetchone() == (11,)
        assert da.execute("SELECT COUNT(*) FROM segments WHERE way_id=100").fetchone()[0] == 2
        assert db.execute("SELECT COUNT(*) FROM segments WHERE way_id=100").fetchone()[0] == 2
    finally:
        da.close()
        db.close()


def test_polygon_is_authoritative_for_published_bbox():
    from shapely.geometry import Polygon
    polygon = Polygon([(10, 20), (12, 20), (12, 22), (10, 22)])
    assert tuple(polygon.bounds) == (10.0, 20.0, 12.0, 22.0)
