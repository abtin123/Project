/// Filtered vehicle state delivered to the UI.
class VehiclePosition {
  final double lat;
  final double lng;
  final double headingDeg;
  final double speedKmh;
  final double accuracyM;
  final bool isEstimated;

  const VehiclePosition({
    required this.lat,
    required this.lng,
    required this.headingDeg,
    required this.speedKmh,
    required this.accuracyM,
    this.isEstimated = false,
  });
}
