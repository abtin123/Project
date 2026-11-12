import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from release_packaging import check_source as cs  # noqa: E402

FILES = [{'name': 'IR.abm', 'size': 100, 'sha256': 'x'}]


def entry(**source):
    return {'code': 'IR', 'country_code': 'IR', 'sha256': 'x', 'files': FILES, 'source': source}


class DecideTest(unittest.TestCase):
    def test_unchanged_etag_is_skipped(self):
        e = entry(pbf_etag='"a"', builder_hash='B')
        self.assertEqual(cs.decide({'etag': '"a"'}, [e], {'IR.abm': 100}, 'B')[0], False)

    def test_changed_etag_rebuilds(self):
        e = entry(pbf_etag='"a"', builder_hash='B')
        self.assertEqual(cs.decide({'etag': '"b"'}, [e], {'IR.abm': 100}, 'B')[0], True)

    def test_last_modified_used_when_no_etag(self):
        e = entry(pbf_last_modified='Mon', builder_hash='B')
        self.assertEqual(cs.decide({'last-modified': 'Mon'}, [e], None, 'B')[0], False)
        self.assertEqual(cs.decide({'last-modified': 'Tue'}, [e], None, 'B')[0], True)

    def test_no_validators_needs_hash(self):
        e = entry(pbf_sha256='h', builder_hash='B')
        self.assertIsNone(cs.decide({}, [e], None, 'B')[0])

    def test_first_build_and_force(self):
        self.assertEqual(cs.decide({'etag': 'a'}, [], None, 'B')[0], True)
        e = entry(pbf_etag='a', builder_hash='B')
        self.assertEqual(cs.decide({'etag': 'a'}, [e], None, 'B', force=True)[0], True)

    def test_release_asset_missing_or_wrong_size_rebuilds(self):
        e = entry(pbf_etag='a', builder_hash='B')
        self.assertEqual(cs.decide({'etag': 'a'}, [e], {}, 'B')[0], True)
        self.assertEqual(cs.decide({'etag': 'a'}, [e], {'IR.abm': 7}, 'B')[0], True)

    def test_builder_change_rebuilds_but_missing_old_hash_does_not(self):
        e = entry(pbf_etag='a', builder_hash='OLD')
        self.assertEqual(cs.decide({'etag': 'a'}, [e], None, 'NEW')[0], True)
        legacy = entry(pbf_etag='a')
        self.assertEqual(cs.decide({'etag': 'a'}, [legacy], None, 'NEW')[0], False)

    def test_incomplete_previous_entry_rebuilds(self):
        self.assertEqual(cs.decide({'etag': 'a'}, [{'code': 'IR', 'source': {'pbf_etag': 'a'}}], None, 'B')[0], True)

    def test_regions_are_found_by_country_code(self):
        m = {'countries': [{'code': 'US-NE', 'country_code': 'US'}, {'code': 'IR', 'country_code': 'IR'}]}
        self.assertEqual([e['code'] for e in cs.entries_for(m, 'US')], ['US-NE'])

    def test_header_dump_uses_last_response(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'h'
            p.write_text('HTTP/1.1 302 Found\r\nETag: redirect\r\n\r\nHTTP/2 200\r\nETag: "real"\r\nLast-Modified: Mon\r\n\r\n')
            self.assertEqual(cs.parse_header_dump(p), {'etag': '"real"', 'last-modified': 'Mon'})

    def test_builder_hash_reacts_to_code_and_regions(self):
        with tempfile.TemporaryDirectory() as d:
            r = Path(d) / 'r.json'
            r.write_text('{"a":1}')
            h1 = cs.builder_hash(str(r))
            r.write_text('{"a":2}')
            self.assertNotEqual(h1, cs.builder_hash(str(r)))
            self.assertEqual(cs.builder_hash(), cs.builder_hash())


class _Handler(BaseHTTPRequestHandler):
    etag = '"v1"'

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('ETag', type(self).etag)
        self.end_headers()

    def log_message(self, *a):
        pass


class CliTest(unittest.TestCase):
    """Real `check` run against a local HTTP server, exactly like the workflow does it."""

    def run_check(self, tmp, prev, url, force=False):
        env = dict(os.environ, GITHUB_ENV=str(tmp / 'env'))
        (tmp / 'env').write_text('')
        (tmp / 'prev.json').write_text(json.dumps(prev))
        (tmp / 'assets.json').write_text(json.dumps({'assets': [{'name': 'IR.abm', 'size': 100}]}))
        cmd = [sys.executable, str(ROOT / 'release_packaging' / 'check_source.py'), 'check', 'IR', '--url', url,
               '--previous-manifest', str(tmp / 'prev.json'), '--assets-json', str(tmp / 'assets.json')]
        if force:
            cmd.append('--force')
        subprocess.run(cmd, env=env, check=True, capture_output=True)
        return (tmp / 'env').read_text().strip()

    def test_skip_then_rebuild_after_source_changes(self):
        srv = HTTPServer(('127.0.0.1', 0), _Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f'http://127.0.0.1:{srv.server_port}/x.osm.pbf'
        try:
            with tempfile.TemporaryDirectory() as d:
                tmp = Path(d)
                prev = {'countries': [entry(pbf_etag='"v1"', builder_hash=cs.builder_hash())]}
                _Handler.etag = '"v1"'
                self.assertEqual(self.run_check(tmp, prev, url), 'SRC_CHANGED=false')
                self.assertEqual(self.run_check(tmp, prev, url, force=True), 'SRC_CHANGED=true')
                _Handler.etag = '"v2"'
                self.assertEqual(self.run_check(tmp, prev, url), 'SRC_CHANGED=true')
        finally:
            srv.shutdown()
            srv.server_close()

    def test_server_down_falls_back_to_hash(self):
        with tempfile.TemporaryDirectory() as d:
            prev = {'countries': [entry(pbf_etag='"v1"', builder_hash=cs.builder_hash())]}
            self.assertEqual(self.run_check(Path(d), prev, 'http://127.0.0.1:9/none'), 'SRC_CHANGED=unknown')


if __name__ == '__main__':
    unittest.main()
