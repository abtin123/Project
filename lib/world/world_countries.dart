import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

class WorldCountries {
  WorldCountries._();

  static const String assetPath = 'assets/world/world_boundaries.v1.json.gz';

  static Map<String, dynamic>? _cached;
  static Future<Map<String, dynamic>>? _loading;

  static Future<Map<String, dynamic>> load() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load().then((value) {
      _cached = value;
      _loading = null;
      return value;
    });
  }

  static Future<Map<String, dynamic>> _load() async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return compute(_decode, bytes);
  }

  static Map<String, dynamic> _decode(Uint8List gzipped) {
    final jsonBytes = GZipDecoder().decodeBytes(gzipped, verify: false);
    final raw = jsonDecode(utf8.decode(jsonBytes));
    if (raw is! Map || raw['b'] is! List) {
      return {'type': 'FeatureCollection', 'features': <dynamic>[]};
    }
    final scale = (raw['s'] as num?)?.toDouble() ?? 10000.0;
    final countries = raw['b'] as List;

    final features = <dynamic>[];
    for (final rawCountry in countries) {
      if (rawCountry is! List) continue;
      final polygons = <dynamic>[];
      for (final rawRing in rawCountry) {
        if (rawRing is! List || rawRing.length < 3) continue;
        final ring = _decodeRing(rawRing, scale);
        if (ring.length < 4) continue;
        polygons.add([ring]);
      }
      if (polygons.isEmpty) continue;
      features.add({
        'type': 'Feature',
        'properties': const <String, dynamic>{},
        'geometry': {'type': 'MultiPolygon', 'coordinates': polygons},
      });
    }
    return {'type': 'FeatureCollection', 'features': features};
  }

  static List<List<double>> _decodeRing(List rawRing, double scale) {
    final ring = <List<double>>[];
    var x = 0;
    var y = 0;
    for (var i = 0; i < rawRing.length; i++) {
      final point = rawRing[i];
      if (point is! List || point.length < 2) continue;
      final dx = (point[0] as num).toInt();
      final dy = (point[1] as num).toInt();
      if (i == 0) {
        x = dx;
        y = dy;
      } else {
        x += dx;
        y += dy;
      }
      ring.add([x / scale, y / scale]);
    }
    if (ring.isEmpty) return ring;
    final first = ring.first;
    final last = ring.last;
    if (first[0] != last[0] || first[1] != last[1]) {
      ring.add(List<double>.from(first));
    }
    return ring;
  }
}
