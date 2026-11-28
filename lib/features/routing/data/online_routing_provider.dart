import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../core/geo/geo_types.dart';
import '../domain/road_block.dart';
import 'routing_instruction_localizer.dart';
import '../../../core/localization/app_localizations.dart';
import 'routing_provider.dart';
import 'routing_service.dart';

class OnlineRoutingProvider implements RoutingProvider {
  OnlineRoutingProvider({
    http.Client? client,
    this.endpoint = defaultEndpoint,
    this.requestTimeout = const Duration(seconds: 12),
    this.languageCode = _defaultLanguageCode,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const String defaultEndpoint = 'https://router.project-osrm.org';
  static String _defaultLanguageCode() => 'fa';

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;
  final Duration requestTimeout;
  final String Function() languageCode;

  @override
  RoutingEngine get engine => RoutingEngine.online;

  @override
  String get displayName => 'نقشه و مسیریابی آنلاین';

  @override
  bool get isOffline => false;

  @override
  String? lastError;

  @override
  Future<bool> isReady() async => true;

  @override
  Future<RouteInfo?> calculateRoute({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    List<String> exclude = const [],
    List<RoadBlock> roadBlocks = const <RoadBlock>[],
  }) async {
    final routes = await calculateRoutes(
      origin: origin,
      destination: destination,
      offlineOnly: offlineOnly,
      exclude: exclude,
      roadBlocks: roadBlocks,
    );
    return routes.isEmpty ? null : routes.first;
  }

  Future<List<RouteInfo>> calculateRoutes({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    List<String> exclude = const [],
    List<RoadBlock> roadBlocks = const <RoadBlock>[],
  }) async {
    final routes = await _fetchRoutes(
      origin: origin,
      destination: destination,
      offlineOnly: offlineOnly,
      exclude: exclude,
    );
    if (roadBlocks.isEmpty || routes.isEmpty) return routes;

    // The public OSRM server cannot avoid an area, so: first look for an
    // alternative that does not use the closed stretch, then force a detour
    // through via-points on both sides of it.
    final clean = <RouteInfo>[
      for (final r in routes)
        if (!RoadBlock.hits(r.geometry, roadBlocks)) r,
    ];
    if (clean.isNotEmpty) return clean;

    final candidates = <LatLng>[
      for (final b in roadBlocks) ...RoadBlock.detourCandidates(b),
    ];
    final direct = routes.first;
    RouteInfo? best;
    for (var i = 0; i < candidates.length && i < 12; i += 4) {
      final batch = candidates.skip(i).take(4).toList();
      final results = await Future.wait(<Future<List<RouteInfo>>>[
        for (final via in batch)
          _fetchRoutes(
            origin: origin,
            destination: destination,
            offlineOnly: offlineOnly,
            exclude: exclude,
            via: via,
            alternatives: false,
          ),
      ]);
      for (final list in results) {
        for (final r in list) {
          if (RoadBlock.hits(r.geometry, roadBlocks)) continue;
          if (r.distanceKm > direct.distanceKm * 3 + 5) continue;
          if (best == null || r.durationMin < best.durationMin) best = r;
        }
      }
      if (best != null) break;
    }
    if (best == null) {
      lastError = 'مسیر جایگزین برای دور زدن بخش بسته پیدا نشد.';
      return const [];
    }
    return <RouteInfo>[best];
  }

  Future<List<RouteInfo>> _fetchRoutes({
    required LatLng origin,
    required LatLng destination,
    bool offlineOnly = false,
    List<String> exclude = const [],
    LatLng? via,
    bool alternatives = true,
  }) async {
    lastError = null;
    if (offlineOnly) {
      lastError = AppStrings.getForLanguage(
          languageCode(), 'route_error_offline_unavailable');
      return const [];
    }
    if (!_isValidCoordinate(origin) || !_isValidCoordinate(destination)) {
      lastError = AppStrings.getForLanguage(
          languageCode(), 'route_error_invalid_coordinates');
      return const [];
    }

    final coordinates =
        '${origin.longitude.toStringAsFixed(6)},${origin.latitude.toStringAsFixed(6)};'
        '${via == null ? '' : '${via.longitude.toStringAsFixed(6)},${via.latitude.toStringAsFixed(6)};'}'
        '${destination.longitude.toStringAsFixed(6)},${destination.latitude.toStringAsFixed(6)}';

    final km = _straightKm(origin, destination);
    final perAttempt = _timeoutFor(km);
    final clock = Stopwatch()..start();
    const overall = Duration(seconds: 100);
    final bases = <String>[
      for (final e in <String>[
        endpoint,
        if (endpoint == defaultEndpoint) ...fallbackEndpoints,
      ])
        e.endsWith('/') ? e.substring(0, e.length - 1) : e,
    ];
    // Long trips: skip alternatives (much heavier on the public server).
    final altModes = alternatives && km <= 150 ? <bool>[true, false] : <bool>[false];
    var useExclude = exclude.isNotEmpty;
    String? error;

    for (final base in bases) {
      for (final alt in altModes) {
        final remaining = overall - clock.elapsed;
        if (remaining <= const Duration(seconds: 3)) {
          lastError = error ??
              AppStrings.getForLanguage(languageCode(), 'route_error_timeout');
          return const [];
        }
        final timeout = perAttempt < remaining ? perAttempt : remaining;
        final uri = Uri.parse('$base/route/v1/driving/$coordinates').replace(
          queryParameters: {
            'alternatives': alt ? 'true' : 'false',
            'steps': 'true',
            'geometries': 'geojson',
            'overview': 'full',
            if (useExclude) 'exclude': exclude.join(','),
          },
        );
        var retrySameBase = true;
        try {
          final response = await _client.get(
            uri,
            headers: const {
              'User-Agent': 'AbtinMaps/0.1 (online-routing)',
              'Accept': 'application/json',
            },
          ).timeout(timeout);
          if (response.statusCode != 200) {
            if (useExclude && response.statusCode < 500) {
              // Server rejected the exclude class: drop it and redo this try.
              useExclude = false;
              return _fetchRoutes(
                  origin: origin,
                  destination: destination,
                  offlineOnly: offlineOnly,
                  via: via,
                  alternatives: alternatives);
            }
            error = AppStrings.getForLanguage(languageCode(), 'route_error_http')
                .replaceAll('{code}', '${response.statusCode}');
            if (response.statusCode == 400) retrySameBase = false;
          } else {
            final bytes = response.bodyBytes;
            final Object? decoded = bytes.length > 150000
                ? await Isolate.run(() => jsonDecode(utf8.decode(bytes)))
                : jsonDecode(utf8.decode(bytes));
            if (decoded is! Map) {
              error = AppStrings.getForLanguage(
                  languageCode(), 'route_error_unreadable_response');
            } else if (decoded['code'] != 'Ok') {
              if (useExclude) {
                useExclude = false;
                return _fetchRoutes(
                    origin: origin,
                    destination: destination,
                    offlineOnly: offlineOnly,
                    via: via,
                    alternatives: alternatives);
              }
              error = _osrmErrorMessage(
                  decoded['code']?.toString(), languageCode());
              retrySameBase = false; // NoRoute/NoSegment: same data, same result
            } else {
              final routesJson = decoded['routes'];
              final routes = <RouteInfo>[];
              if (routesJson is List) {
                for (final routeJson in routesJson) {
                  if (routeJson is! Map) continue;
                  final route =
                      _parseRoute(Map<String, dynamic>.from(routeJson));
                  if (route != null) routes.add(route);
                }
              }
              if (routes.isNotEmpty) {
                lastError = null;
                return routes;
              }
              error = AppStrings.getForLanguage(
                  languageCode(), 'route_error_online_not_found');
            }
          }
        } on TimeoutException {
          error =
              AppStrings.getForLanguage(languageCode(), 'route_error_timeout');
        } on FormatException {
          error = AppStrings.getForLanguage(
              languageCode(), 'route_error_invalid_response');
        } on http.ClientException {
          error = AppStrings.getForLanguage(
              languageCode(), 'route_error_connection');
        } catch (_) {
          error = AppStrings.getForLanguage(
              languageCode(), 'route_error_unexpected');
        }
        if (!retrySameBase) break;
      }
    }
    lastError = error ??
        AppStrings.getForLanguage(languageCode(), 'route_error_unexpected');
    return const [];
  }

  static const List<String> fallbackEndpoints = <String>[
    'https://routing.openstreetmap.de/routed-car',
  ];

  Duration _timeoutFor(double km) {
    final base = requestTimeout.inSeconds;
    final s = (base + km / 12).ceil();
    return Duration(seconds: s.clamp(base, 60));
  }

  static double _straightKm(LatLng a, LatLng b) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(b.latitude - a.latitude);
    final dLon = rad(b.longitude - a.longitude);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(a.latitude)) *
            math.cos(rad(b.latitude)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }

  RouteInfo? _parseRoute(Map<String, dynamic> route) {
    final geometry = route['geometry'];
    if (geometry is! Map) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) return null;

    final points = <LatLng>[];
    for (final coordinate in coordinates) {
      if (coordinate is! List || coordinate.length < 2) continue;
      final lng = _asDouble(coordinate[0]);
      final lat = _asDouble(coordinate[1]);
      if (lat == null || lng == null || !lat.isFinite || !lng.isFinite)
        continue;
      points.add(LatLng(lat, lng));
    }
    if (points.length < 2) return null;

    final distanceM = _asDouble(route['distance']) ?? 0;
    final durationS = _asDouble(route['duration']) ?? 0;
    return RouteInfo(
      geometry: points,
      distanceKm: distanceM / 1000,
      durationMin: durationS / 60,
      instructions: _parseInstructions(route['legs'], languageCode()),
    );
  }

