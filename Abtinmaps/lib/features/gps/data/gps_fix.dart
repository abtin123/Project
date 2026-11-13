enum FixSource { gps, network, fused }

/// One raw location sample coming from the native layer.
class RawFix {
  const RawFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.elapsedMs,
    required this.source,
    this.speedMs,
    this.speedAccMs,
    this.bearingDeg,
    this.bearingAccDeg,
    this.altitudeM,
    this.cached = false,
    this.isMock = false,
  });

  final double lat;
  final double lng;
  final double accuracyM;
  final double? speedMs;
  final double? speedAccMs;
  final double? bearingDeg;
  final double? bearingAccDeg;
  final double? altitudeM;

  /// Monotonic milliseconds (Android elapsedRealtime / iOS uptime).
  final int elapsedMs;
  final FixSource source;
  final bool cached;
  final bool isMock;

  bool get isGnssQuality => source != FixSource.network;

  static RawFix? fromMap(Map<dynamic, dynamic> m) {
    double? d(String k) => (m[k] as num?)?.toDouble();
    final lat = d('lat');
    final lng = d('lng');
    final acc = d('acc');
    final el = (m['elapsedMs'] as num?)?.toInt();
    if (lat == null || lng == null || acc == null || el == null) return null;
    if (!lat.isFinite || !lng.isFinite) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    if (lat == 0 && lng == 0) return null;
    final src = switch (m['source']) {
      'gps' => FixSource.gps,
      'network' => FixSource.network,
      _ => FixSource.fused,
    };
    return RawFix(
      lat: lat,
      lng: lng,
      accuracyM: acc,
      elapsedMs: el,
      source: src,
      speedMs: d('speed'),
      speedAccMs: d('speedAcc'),
      bearingDeg: d('bearing'),
      bearingAccDeg: d('bearingAcc'),
      altitudeM: d('alt'),
      cached: m['cached'] == true,
      isMock: m['mock'] == true,
    );
  }
}
