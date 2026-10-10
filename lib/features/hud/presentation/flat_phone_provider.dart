import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../domain/flat_phone_detector.dart';

const _sensorInterval = Duration(milliseconds: 40);

final flatPhoneSnapshotProvider = StreamProvider<FlatPhoneSnapshot>((ref) {
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
