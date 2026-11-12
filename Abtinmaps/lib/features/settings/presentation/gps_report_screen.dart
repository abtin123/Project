import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../gps/data/gps_debug.dart';
import '../../gps/presentation/gps_providers.dart';

/// گزارش زندهٔ GPS (تنظیمات ← گزارش GPS). دکمهٔ «کپی گزارش» کل گزارش را کپی می‌کند.
class GpsReportScreen extends ConsumerStatefulWidget {
  const GpsReportScreen({super.key});

  @override
  ConsumerState<GpsReportScreen> createState() => _GpsReportScreenState();
}

class _GpsReportScreenState extends ConsumerState<GpsReportScreen> {
  Timer? _timer;
  int _tick = 0;
  bool? _serviceEnabled;
  LocationPermission? _permission;

  String? _runningProbe;
  DateTime? _probeStartedAt;
  Completer<String>? _probeCompleter;
  final List<String> _probeResults = <String>[];

  Future<void> _runProbe(
      String name, LocationSettings settings, Duration timeout) async {
    if (_runningProbe != null) return;
    final svc = ref.read(locationServiceProvider);
    svc.stop();
    setState(() {
      _runningProbe = name;
      _probeStartedAt = DateTime.now();
    });
    final completer = Completer<String>();
    _probeCompleter = completer;
    final sw = Stopwatch()..start();
    final sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        if (!completer.isCompleted) {
          completer.complete(
              'OK بعد از ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s | دقت ${p.accuracy.toStringAsFixed(0)}m | ${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}');
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.complete('خطا: ${e.runtimeType} $e');
        }
      },
    );
    final result = await completer.future.timeout(timeout,
        onTimeout: () => 'بدون فیکس در ${timeout.inSeconds}s');
    await sub.cancel();
    _probeCompleter = null;
    GpsDebug.log('probe-test', '$name -> $result');
    svc.start();
    if (!mounted) return;
    setState(() {
      _runningProbe = null;
      _probeResults.insert(0, '$name: $result');
    });
  }

  AndroidSettings _probeSettings(LocationAccuracy acc, bool raw) =>
      AndroidSettings(
        accuracy: acc,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: raw,
      );

  @override
  void initState() {
    super.initState();
    _refreshPlatformInfo();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _tick++;
      if (_tick % 3 == 0) _refreshPlatformInfo();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshPlatformInfo() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      if (!mounted) return;
      setState(() {
        _serviceEnabled = enabled;
        _permission = perm;
      });
    } catch (_) {}
  }

  int? _ageSec(DateTime? t) =>
      t == null ? null : DateTime.now().difference(t).inSeconds;

  String _fmtAge(DateTime? t) {
    final a = _ageSec(t);
    return a == null ? '—' : '${a}s';
  }

  List<String> _diagnose() {
    final svc = ref.read(locationServiceProvider);
    final out = <String>[];
    final raw = GpsDebug.c('raw');
    final accepted = GpsDebug.c('accepted');
    final rawAge = _ageSec(svc.debugLastRawAt);

    if (_serviceEnabled == false) {
      out.add('GPS (Location) گوشی خاموش است.');
    }
    if (_permission == LocationPermission.denied ||
        _permission == LocationPermission.deniedForever) {
      out.add('مجوز موقعیت مکانی داده نشده است (${_permission!.name}).');
    }
    if (raw == 0) {
      out.add('هیچ کال‌بکی از Geolocator نرسیده؛ مشکل از سطح سیستم‌عامل/مجوز/استریم است، نه فیلترها.');
    } else if (accepted == 0) {
      out.add('کال‌بک رسیده ($raw) ولی هیچ فیکسی پذیرفته نشده؛ فیلترهای زیر را ببینید.');
    } else if (rawAge != null && rawAge > 15) {
      out.add('کال‌بک‌های GPS ${rawAge}s است که متوقف شده‌اند (استریم از سمت Geolocator قطع شده).');
    }
    final drops = GpsDebug.counters.entries
        .where((e) => e.key.startsWith('drop.') && e.value > 0)
        .map((e) => '${e.key}=${e.value}')
        .toList();
    if (drops.isNotEmpty) out.add('فیکس‌های ردشده: ${drops.join('، ')}');
    if (GpsDebug.c('ts.repaired') > 0) {
      out.add('تایم‌استمپ غیرصعودی ${GpsDebug.c('ts.repaired')} بار اصلاح شد (دستگاه/شبیه‌ساز تایم‌استمپ تکراری می‌دهد).');
    }
    if (GpsDebug.c('restart.error') > 0) {
      out.add('${GpsDebug.c('restart.error')} بار به‌خاطر خطای استریم ری‌استارت شد.');
    }
    if (GpsDebug.c('restart.stall') > 0) {
      out.add('${GpsDebug.c('restart.stall')} بار واچ‌داگ توقف استریم را ری‌استارت کرد.');
    }
    if (GpsDebug.c('stop') > 0) {
      out.add('stop() ${GpsDebug.c('stop')} بار صدا زده شده (چرخهٔ عمر/پس‌زمینه).');
    }
    if (accepted > 0 && GpsDebug.c('provider.pos') == 0) {
      out.add('فیکس پذیرفته شده ولی به provider نرسیده.');
    }
    if (GpsDebug.c('provider.pos') > 0 && GpsDebug.c('ui.pos') == 0) {
      out.add('موقعیت به provider رسیده ولی UI دریافتش نکرده.');
    }
    if (out.isEmpty) out.add('مشکل مشخصی در شمارنده‌ها دیده نمی‌شود.');
    return out;
  }

  String _header() {
    final svc = ref.read(locationServiceProvider);
    final b = StringBuffer()
      ..writeln('serviceEnabled=$_serviceEnabled permission=${_permission?.name}')
      ..writeln(svc.debugSummary())
      ..writeln('lastRawAge=${_fmtAge(svc.debugLastRawAt)} '
          'lastFixAge=${_fmtAge(svc.debugLastAcceptedAt)} '
          'providerAge=${_fmtAge(GpsDebug.lastProviderAt)} '
          'uiAge=${_fmtAge(GpsDebug.lastUiAt)}')
      ..writeln('--- diagnosis ---');
    for (final d in _diagnose()) {
      b.writeln('* $d');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(locationServiceProvider);
    final lines = GpsDebug.lines;
    final shown = lines.length > 300 ? lines.sublist(lines.length - 300) : lines;
    final textColor = AppColors.textPrimary(context);

    Widget stat(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(k, style: TextStyle(color: textColor.withOpacity(0.7), fontSize: 13))),
              Text(v,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        );

    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: AppBar(
        title: Text(AppStrings.literal('گزارش GPS')),
        backgroundColor: AppColors.background(context),
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(AppStrings.literal('کپی گزارش')),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: GpsDebug.dump(_header())));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(AppStrings.literal('گزارش کپی شد'))));
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(AppStrings.literal('ری‌استارت GPS')),
                onPressed: () => svc.start(),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(AppStrings.literal('پاک‌کردن')),
                onPressed: () => setState(GpsDebug.clear),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _card(context, [
            Text(AppStrings.literal('تست مستقیم موقعیت‌یابی'),
                style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              AppStrings.literal(
                  'هر تست جدا از منطق برنامه فقط یک روش را امتحان می‌کند. برای تست GPS خالص اینترنت را قطع کنید و بیرون، زیر آسمان باز باشید.'),
              style: TextStyle(color: textColor.withOpacity(0.7), fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                onPressed: _runningProbe != null
                    ? null
                    : () => _runProbe('GPS خالص (ماهواره)',
                        _probeSettings(LocationAccuracy.high, true),
                        const Duration(seconds: 150)),
                child: Text(AppStrings.literal('GPS خالص (۲.۵ دقیقه)')),
              ),
              OutlinedButton(
                onPressed: _runningProbe != null
                    ? null
                    : () => _runProbe('شبکه (Wi‑Fi/دکل)',
                        _probeSettings(LocationAccuracy.low, true),
                        const Duration(seconds: 30)),
                child: Text(AppStrings.literal('شبکه (۳۰ ثانیه)')),
              ),
              OutlinedButton(
                onPressed: _runningProbe != null
                    ? null
                    : () => _runProbe('Fused گوگل',
                        _probeSettings(LocationAccuracy.high, false),
                        const Duration(seconds: 30)),
                child: Text(AppStrings.literal('Fused گوگل (۳۰ ثانیه)')),
              ),
            ]),
            if (_runningProbe != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                    '${_runningProbe!} … ${DateTime.now().difference(_probeStartedAt!).inSeconds}s',
                    style: TextStyle(color: textColor, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final c = _probeCompleter;
                    if (c != null && !c.isCompleted) c.complete('لغو شد');
                  },
                  child: Text(AppStrings.literal('لغو')),
                ),
              ]),
            ],
            for (final r in _probeResults)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $r', style: TextStyle(color: textColor, fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 12),
          _card(context, [
            stat('GPS گوشی', '${_serviceEnabled ?? '…'}'),
            stat('مجوز', _permission?.name ?? '…'),
            stat('وضعیت سرویس', svc.state.name),
            stat('آخرین کال‌بک خام', _fmtAge(svc.debugLastRawAt)),
            stat('آخرین فیکس پذیرفته‌شده', _fmtAge(svc.debugLastAcceptedAt)),
            stat('آخرین موقعیت در provider', _fmtAge(GpsDebug.lastProviderAt)),
            stat('آخرین موقعیت در UI', _fmtAge(GpsDebug.lastUiAt)),
            stat('خام / پذیرفته / UI',
                '${GpsDebug.c('raw')} / ${GpsDebug.c('accepted')} / ${GpsDebug.c('ui.pos')}'),
          ]),
          const SizedBox(height: 12),
          _card(context, [
            Text(AppStrings.literal('تشخیص خودکار'),
                style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final d in _diagnose())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $d', style: TextStyle(color: textColor, fontSize: 13)),
              ),
          ]),
          const SizedBox(height: 12),
          _card(context, [
            Text(AppStrings.literal('شمارنده‌ها'),
                style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('${GpsDebug.counters}',
                textDirection: TextDirection.ltr,
                style: TextStyle(color: textColor, fontSize: 11, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 12),
          _card(context, [
            Text('${AppStrings.literal('لاگ')} (${lines.length})',
                style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final l in shown.reversed)
              Text(l,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: textColor, fontSize: 10, fontFamily: 'monospace')),
          ]),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.frameBackground(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}
