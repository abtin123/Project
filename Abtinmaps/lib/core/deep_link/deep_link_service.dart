import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DeepLinkDestination {
  final double lat;
  final double lng;
  final String? label;

  const DeepLinkDestination({required this.lat, required this.lng, this.label});
}

class DeepLinkService {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  final _controller = StreamController<DeepLinkDestination>.broadcast();

  Stream<DeepLinkDestination> get destinations => _controller.stream;

  Future<void> init() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handle(initial);
    } catch (_) {
    }

    _sub = _appLinks.uriLinkStream.listen(
      _handle,
      onError: (_) {},
    );
  }

  void _handle(Uri uri) {
    final destination = _parseDestination(uri);
    if (destination != null) _controller.add(destination);
  }

  DeepLinkDestination? _parseDestination(Uri uri) {
    double? lat;
    double? lng;
    String? label;

    if (uri.scheme == 'abtin' && uri.host == 'navigate') {
      final coords = _parseCoordinatePair(uri.queryParameters['lat'] == null
              ? ''
              : '${uri.queryParameters['lat']},${uri.queryParameters['lng'] ?? ''}') ??
          _parseCoordinatePair(uri.queryParameters['q'] ?? '');
      lat = coords?.$1;
      lng = coords?.$2;
      label = uri.queryParameters['label'] ?? uri.queryParameters['q'];
    } else if (uri.scheme == 'geo') {
      final q = uri.queryParameters['q'];
      final qResult = _parseCoordinateAndLabel(q ?? '');
      final pathResult = _parseCoordinateAndLabel(uri.path);
      final usePath = pathResult != null &&
          !(pathResult.$1 == 0.0 && pathResult.$2 == 0.0 && qResult != null);
      final result = usePath ? pathResult : qResult ?? pathResult;
      lat = result?.$1;
      lng = result?.$2;
      label = result?.$3;
    } else if (uri.scheme == 'google.navigation') {
      final raw = uri.queryParameters['q'] ?? uri.path;
      final result = _parseCoordinateAndLabel(raw);
      lat = result?.$1;
      lng = result?.$2;
      label = result?.$3 ?? (result == null ? raw : null);
    } else if (uri.scheme == 'https' && _isMapsHost(uri.host)) {
      final raw = uri.queryParameters['destination'] ??
          uri.queryParameters['query'] ??
          uri.queryParameters['q'];
      final result = _parseCoordinateAndLabel(raw ?? '');
      lat = result?.$1;
      lng = result?.$2;
      label = result?.$3 ?? (result == null ? raw : null);
    }

    if (lat == null ||
        lng == null ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      return null;
    }

    if (lat == 0.0 && lng == 0.0) return null;

    return DeepLinkDestination(lat: lat, lng: lng, label: _cleanLabel(label));
  }

  bool _isMapsHost(String host) {
    final h = host.toLowerCase();
    return h == 'www.google.com' ||
        h == 'google.com' ||
        h == 'maps.google.com' ||
        h == 'maps.app.goo.gl';
  }

  (double, double, String?)? _parseCoordinateAndLabel(String value) {
    if (value.isEmpty) return null;
    final match = RegExp(
      r'(-?\d+(?:\.\d+)?)\s*[,;]\s*(-?\d+(?:\.\d+)?)(?:\s*\(([^)]*)\))?',
    ).firstMatch(value);
    if (match == null) return null;
    return (
      double.parse(match.group(1)!),
      double.parse(match.group(2)!),
      match.group(3),
    );
  }

  (double, double)? _parseCoordinatePair(String value) {
    final result = _parseCoordinateAndLabel(value);
    if (result == null) return null;
    return (result.$1, result.$2);
  }

  String? _cleanLabel(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}

final deepLinkServiceProvider = Provider<DeepLinkService>((ref) {
  final service = DeepLinkService();
  service.init();
  ref.onDispose(service.dispose);
  return service;
});

final deepLinkDestinationProvider = StreamProvider<DeepLinkDestination>((ref) {
  return ref.watch(deepLinkServiceProvider).destinations;
});
