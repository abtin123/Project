import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum DbgLevel { debug, info, warn, error, fatal }

class DbgEntry {
  DbgEntry(this.time, this.level, this.tag, this.message);
  final DateTime time;
  final DbgLevel level;
  final String tag;
  final String message;

  String get line {
    final t = time;
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    final lv = level.name.toUpperCase().padRight(5);
    return '$ts $lv [$tag] $message';
  }
}

/// Whole-app flight recorder.
///
///  * every `print`, Flutter error, async error, isolate error is captured
///  * lifecycle, memory pressure, slow frames, navigation, provider failures
///  * a heartbeat with native memory numbers (to see leaks / OOM kills)
///  * a session marker that tells, on the NEXT launch, whether the previous run
///    ended abnormally and in which app state (foreground / background)
///  * the Android side (NativeDebug.kt) adds uncaught exceptions, main-thread
///    stalls and ApplicationExitInfo (why the OS killed us)
class AppDebugger {
  AppDebugger._();
  static final AppDebugger instance = AppDebugger._();

  static const MethodChannel _native = MethodChannel('ir.avash.maps/debug');
  static const int _maxEntries = 6000;
  static const int _maxFileBytes = 1536 * 1024;

  final ListQueue<DbgEntry> _buffer = ListQueue<DbgEntry>();
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  bool _revisionScheduled = false;

  Directory? _dir;
  RandomAccessFile? _raf;
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;
  Timer? _heartbeat;
  File? _sessionFile;

  String? previousSessionVerdict;
  String appInfo = '';
  AppLifecycleState? lifecycle;
  int errorCount = 0;
  final DateTime startedAt = DateTime.now();
  bool _initialized = false;
  bool _hooksInstalled = false;

  Directory? get logDir => _dir;
  List<DbgEntry> get entries => _buffer.toList(growable: false);

  // ------------------------------------------------------------ bootstrap --

