"""Compact ABM route-geometry codec used by builder and runtime readers.

Format: delta encoded integer lon/lat pairs at 1e-5 degree precision,
ZigZag signed integers, then unsigned Varints. Geometry is stored per OSM way
in map.sqlite and is fetched only after route edge IDs are known.
"""
SCALE = 100000

def _write_varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7f) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)

def _zigzag(value: int) -> int:
    return (value << 1) ^ (value >> 63)

def encode_geometry(points):
    out = bytearray(); px = py = 0
    for lon, lat in points:
        x = int(round(float(lon) * SCALE)); y = int(round(float(lat) * SCALE))
        out += _write_varint(_zigzag(x - px)); out += _write_varint(_zigzag(y - py))
        px, py = x, y
    return bytes(out)

def _read_varint(data: bytes, offset: int):
    value = shift = 0
    while True:
        if offset >= len(data):
            raise ValueError("truncated ABM geometry")
        b = data[offset]; offset += 1
        value |= (b & 0x7f) << shift
        if not b & 0x80:
            return value, offset
        shift += 7
        if shift > 63:
            raise ValueError("invalid ABM geometry varint")

def _unzigzag(value: int) -> int:
    return (value >> 1) ^ -(value & 1)

def decode_geometry(data: bytes):
    px = py = 0
    out = []
    off = 0
    while off < len(data):
        vx, off = _read_varint(data, off)
        vy, off = _read_varint(data, off)
        px += _unzigzag(vx)
        py += _unzigzag(vy)
        out.append((px / SCALE, py / SCALE))
    return out
