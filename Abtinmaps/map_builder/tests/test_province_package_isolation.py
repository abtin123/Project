import json
import sqlite3
import zipfile
from pathlib import Path

from release_packaging.create_abm import create_abm, verify_abm


def _make_db(path: Path):
    db = sqlite3.connect(path)
    try:
        # Minimal schema used only to exercise packaging/name isolation.
        for name in [
            'features','names','categories','search_fts','spatial','node_data','way_data',
            'segments','road_index','turn_restrictions','turn_restriction_lookup','routing_cells',
            'node_index','way_geometry','hierarchy_edges','roundabout_info','nodes','ways','edges','places','poi'
        ]:
            if name == 'search_fts':
                db.execute('CREATE VIRTUAL TABLE search_fts USING fts5(name)')
            else:
                db.execute(f'CREATE TABLE "{name}" (id INTEGER)')
        db.execute('PRAGMA user_version=7')
        db.execute('INSERT INTO node_data(id) VALUES (1)')
        db.execute('INSERT INTO segments(id) VALUES (1)')
        db.execute('INSERT INTO features(id) VALUES (1)')
        db.commit()
    finally:
        db.close()


def _make_mbtiles(path: Path):
    db = sqlite3.connect(path)
    try:
        db.executescript('''
          CREATE TABLE metadata (name TEXT, value TEXT);
          CREATE TABLE map (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT);
          CREATE TABLE images (tile_id TEXT PRIMARY KEY, tile_data BLOB);
        ''')
        db.execute("INSERT INTO metadata(name,value) VALUES ('format','pbf')")
        db.execute("INSERT INTO images(tile_id,tile_data) VALUES ('x',X'1F8B')")
        db.commit()
    finally:
        db.close()


def _build(tmp_path, code):
    stage = tmp_path / f'work-{code}'
    stage.mkdir()
    _make_db(stage / f'{code}.sqlite')
    _make_mbtiles(stage / f'{code}.mbtiles')
    out = tmp_path / f'{code}.abm'
    create_abm(stage, out, 'IR', Path('iran.pbf'), {'tiles': {'maxzoom': 14}}, (50, 30, 52, 32), None)
    return out


def test_each_province_has_private_runtime_store_names(tmp_path):
    esf = _build(tmp_path, 'IR-ESF')
    ker = _build(tmp_path, 'IR-KER')
    for path, code in [(esf, 'IR-ESF'), (ker, 'IR-KER')]:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            assert {f'{code}.sqlite', f'{code}.mbtiles', 'metadata.json', 'manifest.json'} <= names
            assert 'map.sqlite' not in names
            assert 'map.mbtiles' not in names
            meta = json.loads(z.read('metadata.json'))
            manifest = json.loads(z.read('manifest.json'))
            assert meta['id'] == code
            assert meta['database'] == f'{code}.sqlite'
            assert meta['tile_file'] == f'{code}.mbtiles'
            assert manifest['id'] == code
            assert manifest['database'] == f'{code}.sqlite'
            assert manifest['tiles'] == f'{code}.mbtiles'
            assert manifest['sizes'][f'{code}.sqlite'] > 0
            assert manifest['sizes'][f'{code}.mbtiles'] > 0
