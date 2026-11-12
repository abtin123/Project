import sqlite3
from pathlib import Path

from routing.graph_builder import build_graph, merge_graph
from search.create_search_db import create_search_db
from search.map_db import finalize_map_db


def test_indexed_turn_rules_and_reverse_oneway(tmp_path: Path) -> None:
    map_db = tmp_path / "map.sqlite"
    graph_db = tmp_path / "graph.sqlite"
    create_search_db(map_db, [], [], [])

    ways = [
        {
            "id": 100,
            "tags": {"highway": "primary", "oneway": "-1", "name": "Reverse"},
            "node_ids": [1, 2],
            "geometry": [[51.4, 35.7], [51.41, 35.71]],
        },
        {
            "id": 200,
            "tags": {"highway": "residential", "name": "Cross"},
            "node_ids": [2, 3],
            "geometry": [[51.41, 35.71], [51.42, 35.72]],
        },
    ]
    relations = [
        {
            "id": 900,
            "tags": {"type": "restriction", "restriction": "no_straight_on"},
            "members": [
                {"type": "way", "ref": 100, "role": "from"},
                {"type": "node", "ref": 2, "role": "via"},
                {"type": "way", "ref": 200, "role": "to"},
            ],
        }
    ]

    build_graph(ways, relations, graph_db)
    merge_graph(map_db, graph_db)
    finalize_map_db(map_db)

    db = sqlite3.connect(map_db)
    try:
        # The stored segment orientation is the actual routable from/to order.
        assert db.execute(
            "SELECT a, b FROM segments WHERE way_id=100"
        ).fetchall() == [(2, 1)]
        assert db.execute(
            'SELECT start, "end" FROM edges WHERE way_id=100'
        ).fetchall() == [(2, 1)]

        assert db.execute(
            "SELECT from_way, via_node, to_way, restriction "
            "FROM turn_restriction_lookup"
        ).fetchall() == [(100, 2, 200, "no_straight_on")]
        plan = " ".join(
            str(row)
            for row in db.execute(
                "EXPLAIN QUERY PLAN SELECT to_way FROM turn_restriction_lookup "
                "WHERE from_way=? AND via_node=?",
                (100, 2),
            )
        )
        assert "idx_turn_lookup_route" in plan
    finally:
        db.close()


def test_no_restrictions_produce_empty_indexed_lookup(tmp_path: Path) -> None:
    map_db = tmp_path / "map.sqlite"
    graph_db = tmp_path / "graph.sqlite"
    create_search_db(map_db, [], [], [])
    build_graph(
        [
            {
                "id": 1,
                "tags": {"highway": "residential"},
                "node_ids": [1, 2],
                "geometry": [[51.4, 35.7], [51.41, 35.71]],
            }
        ],
        [],
        graph_db,
    )
    merge_graph(map_db, graph_db)
    finalize_map_db(map_db)
    db = sqlite3.connect(map_db)
    try:
        assert db.execute(
            "SELECT COUNT(*) FROM turn_restriction_lookup"
        ).fetchone()[0] == 0
    finally:
        db.close()


def test_schema_version_advances_for_runtime_lookup() -> None:
    from search.map_db import SCHEMA_VERSION

    assert SCHEMA_VERSION == 7
