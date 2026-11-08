import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routing/data/routing_service.dart' show RouteAlert;

final hudSpeedLimitProvider = StateProvider<int?>((ref) => null);

final hudNextAlertProvider = StateProvider<RouteAlert?>((ref) => null);
