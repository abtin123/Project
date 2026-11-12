import sqlite3
from pathlib import Path

from search.map_db import search, search_many


def _db(path: Path, rows):
    con = sqlite3.connect(path)
    con.executescript('''
        CREATE TABLE categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
        CREATE TABLE names(id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_fa TEXT NOT NULL, name_en TEXT NOT NULL);
        CREATE TABLE features(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, name_id INTEGER, category_id INTEGER NOT NULL, opening_hours TEXT NOT NULL DEFAULT '');
        CREATE VIRTUAL TABLE spatial USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        CREATE VIRTUAL TABLE search_fts USING fts5(name, name_fa, name_en, content='names', content_rowid='id');
    ''')
    con.executemany('INSERT INTO categories VALUES (?,?)', [(1, 'road')])
    for i, (name, lat, lon) in enumerate(rows, 1):
        con.execute('INSERT INTO names VALUES (?,?,?,?)', (i, name, name, name))
        con.execute('INSERT INTO features VALUES (?,?,?,?,?)', (i, 2, i, 1, ''))
        con.execute('INSERT INTO spatial VALUES (?,?,?,?,?)', (i, lon, lon, lat, lat))
    con.execute("INSERT INTO search_fts(search_fts) VALUES('rebuild')")
    con.commit(); con.close()


def test_search_prefers_nearest_result_over_fts_order(tmp_path):
    db = tmp_path / 'ham.sqlite'
    _db(db, [('Imam Khomeini Boulevard', 35.0, 51.0), ('Imam Khomeini Boulevard', 35.8, 51.8)])
    result = search(db, 'Imam Khomeini Boulevard', limit=2, latitude=35.0, longitude=51.0)
    assert result[0]['lat'] == 35.0
    assert result[0]['distance_m'] < result[1]['distance_m']


def test_search_many_ranks_across_active_dbs_by_distance(tmp_path):
    near = tmp_path / 'ham.sqlite'
    far = tmp_path / 'mkz.sqlite'
    _db(near, [('Imam Khomeini Boulevard', 35.0, 51.0)])
    _db(far, [('Imam Khomeini Boulevard', 36.0, 52.0)])
    result = search_many([far, near], 'Imam Khomeini Boulevard', limit=2, latitude=35.0, longitude=51.0)
    assert result[0]['database'].endswith('ham.sqlite')
    assert result[0]['distance_m'] < result[1]['distance_m']
