import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'release_packaging' / 'build_release_manifest.py'
NAMES = {
    'AM': {'name_fa': 'ارمنستان', 'name_en': 'Armenia', 'pbf_url': 'https://x/armenia.pbf'},
    'IR': {'name_fa': 'ایران', 'name_en': 'Iran', 'pbf_url': 'https://x/iran.pbf'},
    'TR': {'name_fa': 'ترکیه', 'name_en': 'Turkey', 'pbf_url': 'https://x/turkey.pbf'},
}
AM_KEYS = ['code', 'name_fa', 'name_en', 'country_code', 'country_name_fa', 'country_name_en',
           'region_name_fa', 'region_name_en', 'bbox', 'sha256', 'files', 'total_size', 'source']


def make_abm(path: Path, bbox, payload=b'x', region=None):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('metadata.json', json.dumps({'bbox': bbox, 'region': region}))
        z.writestr(f'{path.stem}.sqlite', payload)
    return path


def run(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True, check=True)


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / 'names.json').write_text(json.dumps(NAMES), encoding='utf-8')

    def assets_json(self, **sizes):
        p = self.tmp / 'assets.json'
        p.write_text(json.dumps({'assets': [{'name': n, 'size': s} for n, s in sizes.items()]}))
        return p

    def test_iran_repaired_from_release_abm_like_armenia(self):
        (self.tmp / 'release').mkdir()
        ir = make_abm(self.tmp / 'release' / 'IR.abm', [44.0, 25.0, 63.3, 39.8], b'iran')
        prev = {'release_tag': 'maps-v4', 'countries': [{
            'code': 'IR', 'country_code': 'IR', 'name_fa': 'IR', 'name_en': 'IR',
            'files': [{'name': 'IR.abm', 'size': ir.stat().st_size, 'sha256': 'old'}],
            'total_size': ir.stat().st_size, 'sha256': 'old'}]}
        (self.tmp / 'prev.json').write_text(json.dumps(prev))
        assets = self.assets_json(**{'IR.abm': ir.stat().st_size, 'manifest.json': 1})

        out = run('--previous-manifest', self.tmp / 'prev.json', '--release-assets-json', assets,
                  '--list-incomplete').stdout.split()
        self.assertEqual(out, ['IR'])

        run('--release-tag', 'maps-v4', '--names', self.tmp / 'names.json',
            '--previous-manifest', self.tmp / 'prev.json', '--release-assets-json', assets,
            '--asset-dir', ir.parent, '-o', self.tmp / 'out.json')
        e = json.loads((self.tmp / 'out.json').read_text(encoding='utf-8'))['countries'][0]
        self.assertEqual(list(e)[:len(AM_KEYS)], AM_KEYS)
        self.assertEqual((e['name_fa'], e['name_en']), ('ایران', 'Iran'))
        self.assertEqual(e['bbox'], [44.0, 25.0, 63.3, 39.8])
        self.assertEqual(e['source']['url'], 'https://x/iran.pbf')
        self.assertEqual(e['files'][0]['sha256'], e['sha256'])
        self.assertNotEqual(e['sha256'], 'old')

    def test_partial_run_keeps_other_countries_and_stages_files(self):
        dist = self.tmp / 'dist'
        dist.mkdir()
        am = make_abm(dist / 'AM.abm', [43.0, 38.7, 46.7, 41.4], b'new')
        (dist / 'AM-patch').mkdir()
        (dist / 'AM-patch' / 'AM.abmpatch.json').write_text('{}')
        (dist / 'AM-patch' / 'AM.abmpatch.bin').write_bytes(b'p')
        (dist / 'AM-patch' / 'patch-descriptor.json').write_text(json.dumps({
            'base_sha256': 'b', 'manifest_file': 'AM.abmpatch.json', 'bin_file': 'AM.abmpatch.bin',
            'size': 1, 'sha256': 'c'}))
        ir_entry = {'code': 'IR', 'country_code': 'IR', 'name_fa': 'ایران', 'name_en': 'Iran',
                    'bbox': [44.0, 25.0, 63.3, 39.8], 'sha256': 'i',
                    'files': [{'name': 'IR.abm', 'size': 5, 'sha256': 'i'}], 'total_size': 5}
        old_am = {'code': 'AM', 'files': [{'name': 'AM.abm', 'size': 1, 'sha256': 'o'}]}
        (self.tmp / 'prev.json').write_text(json.dumps({'countries': [ir_entry, old_am]}))
        assets = self.assets_json(**{'AM.abm': 1, 'AM.part000': 1, 'IR.abm': 5, 'AM.abmpatch.bin': 1})

        run(dist, '--release-tag', 't', '--names', self.tmp / 'names.json',
            '--previous-manifest', self.tmp / 'prev.json', '--release-assets-json', assets,
            '--stage-dir', self.tmp / 'stage', '--stale-out', self.tmp / 'stale.txt',
            '-o', self.tmp / 'out.json')
        m = json.loads((self.tmp / 'out.json').read_text(encoding='utf-8'))
        self.assertEqual([c['code'] for c in m['countries']], ['AM', 'IR'])
        am_e = m['countries'][0]
        self.assertEqual(am_e['files'][0]['sha256'], am_e['sha256'])
        self.assertEqual(am_e['patch']['bin_file'], 'AM.abmpatch.bin')
        self.assertEqual(sorted(p.name for p in (self.tmp / 'stage').iterdir()),
                         ['AM.abm', 'AM.abmpatch.bin', 'AM.abmpatch.json'])
        self.assertEqual((self.tmp / 'stale.txt').read_text().split(), ['AM.part000'])
        self.assertEqual(am.stat().st_size, am_e['total_size'])

    def test_unrepairable_entry_dropped(self):
        prev = {'countries': [{'code': 'IR', 'files': [{'name': 'IR.abm', 'size': 5, 'sha256': 'i'}]}]}
        (self.tmp / 'prev.json').write_text(json.dumps(prev))
        run('--release-tag', 't', '--previous-manifest', self.tmp / 'prev.json', '-o', self.tmp / 'out.json')
        self.assertEqual(json.loads((self.tmp / 'out.json').read_text())['countries'], [])

    def test_new_country_build_keeps_am_and_repairs_ir(self):
        rel = self.tmp / 'release'
        rel.mkdir()
        ir = make_abm(rel / 'IR.abm', [44.0, 25.0, 63.3, 39.8], b'iran')
        am_entry = {'code': 'AM', 'name_fa': 'ارمنستان', 'name_en': 'Armenia', 'country_code': 'AM',
                    'country_name_fa': 'ارمنستان', 'country_name_en': 'Armenia',
                    'region_name_fa': 'ارمنستان', 'region_name_en': 'Armenia',
                    'bbox': [43.05, 38.74, 46.71, 41.49], 'sha256': 'a',
                    'files': [{'name': 'AM.abm', 'size': 7, 'sha256': 'a'}], 'total_size': 7,
                    'source': {'provider': 'Geofabrik / OpenStreetMap', 'url': 'u'}}
        ir_broken = {'code': 'IR', 'country_code': 'IR', 'name_fa': 'IR', 'name_en': 'IR',
                     'files': [{'name': 'IR.abm', 'size': ir.stat().st_size, 'sha256': 's'}],
                     'total_size': ir.stat().st_size, 'sha256': 's'}
        prev = self.tmp / 'prev.json'
        prev.write_text(json.dumps({'countries': [am_entry, ir_broken]}))
        assets = self.assets_json(**{'AM.abm': 7, 'IR.abm': ir.stat().st_size})

        frag_dist = self.tmp / 'dist'
        frag_dist.mkdir()
        make_abm(frag_dist / 'TR.abm', [26.0, 36.0, 45.0, 42.0], b'turkey')
        run(frag_dist, '--release-tag', 't', '--names', self.tmp / 'names.json', '-o', self.tmp / 'frag.json')

        inc = run('--previous-manifest', prev, '--release-assets-json', assets,
                  '--current-manifest', self.tmp / 'frag.json', '--list-incomplete').stdout.split()
        self.assertEqual(inc, ['IR'])

        run('--release-tag', 't', '--names', self.tmp / 'names.json', '--previous-manifest', prev,
            '--release-assets-json', assets, '--asset-dir', rel, '--current-manifest', self.tmp / 'frag.json',
            '-o', self.tmp / 'out.json')
        m = json.loads((self.tmp / 'out.json').read_text(encoding='utf-8'))
        self.assertEqual([c['code'] for c in m['countries']], ['AM', 'IR', 'TR'])
        for k in ('name_en', 'bbox', 'sha256', 'files', 'total_size'):
            self.assertEqual(m['countries'][0][k], am_entry[k])
        for c in m['countries']:
            self.assertEqual(list(c)[:len(AM_KEYS)], AM_KEYS)
        r = subprocess.run([sys.executable, str(SCRIPT), '--validate', str(self.tmp / 'out.json'),
                            '--previous-manifest', str(prev)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_validate_fails_when_valid_entry_disappears(self):
        good = {'code': 'AM', 'bbox': [1, 2, 3, 4], 'files': [{'name': 'AM.abm', 'size': 1, 'sha256': 'x'}]}
        prev = self.tmp / 'prev.json'
        prev.write_text(json.dumps({'countries': [good]}))
        out = self.tmp / 'out.json'
        out.write_text(json.dumps({'countries': []}))
        r = subprocess.run([sys.executable, str(SCRIPT), '--validate', str(out), '--previous-manifest', str(prev)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


if __name__ == '__main__':
    unittest.main()
