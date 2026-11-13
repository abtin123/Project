import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../routing/presentation/routing_providers.dart';
import '../domain/flat_phone_detector.dart';
import 'hud_settings_providers.dart';

const _sensorInterval = Duration(milliseconds: 40);

final flatPhoneSnapshotProvider = StreamProvider<FlatPhoneSnapshot>((ref) {
  // The gyroscope + accelerometer were sampled at 25 Hz for the whole app lifetime,
  // but the result is only used to auto-open the HUD while navigating with the HUD
  // enabled. Outside that case the sensors stay off.
  final hudEnabled = ref.watch(hudSettingsProvider.select((s) => s.enabled));
  final navigating =
      ref.watch(activeNavigationProvider.select((n) => n != null));
  if (!hudEnabled || !navigating) {
    return Stream<FlatPhoneSnapshot>.value(FlatPhoneSnapshot.idle);
  }
  final out = StreamController<FlatPhoneSnapshot>();
  final detector = FlatPhoneDetector();
  var last = FlatPhoneSnapshot.idle;

  void publish() {
    final s = detector.snapshot;
    if (s.sameFlags(last) || out.isClosed) return;
    last = s;
    out.add(s);
  }

  void quiet(Object _) {}
  final subs = <StreamSubscription<dynamic>>[
    gyroscopeEventStream(samplingPeriod: _sensorInterval).listen((e) {
      detector.onGyroscope(e.x, e.y, e.z, DateTime.now());
    }, onError: quiet),
    accelerometerEventStream(samplingPeriod: _sensorInterval).listen((e) {
      detector.onAccelerometer(e.x, e.y, e.z, DateTime.now());
      publish();
    }, onError: quiet),
  ];

  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
    out.close();
  });
  out.add(last);
  return out.stream;
});

final canAttemptOpenHudProvider = Provider<bool>((ref) {
  return ref.watch(flatPhoneSnapshotProvider).valueOrNull?.canAttemptOpenHud ??
      false;
});
