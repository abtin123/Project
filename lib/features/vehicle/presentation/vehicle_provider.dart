import 'package:flutter/services.dart';

final vehicleModels = <String>[
  'assets/models/bmw_i8.glb',
  'assets/models/acura_rsx.glb',
  'assets/models/nissan_patrol.glb',
  'assets/models/nissan_4x4.glb',
];

const vehicleModelNameKeys = <String>[
  'vehicle_model_bmw_i8',
  'vehicle_model_acura_rsx',
  'vehicle_model_nissan_patrol',
  'vehicle_model_porsche_macan_gts',
];

final vehicleModelNames = <String>[
  'BMW i8',
  'Acura RSX',
  'Nissan Patrol',
  'Dodge B-Series Pickup 1953',
];

final Set<String> _warmedVehicleModels = <String>{};

Future<void> warmUpVehicleModel(int modelIndex) async {
  if (vehicleModels.isEmpty) return;
  final index = modelIndex.clamp(0, vehicleModels.length - 1);
  final asset = vehicleModels[index];
  if (!_warmedVehicleModels.add(asset)) return;
  try {
    await rootBundle.load(asset);
  } catch (_) {
    _warmedVehicleModels.remove(asset);
  }
}
