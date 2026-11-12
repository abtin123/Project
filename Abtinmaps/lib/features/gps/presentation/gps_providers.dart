import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/permissions/location_permission_flow.dart';
import '../../../shared/providers/abtinmap_providers.dart';
import '../data/location_repository.dart';
import '../data/location_service.dart';
import '../data/gps_debug.dart';
import 'last_location_providers.dart';
import 'navigation_position_controller.dart';

final locationServiceProvider = Provider<LocationService>((ref) {
  final service = LocationService();
  GpsDebug.log('provider', 'locationServiceProvider created');
  ref.onDispose(() {
    GpsDebug.log('provider', 'locationServiceProvider DISPOSED');
    service.dispose();
  });
  return service;
});

final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  final service = ref.watch(locationServiceProvider);
  return LocationRepository(service);
});

final locationLifecycleTickProvider = StateProvider<int>((ref) => 0);

final locationReadinessProvider =
    StreamProvider<LocationReadiness>((ref) async* {
  final locationService = ref.read(locationServiceProvider);
  bool serviceStarted = false;

  ref.onDispose(() => GpsDebug.log('provider', 'locationReadinessProvider DISPOSED'));

  Future<LocationReadiness> reportAndMaybeStart(LocationReadiness r) async {
    GpsDebug.log('readiness',
        '$r serviceStarted=$serviceStarted svcState=${locationService.state.name}');
    if (r == LocationReadiness.ready && !serviceStarted) {
      serviceStarted = true;
      locationService.start();
    } else if (r == LocationReadiness.ready) {
      // اگر سرویس بعد از قطع/وصل شدن GPS مرده باشد، ensureAlive دوباره بالایش می‌آورد.
      locationService.ensureAlive();
    }
    return r;
  }

  yield await reportAndMaybeStart(await LocationPermissionFlow.ensureReady());

  final serviceStatusStream = Geolocator.getServiceStatusStream().map((s) {
    GpsDebug.log('svcStatus', s.name);
    return s;
  });

  final lifecycleStream =
      ref.watch(locationLifecycleTickProvider.notifier).stream.map((t) {
    GpsDebug.log('lifecycle', 'tick=$t');
    return t;
  });

  await for (final _ in _merge(serviceStatusStream, lifecycleStream)) {
    yield await reportAndMaybeStart(
      await LocationPermissionFlow.checkStatusAndRetryIfDenied(),
    );
  }
});

final retryLocationPermissionProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    await LocationPermissionFlow.retryFromUserTap();
    ref.read(locationLifecycleTickProvider.notifier).state++;
  };
});

Stream<void> _merge(Stream<ServiceStatus> a, Stream<int> b) {
  final controller = StreamController<void>();
  final subA = a.listen((_) => controller.add(null));
  final subB = b.listen((_) => controller.add(null));
  controller.onCancel = () {
    subA.cancel();
    subB.cancel();
  };
  return controller.stream;
}

final vehiclePositionProvider = StreamProvider<VehiclePosition>((ref) {
  ref.listen(locationReadinessProvider, (_, __) {});
  final stream = ref.watch(locationServiceProvider).stream;
  GpsDebug.log('provider', 'vehiclePositionProvider created');
  ref.onDispose(() => GpsDebug.log('provider', 'vehiclePositionProvider DISPOSED'));

  DateTime lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  final repo = ref.read(lastLocationRepositoryProvider);
  final broadcast = stream.asBroadcastStream();
  final persistenceSub = broadcast.listen((pos) {
    GpsDebug.count('provider.pos');
    GpsDebug.lastProviderAt = DateTime.now();
    final now = DateTime.now();
    if (now.difference(lastSaved) >= const Duration(seconds: 5)) {
      lastSaved = now;
      repo.save(
        lat: pos.lat,
        lng: pos.lng,
        heading: pos.headingDeg,
        speedKmh: pos.speedKmh,
        accuracy: pos.accuracyM,
      );
    }
  }, onError: (Object e, StackTrace st) {
    GpsDebug.log('provider', 'vehiclePosition stream ERROR $e');
  }, onDone: () {
    GpsDebug.log('provider', 'vehiclePosition stream DONE');
  });
  ref.onDispose(persistenceSub.cancel);

  return broadcast;
});

final navigationPositionControllerProvider =
    Provider<NavigationPositionController>((ref) {
  final controller = NavigationPositionController();
  controller.attach(ref.watch(vehiclePositionProvider.stream));
  final seed = ref.read(vehiclePositionProvider).valueOrNull;
  if (seed != null) controller.seed(seed);
  ref.onDispose(controller.dispose);
  return controller;
});

final navigationPositionProvider = StreamProvider<VehiclePosition>((ref) {
  return ref.watch(navigationPositionControllerProvider).positionStream;
});

final jointKalmanEnabledProvider = StateProvider<bool>((ref) {
  return true;
});

final jointKalmanEnabledEffectProvider = Provider<void>((ref) {
  final enabled = ref.watch(jointKalmanEnabledProvider);
  ref.read(locationServiceProvider).setJointKalmanEnabled(enabled);
});
