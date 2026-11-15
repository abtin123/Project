"""Dependency-free Mapbox Vector Tile (spec v2) encoder/decoder and the
tile-space geometry helpers (mercator, importance simplification, clipping)."""
from __future__ import annotations

import gzip
import math

EXTENT = 4096
BUFFER = 64
INF = float("inf")
POINT, LINE, POLY = 1, 2, 3


# --- projection / simplification -------------------------------------------
def merc(lon: float, lat: float) -> tuple[float, float]:
    lat = max(-85.05112878, min(85.05112878, lat))
    s = math.sin(math.radians(lat))
    return (lon + 180.0) / 360.0, 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)


def importance(pts: list[tuple[float, float]]) -> list[float]:
    """Per-point RDP importance (monotone). A point survives tolerance ``t``
    iff ``imp > t``; computed once per feature and reused for every zoom."""
    n = len(pts)
    imp = [0.0] * n
    if n == 0:
        return imp
    imp[0] = imp[-1] = INF
    stack = [(0, n - 1, INF)]
    while stack:
        lo, hi, par = stack.pop()
        if hi - lo < 2:
            continue
        x1, y1 = pts[lo]
        x2, y2 = pts[hi]
        dx, dy = x2 - x1, y2 - y1
        den = dx * dx + dy * dy
        best, idx = -1.0, lo + 1
        for i in range(lo + 1, hi):
            x, y = pts[i]
            if den == 0:
                d = math.hypot(x - x1, y - y1)
            else:
                t = ((x - x1) * dx + (y - y1) * dy) / den
                t = 0.0 if t < 0 else 1.0 if t > 1 else t
                d = math.hypot(x - (x1 + t * dx), y - (y1 + t * dy))
            if d > best:
                best, idx = d, i
        d = best if best < par else par
        imp[idx] = d
        stack.append((lo, idx, d))
        stack.append((idx, hi, d))
    return imp


# --- clipping (axis-aligned strips; axis 0 = x, 1 = y) ----------------------
def _lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def clip_lines(lines, axis, lo, hi):
    out = []
    for ln in lines:
        vs = [p[axis] for p in ln]
        if min(vs) >= lo and max(vs) <= hi:
            out.append(ln)
            continue
        if max(vs) < lo or min(vs) > hi:
            continue
        cur: list = []
        for i in range(len(ln) - 1):
            a, b = ln[i], ln[i + 1]
            av, bv = a[axis], b[axis]
            if (av < lo and bv < lo) or (av > hi and bv > hi):
                if cur:
                    out.append(cur)
                    cur = []
                continue
            t0, t1 = 0.0, 1.0
            d = bv - av
            if d != 0:
                ta, tb = (lo - av) / d, (hi - av) / d
                if ta > tb:
                    ta, tb = tb, ta
                t0, t1 = max(0.0, ta), min(1.0, tb)
            pa = a if t0 <= 0 else _lerp(a, b, t0)
            pb = b if t1 >= 1 else _lerp(a, b, t1)
            if t0 > 0 and cur:
                out.append(cur)
                cur = []
            if not cur:
                cur = [pa]
            cur.append(pb)
            if t1 < 1:
                out.append(cur)
                cur = []
        if cur:
            out.append(cur)
    return [l for l in out if len(l) >= 2]


def _isect(p, q, axis, v):
    t = (v - p[axis]) / (q[axis] - p[axis])
    return (v, p[1] + (q[1] - p[1]) * t) if axis == 0 else (p[0] + (q[0] - p[0]) * t, v)


def clip_rings(rings, axis, lo, hi):
    res = []
    for ring in rings:
        vs = [p[axis] for p in ring]
        if min(vs) >= lo and max(vs) <= hi:
            res.append(ring)
            continue
        if max(vs) < lo or min(vs) > hi:
            continue
        r = ring
        for bound, ge in ((lo, True), (hi, False)):
            if not r:
                break
            out = []
            prev = r[-1]
            pin = prev[axis] >= bound if ge else prev[axis] <= bound
            for cur in r:
                cin = cur[axis] >= bound if ge else cur[axis] <= bound
                if cin:
                    if not pin:
                        out.append(_isect(prev, cur, axis, bound))
                    out.append(cur)
                elif pin:
                    out.append(_isect(prev, cur, axis, bound))
                prev, pin = cur, cin
            r = out
        if len(r) >= 3:
            res.append(r)
    return res


# --- protobuf writer --------------------------------------------------------
def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _key(field: int, wt: int) -> bytes:
    return _varint(field << 3 | wt)


def _ld(field: int, data: bytes) -> bytes:
    return _key(field, 2) + _varint(len(data)) + data


def _zz(n: int) -> int:
    return (n << 1) ^ (n >> 63)


def _value(v) -> bytes:
    if isinstance(v, str):
        return _ld(1, v.encode("utf-8"))
    v = int(v)
    return _key(5, 0) + _varint(v) if v >= 0 else _key(6, 0) + _varint(_zz(v))