  List<RouteInstruction> _parseInstructions(
      Object? legsJson, String languageCode) {
    if (legsJson is! List) return const [];
    final instructions = <RouteInstruction>[];
    for (var legIndex = 0; legIndex < legsJson.length; legIndex++) {
      final legJson = legsJson[legIndex];
      if (legJson is! Map) continue;
      final stepsJson = legJson['steps'];
      if (stepsJson is! List) continue;
      for (final stepJson in stepsJson) {
        if (stepJson is! Map) continue;
        final step = Map<String, dynamic>.from(stepJson);
        final maneuver = step['maneuver'];
        if (maneuver is! Map) continue;
        final maneuverMap = Map<String, dynamic>.from(maneuver);
        // Detour via-points split the route into legs: the "arrive" of a middle
        // leg and the "depart" of the next one are not real instructions.
        final stepType = maneuverMap['type']?.toString();
        if (legIndex < legsJson.length - 1 && stepType == 'arrive') continue;
        if (legIndex > 0 && stepType == 'depart') continue;
        final location = maneuverMap['location'];
        if (location is! List || location.length < 2) continue;
        final lng = _asDouble(location[0]);
        final lat = _asDouble(location[1]);
        if (lat == null || lng == null || !lat.isFinite || !lng.isFinite)
          continue;
        final rawType = maneuverMap['type']?.toString() ?? 'turn';
        final rawModifier = maneuverMap['modifier']?.toString();
        final exit = maneuverMap['exit'] is num
            ? (maneuverMap['exit'] as num).toInt()
            : null;
        final geometryPoints = _stepCoordinates(step);
        final inferredModifier = _normalizedOnlineModifier(
          type: rawType,
          modifier: rawModifier,
          geometry: geometryPoints,
        );
        final type = inferredModifier == 'uturn' ? 'uturn' : rawType;
        final modifier = inferredModifier;
        if (_isNoopStep(rawType, rawModifier, modifier)) continue;
        final roadName = step['name']?.toString().trim();
        LatLng? maneuverEndLocation;
        if (geometryPoints.isNotEmpty) {
          maneuverEndLocation = geometryPoints.last;
        }

        final roundabout = (rawType == 'roundabout' || rawType == 'rotary')
            ? _analyzeOnlineRoundabout(step, maneuverMap, geometryPoints)
            : const _OnlineRoundaboutData.empty();
        instructions.add(
          RouteInstruction(
            text: _instructionText(
              type: type,
              modifier: modifier,
              roadName: roadName?.isEmpty ?? true ? null : roadName,
              exit: exit,
              languageCode: languageCode,
            ),
            distanceMeters: _asDouble(step['distance']) ?? 0,
            location: LatLng(lat, lng),
            type: type,
            modifier: modifier,
            exit: exit,
            roundaboutExitCount: roundabout.exitCount,
            roundaboutBranchAngles: roundabout.branchAngles,
            roundaboutEntranceAngles: roundabout.entranceAngles,
            roundaboutExitAngles: roundabout.exitAngles,
            roundaboutActiveExitAngle: roundabout.activeExitAngle,
            roundaboutAngleDegrees: roundabout.activeEntranceAngle,
            maneuverEndLocation: maneuverEndLocation,
            maneuverAngleDegrees: _maneuverAngleFromGeometry(geometryPoints),
          ),
        );
      }
    }
    return instructions;
  }


