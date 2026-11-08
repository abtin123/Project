import json, os, random, tempfile, unittest, zipfile
from pathlib import Path
from release_packaging.create_patch import create_patch, apply_patch, sha256

C = 64 * 1024


def make_abm(path: Path, tiles: bytes, db: bytes, meta: bytes):
    # same layout as create_abm.py: sorted names, mbtiles STORED, others DEFLATE, fixed dates
    with zipfile.ZipFile(path, 'w') as z:
        for name, data, ct in sorted([('X.mbtiles', tiles, zipfile.ZIP_STORED),
                                      ('X.sqlite', db, zipfile.ZIP_STORED),
                                      ('metadata.json', meta, zipfile.ZIP_DEFLATED)]):
            zi = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0)); zi.compress_type = ct
            with z.open(zi, 'w', force_zip64=True) as d:
                d.write(data)


class PatchTest(unittest.TestCase):
    def roundtrip(self, base_args, target_args):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); rnd = random.Random(1)
            make_abm(d / 'a.abm', *base_args(rnd)); rnd = random.Random(1)
            make_abm(d / 'b.abm', *target_args(rnd))
            mpath, ppath = create_patch(d / 'a.abm', d / 'b.abm', 'X', d / 'out', C)
            m = json.loads(mpath.read_text())
            apply_patch(d / 'a.abm', m, ppath, d / 'r.abm')
            self.assertEqual(sha256(d / 'r.abm'), sha256(d / 'b.abm'))
            return m, ppath.stat().st_size, (d / 'b.abm').stat().st_size

    def test_same_size_change_stays_v1(self):
        def base(r): return os.urandom(0) + r.randbytes(C * 20), r.randbytes(C * 10), b'{"a":1}'
        def tgt(r):
            t, db, _ = base(r); t = bytearray(t); t[C * 5] ^= 1
            return bytes(t), db, b'{"a":2}'
        m, p, full = self.roundtrip(base, tgt)
        self.assertEqual(m['schema'], 'ABTINMAP-CHUNK-PATCH/1'); self.assertLess(p, full / 5)

    def test_growing_tiles_does_not_ruin_patch(self):
        def base(r): return r.randbytes(C * 20), r.randbytes(C * 10), b'{"a":1}'
        def tgt(r):
            t, db, _ = base(r)
            return t + b'extra-tiles-bytes', db, b'{"a":2}'   # shifts everything after mbtiles
        m, p, full = self.roundtrip(base, tgt)
        self.assertEqual(m['schema'], 'ABTINMAP-CHUNK-PATCH/2'); self.assertLess(p, full / 5)


if __name__ == '__main__':
    unittest.main()