  /// Runs [body] inside a guarded zone that records `print` and uncaught errors.
  static void runGuarded(FutureOr<void> Function() body) {
    runZonedGuarded<void>(
      () {
        final r = body();
        if (r is Future<void>) {
          r.catchError((Object e, StackTrace s) {
            instance.recordError('zone', e, s, fatal: true);
          });
        }
      },
      (Object e, StackTrace s) => instance.recordError('zone', e, s, fatal: true),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          instance.log(DbgLevel.info, 'print', line);
          parent.print(zone, line);
        },
      ),
    );
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _installHooks();
    try {
      _dir = await _resolveDir();
      if (_dir != null) {
        await _dir!.create(recursive: true);
        final f = File('${_dir!.path}/dart.log');
        try {
          if (await f.exists() && await f.length() > _maxFileBytes) {
            final old = File('${_dir!.path}/dart.1.log');
            if (await old.exists()) await old.delete();
            await f.rename(old.path);
          }
        } catch (_) {}
        _raf = await f.open(mode: FileMode.append);
        _flushTimer = Timer.periodic(
            const Duration(milliseconds: 400), (_) => _flushPending());
      }
    } catch (e) {
      log(DbgLevel.warn, 'debug', 'file logging unavailable: $e');
    }

    try {
      final info = await PackageInfo.fromPlatform();
      appInfo =
          '${info.packageName} v${info.version}+${info.buildNumber} [build: fixes-r6]';
    } catch (_) {}
    log(DbgLevel.info, 'session',
        '=== START $appInfo | ${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
        '| ${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')} '
        '| logs: ${_dir?.path}');

    await _checkPreviousSession();
    _startHeartbeat();
  }

  Future<Directory?> _resolveDir() async {
    try {
      if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return Directory('${ext.path}/debug');
      }
    } catch (_) {}
    try {
      final s = await getApplicationSupportDirectory();
      return Directory('${s.path}/debug');
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------- session marker --

  Future<void> _checkPreviousSession() async {
    final d = _dir;
    if (d == null) return;
    _sessionFile = File('${d.path}/session.json');
    try {
      if (await _sessionFile!.exists()) {
        final j = jsonDecode(await _sessionFile!.readAsString()) as Map<String, dynamic>;
        final state = '${j['state']}';
        final lastBeat = DateTime.tryParse('${j['lastBeat']}');
        final started = DateTime.tryParse('${j['startedAt']}');
        final clean = j['clean'] == true;
        if (!clean) {
          final fg = state == 'resumed' || state == 'inactive';
          final ranFor = (started != null && lastBeat != null)
              ? lastBeat.difference(started)
              : null;
          previousSessionVerdict =
              'جلسهٔ قبلی غیرعادی تموم شده (ساعت ${lastBeat?.toLocal()}). '
              'آخرین وضعیت اپ: $state → ${fg ? 'داخل برنامه بودی/برنامه جلوی صفحه بود؛ احتمال کرش یا کشته‌شدن توسط سیستم' : 'اپ در پس‌زمینه بود؛ احتمالاً سیستم بستش یا از لیست اخیر پاکش کردی'}. '
              '${ranFor != null ? 'مدت اجرا: ${ranFor.inSeconds}s. ' : ''}'
              'آخرین مصرف حافظه: ${j['mem'] ?? '-'}';
          log(DbgLevel.fatal, 'session', 'PREVIOUS SESSION ENDED ABNORMALLY: $previousSessionVerdict');
        } else {
          log(DbgLevel.info, 'session', 'previous session ended cleanly');
        }
      } else {
        log(DbgLevel.info, 'session', 'first launch (no previous session file)');
      }
    } catch (e) {
      log(DbgLevel.warn, 'session', 'could not read previous session: $e');
    }
    _writeSession();
  }

  String _lastMem = '';

  void _writeSession({bool clean = false}) {
    final f = _sessionFile;
    if (f == null) return;
    try {
      f.writeAsStringSync(jsonEncode({
        'startedAt': startedAt.toIso8601String(),
        'lastBeat': DateTime.now().toIso8601String(),
        'state': lifecycle?.name ?? 'starting',
        'clean': clean,
        'mem': _lastMem,
      }));
    } catch (_) {}
  }

  void _startHeartbeat() {
    var n = 0;
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) async {
      n++;
      _writeSession();
      if (n % 2 == 0) {
        try {
          final m = await _native.invokeMethod<String>('memory');
          if (m != null) {
            _lastMem = m;
            log(DbgLevel.debug, 'hb', '${lifecycle?.name ?? '?'} $m');
          }
        } catch (_) {}
      }
    });
  }

  // ----------------------------------------------------------------- hooks --

  void _installHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;

    final presentError = FlutterError.presentError;
    FlutterError.onError = (FlutterErrorDetails d) {
      recordError('flutter', d.exception, d.stack,
          extra: d.context?.toDescription() ?? d.library);
      try {
        presentError(d);
      } catch (_) {}
    };

    ui.PlatformDispatcher.instance.onError = (Object e, StackTrace s) {
      recordError('platform', e, s, fatal: true);
      return true;
    };

    try {
      Isolate.current.addErrorListener(RawReceivePort((dynamic pair) {
        final l = pair as List<dynamic>;
        log(DbgLevel.fatal, 'isolate', '${l.first}\n${l.last}');
      }).sendPort);
    } catch (_) {}

    WidgetsBinding.instance.addObserver(_LifecycleObserver(this));

    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final total = t.totalSpan.inMilliseconds;
        if (total > 200) {
          _slowFrames++;
          if (_slowFrames <= 5 || _slowFrames % 20 == 0) {
            log(DbgLevel.warn, 'frame',
                'slow frame #$_slowFrames total=${total}ms '
                'build=${t.buildDuration.inMilliseconds}ms raster=${t.rasterDuration.inMilliseconds}ms');
          }
        }
      }
    });
  }

  int _slowFrames = 0;

  // ------------------------------------------------------------------- API --

  void log(DbgLevel level, String tag, String message) {
    final e = DbgEntry(DateTime.now(), level, tag, message);
    _buffer.addLast(e);
    while (_buffer.length > _maxEntries) {
      _buffer.removeFirst();
    }
    _pending.writeln(e.line);
    if (level.index >= DbgLevel.error.index) {
      _flushPending();
    }
    if (!_revisionScheduled) {
      _revisionScheduled = true;
      Timer(const Duration(milliseconds: 250), () {
        _revisionScheduled = false;
        revision.value++;
      });
    }
  }

  void i(String tag, String msg) => log(DbgLevel.info, tag, msg);
  void w(String tag, String msg) => log(DbgLevel.warn, tag, msg);
  void d(String tag, String msg) => log(DbgLevel.debug, tag, msg);

  void recordError(String tag, Object error, StackTrace? stack,
      {bool fatal = false, String? extra}) {
    errorCount++;
    final st = stack == null
        ? ''
        : '\n${stack.toString().split('\n').take(28).join('\n')}';
    log(fatal ? DbgLevel.fatal : DbgLevel.error, tag,
        '${extra != null ? '($extra) ' : ''}$error$st');
    try {
      _native.invokeMethod<void>('log', {'tag': 'dart-err', 'msg': '$error'});
    } catch (_) {}
  }

  void _flushPending() {
    final raf = _raf;
    if (raf == null || _pending.isEmpty) return;
    try {
      raf.writeStringSync(_pending.toString());
      raf.flushSync();
    } catch (_) {}
    _pending.clear();
  }

  void markClean() {
    _flushPending();
    _writeSession(clean: true);
  }

  Future<void> clear() async {
    _buffer.clear();
    _pending.clear();
    revision.value++;
    try {
      await _raf?.truncate(0);
      await _raf?.setPosition(0);
    } catch (_) {}
    try {
      await _native.invokeMethod<void>('clearNativeLog');
    } catch (_) {}
  }

  // ---------------------------------------------------------- native calls --

  Future<String> nativeSnapshot() => _str('snapshot');
  Future<String> nativeLog() => _str('nativeLog');
  Future<String> logcat([int lines = 1200]) => _str('logcat', {'lines': lines});
  Future<String> lastCrash() async {
    final s = await _str('lastCrash');
    return s == '(unavailable)' ? '' : s;
  }

  Future<void> openBatterySettings() async {
    try {
      await _native.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }

  Future<String> _str(String method, [Object? args]) async {
    try {
      final r = await _native.invokeMethod<String>(method, args);
      return r ?? '';
    } on MissingPluginException {
      return '(not available on this platform)';
    } catch (e) {
      return '(unavailable: $e)';
    }
  }

  // ---------------------------------------------------------------- report --

  Future<String> buildReport() async {
    final b = StringBuffer();
    b.writeln('===== AVASH MAPS DEBUG REPORT =====');
    b.writeln('generated: ${DateTime.now()}');
    b.writeln('app: $appInfo');
    b.writeln('uptime: ${DateTime.now().difference(startedAt)}');
    b.writeln('errors since start: $errorCount');
    b.writeln('previous session: ${previousSessionVerdict ?? 'OK / unknown'}');
    b.writeln('\n----- ANDROID SNAPSHOT -----');
    b.writeln(await nativeSnapshot());
    final crash = await lastCrash();
    if (crash.isNotEmpty) {
      b.writeln('\n----- LAST NATIVE (JAVA) CRASH -----');
      b.writeln(crash);
    }
    b.writeln('\n----- ANDROID NATIVE LOG (tail) -----');
    b.writeln(await nativeLog());
    b.writeln('\n----- DART LOG (last ${_buffer.length}) -----');
    for (final e in _buffer) {
      b.writeln(e.line);
    }
    b.writeln('\n----- LOGCAT (own app, tail) -----');
    b.writeln(await logcat(900));
    return b.toString();
  }

  Future<String?> saveReport() async {
    try {
      final text = await buildReport();
      final dir = _dir ?? await getTemporaryDirectory();
      await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final f = File('${dir.path}/report_$stamp.txt');
      await f.writeAsString(text);
      return f.path;
    } catch (e) {
      log(DbgLevel.error, 'debug', 'saveReport failed: $e');
      return null;
    }
  }

  Future<void> shareReport() async {
    final path = await saveReport();
    if (path == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: 'Avash Maps debug report'),
      );
    } catch (e) {
      log(DbgLevel.error, 'debug', 'share failed: $e');
    }
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._d);
  final AppDebugger _d;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _d.lifecycle = state;
    _d.log(DbgLevel.info, 'lifecycle', state.name);
    _d._writeSession(clean: state == AppLifecycleState.detached);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _d._flushPending();
    }
  }

  @override
  void didHaveMemoryPressure() {
    _d.log(DbgLevel.warn, 'memory', 'didHaveMemoryPressure (Flutter)');
  }
}

