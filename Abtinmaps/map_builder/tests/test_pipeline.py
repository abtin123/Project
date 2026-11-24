import random, sqlite3, sys, tempfile, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_abm import _build_one
from extractors.loader import load
from release_packaging.create_abm import verify_abm
from search.map_db import search

SAMPLE = Path(__file__).resolve().parent.parent / "sample" / "us_mini.jsonl"


def _abm(tmp: Path) -> Path:
    out = tmp / "US.abm"
    _build_one(load(SAMPLE), "US", out, SAMPLE)
    return out


def test_build_verify_and_no_duplicates():
    with tempfile.TemporaryDirectory() as d:
        out = _abm(Path(d))
        verify_abm(out)  # also enforces unique names / segments
        z = zipfile.ZipFile(out)
        assert {"US.sqlite", "US.mbtiles", "metadata.json", "manifest.json"} <= set(z.namelist())
        z.extractall(d)
        c = sqlite3.connect(Path(d) / "US.sqlite")
        two_way = c.execute("SELECT COUNT(*) FROM segments s JOIN way_data w USING(way_id) WHERE w.oneway=0").fetchone()[0]
        segs = c.execute("SELECT COUNT(*) FROM segments").fetchone()[0]
        assert c.execute("SELECT COUNT(*) FROM edges").fetchone()[0] == segs + two_way
        assert search(Path(d) / "US.sqlite", "Broadway")


def test_pbf_stream_keeps_distinct_ways():
    import pytest
    pytest.importorskip("osmium")
    from routing.graph_builder import build_graph_from_pbf
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "t.osm"
        src.write_text('<?xml version="1.0"?><osm version="0.6">'
            '<node id="1" lat="34.10" lon="49.68" version="1"/><node id="2" lat="34.101" lon="49.681" version="1"/>'
            '<node id="3" lat="34.102" lon="49.682" version="1"/><node id="4" lat="34.103" lon="49.683" version="1"/>'
            '<way id="10" version="1"><nd ref="1"/><nd ref="2"/><nd ref="3"/><tag k="highway" v="residential"/></way>'
            '<way id="11" version="1"><nd ref="3"/><nd ref="4"/><tag k="highway" v="primary"/></way>'
            '<way id="12" version="1"><nd ref="1"/><nd ref="4"/><tag k="highway" v="tertiary"/></way></osm>')
        stats = build_graph_from_pbf(src, Path(d) / "g.sqlite")
        assert stats["ways"] == 3 and stats["segments"] == 4
