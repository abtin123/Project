import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routing/data/routing_service.dart' show RouteAlert;

/// داده‌هایی که صفحهٔ اصلی محاسبه می‌کند و HUD باید عیناً همان را نشان بدهد
/// (نه محاسبهٔ جداگانه‌ای که ممکن است با نقشه اختلاف داشته باشد).
///
/// محدودیت سرعتِ جاده‌ی فعلی: `instruction.speedLimit ?? roadSafety.speedLimit`.
final hudSpeedLimitProvider = StateProvider<int?>((ref) => null);

/// نزدیک‌ترین هشدارِ جلوی خودرو روی مسیر (همان که زیر کارت مسیر دیده می‌شود).
final hudNextAlertProvider = StateProvider<RouteAlert?>((ref) => null);