/// Logs every route change.
class DebugNavigatorObserver extends NavigatorObserver {
  String _n(Route<dynamic>? r) =>
      r?.settings.name ?? r?.settings.runtimeType.toString() ?? '?';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      AppDebugger.instance.i('nav', 'push ${_n(route)} (from ${_n(previousRoute)})');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      AppDebugger.instance.i('nav', 'pop ${_n(route)} (back to ${_n(previousRoute)})');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      AppDebugger.instance.i('nav', 'replace ${_n(oldRoute)} -> ${_n(newRoute)}');
}

/// Logs provider creation / disposal and every provider failure.
base class DebugProviderObserver extends ProviderObserver {
  String _name(ProviderBase<Object?> p) => p.name ?? p.runtimeType.toString();

  @override
  void didAddProvider(
      ProviderBase<Object?> provider, Object? value, ProviderContainer container) {
    AppDebugger.instance.d('provider', 'create ${_name(provider)}');
    if (value is AsyncError) {
      AppDebugger.instance.recordError('provider', value.error, value.stackTrace,
          extra: _name(provider));
    }
  }

  @override
  void didUpdateProvider(ProviderBase<Object?> provider, Object? previousValue,
      Object? newValue, ProviderContainer container) {
    if (newValue is AsyncError &&
        !(previousValue is AsyncError && previousValue.error == newValue.error)) {
      AppDebugger.instance.recordError('provider', newValue.error, newValue.stackTrace,
          extra: _name(provider));
    }
  }

  @override
  void didDisposeProvider(ProviderBase<Object?> provider, ProviderContainer container) {
    AppDebugger.instance.d('provider', 'dispose ${_name(provider)}');
  }

  @override
  void providerDidFail(ProviderBase<Object?> provider, Object error,
      StackTrace stackTrace, ProviderContainer container) {
    AppDebugger.instance.recordError('provider', error, stackTrace,
        extra: _name(provider));
  }
}
