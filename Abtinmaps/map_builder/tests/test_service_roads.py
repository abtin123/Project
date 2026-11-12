import sqlite3
from pathlib import Path

from routing.graph_builder import build_graph, is_routable_way


def _way(way_id, nodes, geom, tags):
    return {"id": way_id, "node_ids": nodes, "geometry": geom, "tags": tags}


def test_is_routable_way_rules():
    assert is_routable_way({"highway": "service"})
    assert is_routable_way({"highway": "track"})
    assert is_routable_way({"highway": "service", "access": "private"})
    assert not is_routable_way({"highway": "service", "service": "parking_aisle"})
    assert not is_routable_way({"highway": "service", "access": "no"})
    assert not is_routable_way({"highway": "service", "motor_vehicle": "no"})
    assert not is_routable_way({"highway": "footway"})
    assert is_routable_way({"highway": "primary", "access": "no"})  # unchanged behavior


def test_campus_service_roads_are_in_the_graph(tmp_path: Path):
    ways = [
        _way(1, [1, 2], [(51.0, 35.0), (51.001, 35.0)], {"highway": "primary", "name": "Main"}),
        _way(2, [2, 3], [(51.001, 35.0), (51.001, 35.001)], {"highway": "service", "name": "Hospital loop"}),
        _way(3, [3, 4], [(51.001, 35.001), (51.002, 35.001)], {"highway": "service", "service": "parking_aisle"}),
        _way(4, [3, 5], [(51.001, 35.001), (51.0, 35.001)], {"highway": "service", "access": "no"}),
    ]
    db = tmp_path / "g.sqlite"
    build_graph(ways, [], db)
    con = sqlite3.connect(db)
    ids = {r[0] for r in con.execute("SELECT way_id FROM way_data")}
    assert ids == {1, 2}
