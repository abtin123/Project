import 'dart:math' as math;

const double kDegToRad = math.pi / 180.0;
const double kRadToDeg = 180.0 / math.pi;

double mPerDegLat(double latDeg) {
  final p = latDeg * kDegToRad;
  return 111132.92 - 559.82 * math.cos(2 * p) + 1.175 * math.cos(4 * p);
}

double mPerDegLng(double latDeg) {
  final p = latDeg * kDegToRad;
  return 111412.84 * math.cos(p) - 93.5 * math.cos(3 * p);
}

double normDeg(double d) {
  final r = d % 360.0;
  return r < 0 ? r + 360.0 : r;
}

/// Smallest signed difference b - a in (-180, 180].
double angleDiffDeg(double a, double b) {
  var d = (b - a) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

double absAngleDiffDeg(double a, double b) => angleDiffDeg(a, b).abs();

double lerpAngleDeg(double a, double b, double t) =>
    normDeg(a + angleDiffDeg(a, b) * t);

double distanceM(double lat1, double lng1, double lat2, double lng2) {
  final mLat = mPerDegLat((lat1 + lat2) / 2);
  final mLng = mPerDegLng((lat1 + lat2) / 2);
  final dy = (lat2 - lat1) * mLat;
  final dx = (lng2 - lng1) * mLng;
  return math.sqrt(dx * dx + dy * dy);
}

double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final mLat = mPerDegLat((lat1 + lat2) / 2);
  final mLng = mPerDegLng((lat1 + lat2) / 2);
  final dy = (lat2 - lat1) * mLat;
  final dx = (lng2 - lng1) * mLng;
  return normDeg(math.atan2(dx, dy) * kRadToDeg);
}

/// Moves a point [meters] along [headingDeg] (clockwise from north).
({double lat, double lng}) offsetLatLng(
    double lat, double lng, double headingDeg, double meters) {
  final h = headingDeg * kDegToRad;
  final dn = math.cos(h) * meters;
  final de = math.sin(h) * meters;
  return (
    lat: lat + dn / mPerDegLat(lat),
    lng: lng + de / mPerDegLng(lat),
  );
}
