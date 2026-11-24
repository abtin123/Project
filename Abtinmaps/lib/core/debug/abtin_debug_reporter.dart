import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'abtin_debug.dart';

/// ارسال گزارش دیباگ به توسعه‌دهنده (abtinmaps@gmail.com).
///
/// ایمیل مستقیم از داخل اپ (SMTP) ممکن نیست مگر اینکه رمز حساب جیمیل داخل APK
/// گذاشته شود که هر کاربر می‌تواند آن را استخراج کند؛ پس گزارش به یک «گیرنده»
/// (Google Apps Script، فایل tools/apps_script_debug_receiver.gs) POST می‌شود و
/// آن گیرنده برای abtinmaps@gmail.com ایمیل می‌فرستد. بدون endpoint، گزینهٔ
/// ایمیل دستی (mailto) استفاده می‌شود.
class AbtinDebugReporter {
  AbtinDebugReporter._();

  /// آدرس Web App گیرنده؛ یا هنگام بیلد: --dart-define=ABTIN_DEBUG_ENDPOINT=...
  static const String endpoint = String.fromEnvironment(
    'ABTIN_DEBUG_ENDPOINT',
    defaultValue: '',
  );

  /// توکن ساده برای کم‌کردن اسپم (باید با توکن داخل اسکریپت یکی باشد).
  static const String token = String.fromEnvironment(
    'ABTIN_DEBUG_TOKEN',
    defaultValue: 'abtin-debug-v1',
  );

  static const String email = 'abtinmaps@gmail.com';

  /// ارسال خودکار فقط با رضایت کاربر (پیش‌فرض خاموش).
  static final ValueNotifier<bool> autoSend = ValueNotifier<bool>(false);

  static String _deviceId = '';
  static File? _file;
  static bool _sending = false;
  static DateTime _lastAutoAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _pendingAuto;

  static bool get hasEndpoint => endpoint.trim().isNotEmpty;

  static Future<void> init() async {
    AbtinDebug.onProblem = _onProblem;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/abtin_debug_reporter.json');
      _file = f;
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          autoSend.value = j['autoSend'] == true;
          _deviceId = '${j['deviceId'] ?? ''}';
        }
      }
      if (_deviceId.isEmpty) {
        final r = math.Random.secure();
        _deviceId =
            List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
                .join();
        await _save();
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      await _file?.writeAsString(
          jsonEncode({'autoSend': autoSend.value, 'deviceId': _deviceId}));
    } catch (_) {}
  }

  static Future<void> setAutoSend(bool value) async {
    autoSend.value = value;
    await _save();
  }

  /// مختصات را به ~۱۰۰ متر گرد می‌کند تا موقعیت دقیق کاربر ارسال نشود.
  static String sanitize(String text) {
    return text.replaceAllMapped(RegExp(r'-?\d{1,3}\.\d{4,}'), (m) {
      final v = double.tryParse(m[0]!);
      return v == null ? m[0]! : v.toStringAsFixed(3);
    });
  }

  static String _tail(int maxLines) {
    final lines = AbtinDebug.dump().split('\n');
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    return sanitize(lines.sublist(start).join('\n'));
  }

  static void _onProblem(String tag, String message) {
    if (!autoSend.value || !hasEndpoint) return;
    final now = DateTime.now();
    if (now.difference(_lastAutoAt) < const Duration(minutes: 10)) return;
    if (_pendingAuto?.isActive ?? false) return;
    // چند ثانیه صبر می‌کنیم تا لاگ‌های بعد از مشکل هم در گزارش باشند.
    _pendingAuto = Timer(const Duration(seconds: 5), () {
      _lastAutoAt = DateTime.now();
      unawaited(send(reason: 'auto:$tag'));
    });
  }

  /// ارسال گزارش به endpoint. true یعنی ارسال شد.
  static Future<bool> send({required String reason}) async {
    if (!hasEndpoint || _sending) return false;
    _sending = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final body = jsonEncode({
        'token': token,
        'app': info.appName,
        'version': '${info.version}+${info.buildNumber}',
        'platform': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'deviceId': _deviceId,
        'time': DateTime.now().toIso8601String(),
        'reason': reason,
        'log': _tail(500),
      });
      final r = await http
          .post(
            Uri.parse(endpoint),
            headers: const {'Content-Type': 'text/plain;charset=utf-8'},
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      // Apps Script بعد از اجرای doPost با ریدایرکت (302) جواب می‌دهد؛ اجرا انجام شده.
      final ok = r.statusCode >= 200 && r.statusCode < 400;
      AbtinDebug.log('REPORT', 'sent reason=$reason ok=$ok status=${r.statusCode}');
      return ok;
    } catch (e) {
      AbtinDebug.log('REPORT', 'send failed: $e');
      return false;
    } finally {
      _sending = false;
    }
  }

  /// فایل کامل لاگ را برای ارسال با هر برنامه‌ای (جیمیل و ...) به اشتراک می‌گذارد.
  static Future<bool> shareLogFile() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/abtin_debug.log');
      await f.writeAsString(
          'AbtinMaps ${info.version}+${info.buildNumber} '
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n\n'
          '${sanitize(AbtinDebug.dump())}');
      await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        subject: 'AbtinMaps debug report',
        text: 'گزارش دیباگ AbtinMaps — لطفاً به $email ارسال شود.',
      ));
      return true;
    } catch (e) {
      AbtinDebug.log('REPORT', 'share failed: $e');
      return false;
    }
  }

  /// بدون endpoint: باز کردن برنامهٔ ایمیل با ابتدای متن گزارش (محدودیت طول لینک).
  static Future<bool> openMailFallback() async {
    final body = _tail(80);
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {
        'subject': 'AbtinMaps debug report',
        'body': body.length > 6000 ? body.substring(body.length - 6000) : body,
      },
    );
    try {
      return await launchUrl(uri);
    } catch (_) {
      return false;
    }
  }
}