def enc_lines(lines) -> list[int]:
    out, cx, cy = [], 0, 0
    for ln in lines:
        x, y = ln[0]
        out += [1 | (1 << 3), _zz(x - cx), _zz(y - cy)]
        cx, cy = x, y
        out.append(2 | ((len(ln) - 1) << 3))
        for x, y in ln[1:]:
            out += [_zz(x - cx), _zz(y - cy)]
            cx, cy = x, y
    return out


def enc_rings(rings) -> list[int]:
    out, cx, cy = [], 0, 0
    for r in rings:
        x, y = r[0]
        out += [1 | (1 << 3), _zz(x - cx), _zz(y - cy)]
        cx, cy = x, y
        out.append(2 | ((len(r) - 1) << 3))
        for x, y in r[1:]:
            out += [_zz(x - cx), _zz(y - cy)]
            cx, cy = x, y
        out.append(7 | (1 << 3))
    return out


class Layer:
    __slots__ = ("name", "keys", "vals", "feats")

    def __init__(self, name: str):
        self.name, self.keys, self.vals, self.feats = name, {}, {}, []

    def add(self, fid: int, gtype: int, geom: list[int], tags: dict) -> None:
        tg = []
        for k, v in tags.items():
            ki = self.keys.get(k)
            if ki is None:
                ki = self.keys[k] = len(self.keys)
            vk = (v.__class__, v)
            vi = self.vals.get(vk)
            if vi is None:
                vi = self.vals[vk] = len(self.vals)
            tg += [ki, vi]
        self.feats.append((fid, gtype, tg, geom))

    def encode(self) -> bytes:
        out = bytearray(_key(15, 0) + _varint(2) + _ld(1, self.name.encode()))
        for fid, gt, tg, geom in self.feats:
            f = bytearray(_key(1, 0) + _varint(fid & 0xFFFFFFFFFFFFFFFF))
            if tg:
                f += _ld(2, b"".join(_varint(t) for t in tg))
            f += _key(3, 0) + _varint(gt)
            f += _ld(4, b"".join(_varint(g) for g in geom))
            out += _ld(2, bytes(f))
        for k in self.keys:
            out += _ld(3, k.encode())
        for _, v in self.vals:
            out += _ld(4, _value(v))
        out += _key(5, 0) + _varint(EXTENT)
        return bytes(out)


def encode_tile(layers: dict[str, Layer]) -> bytes:
    raw = b"".join(_ld(3, l.encode()) for l in layers.values() if l.feats)
    return gzip.compress(raw, 9, mtime=0)  # mtime=0 -> byte-identical tiles dedupe


# --- decoder (verification / tests) -----------------------------------------
def _rv(b, i):
    r = shift = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << shift
        if not c & 0x80:
            return r, i
        shift += 7


def _fields(b):
    i = 0
    while i < len(b):
        k, i = _rv(b, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = _rv(b, i)
        elif w == 2:
            n, i = _rv(b, i)
            v = b[i:i + n]
            i += n
        else:
            raise ValueError(f"unsupported wire type {w}")
        yield f, w, v


def _packed(b):
    i, out = 0, []
    while i < len(b):
        v, i = _rv(b, i)
        out.append(v)
    return out


def _geom(g):
    i, x, y, parts, cur = 0, 0, 0, [], None
    while i < len(g):
        c = g[i]
        i += 1
        cmd, cnt = c & 7, c >> 3
        if cmd == 7:
            cur.append(cur[0])
            continue
        for _ in range(cnt):
            x += (g[i] >> 1) ^ -(g[i] & 1)
            y += (g[i + 1] >> 1) ^ -(g[i + 1] & 1)
            i += 2
            if cmd == 1:
                cur = [(x, y)]
                parts.append(cur)
            else:
                cur.append((x, y))
    return parts


def decode_tile(data: bytes) -> list[dict]:
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    out = []
    for f, _, layer in _fields(data):
        if f != 3:
            continue
        name, keys, vals, feats = "", [], [], []
        for lf, _, lv in _fields(layer):
            if lf == 1:
                name = lv.decode()
            elif lf == 2:
                feats.append(lv)
            elif lf == 3:
                keys.append(lv.decode())
            elif lf == 4:
                for vf, _, vv in _fields(lv):
                    if vf == 1:
                        vals.append(vv.decode())
                    elif vf == 5:
                        vals.append(vv)
                    elif vf == 6:
                        vals.append((vv >> 1) ^ -(vv & 1))
        for fb in feats:
            fid, gt, tg, geom = 0, 0, [], []
            for ff, _, fv in _fields(fb):
                if ff == 1:
                    fid = fv
                elif ff == 2:
                    tg = _packed(fv)
                elif ff == 3:
                    gt = fv
                elif ff == 4:
                    geom = _packed(fv)
            out.append({"layer": name, "id": fid, "type": gt,
                        "tags": {keys[tg[j]]: vals[tg[j + 1]] for j in range(0, len(tg), 2)},
                        "geometry": _geom(geom)})
    return out
