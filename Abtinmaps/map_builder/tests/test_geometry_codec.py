from routing.geometry import decode_geometry
from routing.graph_builder import encode_geometry

def test_geometry_codec_roundtrip():
    points = [(51.4, 35.7), (51.40123, 35.70111), (51.40300, 35.70222)]
    assert decode_geometry(encode_geometry(points)) == points
