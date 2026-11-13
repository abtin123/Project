import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/permissions/location_permission_flow.dart';
import '../data/location_repository.dart';
import '../data/location_service.dart';
import 'navigation_position_controller.dart';

final locationServiceProvider = Provider<LocationService>((ref) {
  final service = LocationService();
  ref.onDispose(service.dispose);
  return service;
});

final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  return LocationRepository(ref.watch(locationServiceProvider));
});

final locationLifecycleTickProvider = StateProvider<int>((ref) => 0);

/// Emits on every change of permission / location-service state.
final locationReadinessProvider = StreamProvider<LocationReadiness>((ref) async* {
  ref.watch(locationLifecycleTickProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  LocationReadiness? last;
  while (!disposed) {
    final r = await LocationPermissionFlow.check();
    if (disposed) return;
    if (r != last) {
      last = r;
      yield r;
    }
    await Future<void>.delayed(
      Duration(seconds: r == LocationReadiness.ready ? 8 : 2),
    );
  }
});

final retryLocationPermissionProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    await LocationPermissionFlow.resolve();
    ref.read(locationLifecycleTickProvider.notifier).state++;
    unawaited(ref.read(locationRepositoryProvider).start());
  };
});

final vehiclePositionProvider = StreamProvider<VehiclePosition>((ref) {
  final repo = ref.watch(locationRepositoryProvider);
  unawaited(repo.start());
  ref.listen<AsyncValue<LocationReadiness>>(locationReadinessProvider,
      (prev, next) {
    if (next.valueOrNull == LocationReadiness.ready &&
        prev?.valueOrNull != LocationReadiness.ready) {
      unawaited(repo.start());
    }
  });
  return repo.positionStream;
});

final navigationPositionControllerProvider =
    Provider<NavigationPositionController>((ref) {
  final controller = NavigationPositionController();
  controller.attach(ref.watch(locationRepositoryProvider).positionStream);
  ref.onDispose(controller.dispose);
  return controller;
});

final navigationPositionProvider = StreamProvider<VehiclePosition>((ref) {
  return ref.watch(navigationPositionControllerProvider).positionStream;
});