  static String _normModifier(String? v) =>
      (v ?? '').trim().toLowerCase().replaceAll('-', ' ').replaceAll('_', ' ');

  /// مرحله‌هایی که فقط «ادامه‌ی همان مسیر» هستند (تغییر نام خیابان، continue و
  /// ...) دستور راهنمایی نمی‌شوند تا در مسیر مستقیم صوت و کارت تکرار نشود.
  bool _isNoopStep(String rawType, String? rawModifier, String? finalModifier) {
    final type = rawType.trim().toLowerCase();
    if (type != 'new name' &&
        type != 'continue' &&
        type != 'notification' &&
        type != 'turn') {
      return false;
    }
    final raw = _normModifier(rawModifier);
    final fin = _normModifier(finalModifier);
    final slight = fin.startsWith('slight');
    if (raw.isNotEmpty && raw != 'straight') {
      // خودِ سرور جهت واقعی داده؛ فقط new name/notification با slight حذف شود.
      return (type == 'new name' || type == 'notification') && slight;
    }
    // سرور گفته مستقیم است: فقط اگر هندسه پیچ واقعی (≥۵۵°) نشان داد نگه دار.
    return fin.isEmpty || fin == 'straight' || slight;
  }

  List<LatLng> _stepCoordinates(Map<String, dynamic> step) {
    final geometry = step['geometry'];
    if (geometry is! Map) return const [];
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) return const [];
    final out = <LatLng>[];
    for (final raw in coordinates) {
      if (raw is! List || raw.length < 2) continue;
      final lng = _asDouble(raw[0]);
      final lat = _asDouble(raw[1]);
      if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) continue;
      out.add(LatLng(lat, lng));
    }
    return out;
  }

  double? _maneuverAngleFromGeometry(List<LatLng> geometry) {
    if (geometry.length < 4) return null;
    final firstEnd = math.min(geometry.length - 1, 2);
    final lastStart = math.max(0, geometry.length - 3);
    final first = _bearing(geometry[0], geometry[firstEnd]);
    final last = _bearing(geometry[lastStart], geometry.last);
    return _signedAngle(last - first);
  }

  String? _normalizedOnlineModifier({
    required String type,
    required String? modifier,
    required List<LatLng> geometry,
  }) {
    final normalized = (modifier ?? '')
        .trim()
        .toLowerCase()
        .replaceAll('-', ' ')
        .replaceAll('_', ' ');
    if (type == 'roundabout' || type == 'rotary') return modifier;
    if (normalized.contains('uturn') || normalized.contains('u turn')) {
      return 'uturn';
    }
    if (geometry.length >= 4 &&
        !normalized.contains('sharp') &&
        (type == 'turn' || type == 'continue' || type == 'new name' || type == 'end of road')) {
      final firstEnd = math.min(geometry.length - 1, 2);
      final lastStart = math.max(0, geometry.length - 3);
      final first = _bearing(geometry[0], geometry[firstEnd]);
      final last = _bearing(geometry[lastStart], geometry.last);
      final delta = _signedAngle(last - first).abs();
      if (delta >= 150) return 'uturn';
    }
    final inferred = _inferShallowModifier(geometry);
    if (inferred != null &&
        (normalized.isEmpty || normalized == 'straight') &&
        inferred != 'straight') {
      return inferred;
    }
    if (modifier == null || normalized.isEmpty) return inferred;
    return modifier;
  }

  String? _inferShallowModifier(List<LatLng> geometry) {
    if (geometry.length < 4) return null;
    final firstEnd = math.min(geometry.length - 1, 2);
    final lastStart = math.max(0, geometry.length - 3);
    final first = _bearing(geometry[0], geometry[firstEnd]);
    final last = _bearing(geometry[lastStart], geometry.last);
    final delta = _signedAngle(last - first);
    final a = delta.abs();
    if (a >= 150) return 'uturn';
    if (a >= 55) return delta > 0 ? 'right' : 'left';
    if (a >= 5) return delta > 0 ? 'slight right' : 'slight left';
    return 'straight';
  }

  double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dl = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dl) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  double _signedAngle(double angle) {
    var a = angle % 360;
    if (a > 180) a -= 360;
    if (a < -180) a += 360;
    return a;
  }

  _OnlineRoundaboutData _analyzeOnlineRoundabout(
    Map<String, dynamic> step,
    Map<String, dynamic> maneuver,
    List<LatLng> geometry,
  ) {
    final rawIntersections = step['intersections'];
    if (rawIntersections is! List) {
      return const _OnlineRoundaboutData.empty();
    }

    final angles = <double>[];
    final entrances = <double>[];
    final exits = <double>[];
    double? activeExit;
    double? activeEntrance;

    void addUnique(List<double> target, double value) {
      final normalized = (value % 360 + 360) % 360;
      for (final old in target) {
        var d = (old - normalized).abs();
        if (d > 180) d = 360 - d;
        if (d <= 7.5) return;
      }
      target.add(normalized);
    }

    for (var i = 0; i < rawIntersections.length; i++) {
      final raw = rawIntersections[i];
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final bearings = m['bearings'];
      if (bearings is! List || bearings.isEmpty) continue;
      final entry = m['entry'] is List ? List<dynamic>.from(m['entry']) : const <dynamic>[];
      final inIndex = m['in'] is num ? (m['in'] as num).toInt() : -1;
      final outIndex = m['out'] is num ? (m['out'] as num).toInt() : -1;

      if (i == 0 && inIndex >= 0 && inIndex < bearings.length) {
        final b = _asDouble(bearings[inIndex]);
        if (b != null) {
          addUnique(angles, b);
          addUnique(entrances, b);
          activeEntrance = b;
        }
      }

      for (var j = 0; j < bearings.length; j++) {
        if (j == inIndex || j == outIndex) continue;
        final b = _asDouble(bearings[j]);
        if (b == null) continue;
        final canExit = j < entry.length ? entry[j] == true : true;
        addUnique(angles, b);
        if (canExit) addUnique(exits, b);
        if (j < entry.length && entry[j] == true) addUnique(entrances, b);
      }

      if (i == rawIntersections.length - 1 && outIndex >= 0 && outIndex < bearings.length) {
        final b = _asDouble(bearings[outIndex]);
        if (b != null) {
          addUnique(angles, b);
          addUnique(exits, b);
          activeExit = (maneuver['exit'] is num || geometry.length >= 2) ? b : activeExit;
        }
      }
    }

    if (activeExit == null && geometry.length >= 2) {
      activeExit = _bearing(geometry[geometry.length - 2], geometry.last);
      addUnique(angles, activeExit);
      addUnique(exits, activeExit);
    }

    final maneuverExit = maneuver['exit'] is num
        ? (maneuver['exit'] as num).toInt()
        : null;
    final orderedExits = [...exits];
    final exitCount = orderedExits.length;
    if (angles.length < 2) return const _OnlineRoundaboutData.empty();

    return _OnlineRoundaboutData(
      exitCount: exitCount == 0 ? maneuverExit : exitCount,
      branchAngles: List.unmodifiable(angles),
      entranceAngles: List.unmodifiable(entrances),
      exitAngles: List.unmodifiable(exits),
      activeExitAngle: activeExit,
      activeEntranceAngle: activeEntrance,
    );
  }

  String _instructionText({
    required String type,
    required String? modifier,
    required String? roadName,
    required int? exit,
    required String languageCode,
  }) =>
      RoutingInstructionLocalizer.text(
        languageCode: languageCode,
        type: type,
        modifier: modifier,
        roadName: roadName,
        exit: exit,
      );

  String _osrmErrorMessage(String? code, String languageCode) => switch (code) {
        'NoRoute' => AppStrings.getForLanguage(
            languageCode, 'route_error_online_not_found'),
        'NoSegment' =>
          AppStrings.getForLanguage(languageCode, 'route_error_no_segment'),
        'TooBig' =>
          AppStrings.getForLanguage(languageCode, 'route_error_too_big'),
        _ =>
          AppStrings.getForLanguage(languageCode, 'route_error_online_failed'),
      };

  bool _isValidCoordinate(LatLng point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude.abs() <= 90 &&
      point.longitude.abs() <= 180;

  double? _asDouble(Object? value) => value is num ? value.toDouble() : null;

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class _OnlineRoundaboutData {
  const _OnlineRoundaboutData({
    required this.exitCount,
    required this.branchAngles,
    required this.entranceAngles,
    required this.exitAngles,
    required this.activeExitAngle,
    required this.activeEntranceAngle,
  });

  const _OnlineRoundaboutData.empty()
      : exitCount = null,
        branchAngles = const [],
        entranceAngles = const [],
        exitAngles = const [],
        activeExitAngle = null,
        activeEntranceAngle = null;

  final int? exitCount;
  final List<double> branchAngles;
  final List<double> entranceAngles;
  final List<double> exitAngles;
  final double? activeExitAngle;
  final double? activeEntranceAngle;
}

