import 'dart:collection';
import 'package:flutter/foundation.dart';

/// دیباگ GPS — بعد از پیدا شدن علت، با `--dart-define=GPS_DEBUG=false` خاموش می‌شود.
const bool kGpsDebug = bool.fromEnvironment('GPS_DEBUG', defaultValue: true);

class GpsDebug {
  GpsDebug._();

  static final DateTime _t0 = DateTime.now();
  static final Queue<String> _lines = Queue<String>();
  static const int _maxLines = 700;
  static final Map<String, int> counters = <String, int>{};

  static DateTime? lastProviderAt;
  static DateTime? lastUiAt;

  static void count(String key) {
    if (!kGpsDebug) return;
    counters[key] = (counters[key] ?? 0) + 1;
  }

  static int c(String key) => counters[key] ?? 0;

  static void log(String tag, String msg) {
    if (!kGpsDebug) return;
    final t = DateTime.now().difference(_t0);
    final stamp = '${t.inMinutes.toString().padLeft(2, '0')}:'
        '${(t.inSeconds % 60).toString().padLeft(2, '0')}.'
        '${(t.inMilliseconds % 1000).toString().padLeft(3, '0')}';
    final line = '[$stamp][$tag] $msg';
    _lines.addLast(line);
    while (_lines.length > _maxLines) {
      _lines.removeFirst();
    }
    // adb logcat -s flutter | grep ABM-GPS
    debugPrint('ABM-GPS $line');
  }

  /// چند فریم اول استک = چه کسی start()/stop() را صدا زده.
  static String caller([int skip = 2, int take = 3]) {
    if (!kGpsDebug) return '';
    final lines = StackTrace.current.toString().split('\n');
    return lines
        .skip(skip)
        .take(take)
        .map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').trim())
        .join(' <- ');
  }

  static List<String> get lines => _lines.toList(growable: false);

  static void clear() {
    _lines.clear();
    counters.clear();
  }

  static String dump(String serviceSummary) {
    final b = StringBuffer()
      ..writeln('=== ABM-GPS DUMP ${DateTime.now().toIso8601String()} ===')
      ..writeln(serviceSummary)
      ..writeln('counters: $counters')
      ..writeln('lastProviderAt=$lastProviderAt lastUiAt=$lastUiAt')
      ..writeln('---');
    for (final l in _lines) {
      b.writeln(l);
    }
    return b.toString();
  }
}
