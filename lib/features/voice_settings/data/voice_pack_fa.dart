library;

/// نگاشت مانور واقعی به cueهای داخل فایل ABV یک‌تکه.
///
/// هر مانور یک «زنجیرهٔ cue» دارد: اولین cueی که در بستهٔ نصب‌شده وجود داشته
/// باشد پخش می‌شود. به این ترتیب اگر بسته قدیمی باشد یا cue خاصی نداشته باشد،
/// به‌جای سکوت نزدیک‌ترین جملهٔ درست گفته می‌شود (مثلاً خروجی شمارهٔ ۷ میدان که
/// در بسته نیست → «از خروجی بعدی»).
///
/// فاصله جدا از مانور گفته می‌شود: [distancePrefixCue] یک cueی مثل `in_200m`
/// برمی‌گرداند که قبل از cue مانور پخش می‌شود («در دویست متر دیگر،» + «در میدان،
/// از خروجی دوم خارج شوید»).
class VoicePackFa {
  VoicePackFa._();

  static const String arrived = 'arrived_destination';
  static const int maxRoundaboutExit = 20;

  /// فاصله‌های استاندارد موجود در بستهٔ صوتی (متر).
  static const List<int> _prefixMeters = <int>[
    20, 30, 50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 800, 900, 1000,
  ];

  /// کمترین فاصله‌ای که گفتن «در N متر دیگر» برایش معنا دارد.
  static const double minPrefixMeters = 45;

  /// cue فاصله (قبل از مانور). برای فاصلهٔ خیلی کم `null` است.
  static String? distancePrefixCue(double meters) {
    if (!meters.isFinite || meters < minPrefixMeters) return null;
    var best = _prefixMeters.first;
    for (final m in _prefixMeters) {
      if ((m - meters).abs() < (best - meters).abs()) best = m;
    }
    return best >= 1000 ? 'in_${best ~/ 1000}km' : 'in_${best}m';
  }

  static String _norm(String? v) =>
      (v ?? '').trim().toLowerCase().replaceAll('-', ' ').replaceAll('_', ' ');

  static String? _side(String modifier) {
    if (modifier.contains('left')) return 'left';
    if (modifier.contains('right')) return 'right';
    return null;
  }

  /// زنجیرهٔ cueها، از دقیق‌ترین به عمومی‌ترین.
  static List<String> cueChainForManeuver({
    required String type,
    String? modifier,
    int? exit,
  }) {
    final t = _norm(type);
    final m = _norm(modifier);
    final side = _side(m);

    // --- شروع و پایان ---
    if (t == 'arrive') {
      return <String>[
        if (side != null) 'destination_on_$side',
        'approaching_destination',
        'destination_ahead',
      ];
    }
    if (t == 'depart') return const <String>['route_found', 'start_navigation'];

    // --- دوربرگردان ---
    if (t == 'uturn' || t == 'u turn' || m.contains('uturn') || m.contains('u turn')) {
      return const <String>['u_turn', 'u_turn_when_possible', 'turn_left'];
    }

    // --- میدان (همهٔ نوع‌های OSRM: roundabout, rotary, roundabout turn, exit roundabout ...) ---
    if (t.contains('roundabout') || t.contains('rotary')) {
      if (t.startsWith('exit')) return const <String>['continue_straight'];
      if (exit != null && exit >= 1 && exit <= maxRoundaboutExit) {
        return <String>[
          'roundabout_take_exit_$exit',
          'roundabout_take_exit_next',
          'roundabout_enter',
        ];
      }
      // «roundabout turn»: میدان کوچک بدون شماره خروجی؛ جهت پیچ مهم است.
      if (t.contains('turn') && side != null) {
        return <String>[..._turnChain(m, side), 'roundabout_enter'];
      }
      return const <String>['roundabout_take_exit_next', 'roundabout_enter'];
    }

    // --- بزرگراه و رمپ ---
    if (t == 'on ramp') {
      return <String>[
        'merge_onto_highway',
        if (side != null) 'keep_$side',
        'continue_straight',
      ];
    }
    if (t == 'off ramp') {
      return <String>[
        'exit_highway',
        if (side != null) 'keep_$side',
        'continue_straight',
      ];
    }
    if (t == 'merge') {
      return <String>[
        if (side != null) 'keep_$side' else 'merge_onto_highway',
        'continue_straight',
      ];
    }
    if (t == 'fork') {
      return <String>[
        if (side != null) 'keep_$side',
        'continue_straight',
      ];
    }

    // --- ادامه دادن ---
    if (t == 'new name' || t == 'continue' || t == 'notification') {
      return side != null && m != 'straight'
          ? _turnChain(m, side)
          : const <String>['continue_straight'];
    }

    // --- پیچ‌ها (turn, end of road, use lane, ...) ---
    if (side != null) return _turnChain(m, side);
    return const <String>['continue_straight'];
  }

  static List<String> _turnChain(String modifier, String side) {
    if (modifier.contains('sharp')) {
      return <String>['turn_sharp_$side', 'turn_$side'];
    }
    if (modifier.contains('slight')) {
      return <String>['turn_slight_$side', 'turn_$side'];
    }
    return <String>['turn_$side'];
  }
}
