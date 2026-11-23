import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

String googleMapsLocationUri({required double latitude, required double longitude}) {
  if (!latitude.isFinite || latitude < -90 || latitude > 90) {
    throw ArgumentError.value(latitude, 'latitude', 'must be between -90 and 90');
  }
  if (!longitude.isFinite || longitude < -180 || longitude > 180) {
    throw ArgumentError.value(
        longitude, 'longitude', 'must be between -180 and 180');
  }
  return Uri.https('www.google.com', '/maps/search/', <String, String>{
    'api': '1',
    'query': '${latitude.toString()},${longitude.toString()}',
  }).toString();
}

String geoLocationUri({required double latitude, required double longitude}) {
  if (!latitude.isFinite || latitude < -90 || latitude > 90) {
    throw ArgumentError.value(latitude, 'latitude', 'must be between -90 and 90');
  }
  if (!longitude.isFinite || longitude < -180 || longitude > 180) {
    throw ArgumentError.value(
        longitude, 'longitude', 'must be between -180 and 180');
  }
  return 'geo:${latitude.toString()},${longitude.toString()}';
}

class ShareService {
  Future<void> share(String text, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  Future<void> shareCoordinates({
    required double latitude,
    required double longitude,
  }) async {
    await share(googleMapsLocationUri(
      latitude: latitude,
      longitude: longitude,
    ));
  }

}

final shareServiceProvider = Provider<ShareService>((ref) {
  return ShareService();
});
