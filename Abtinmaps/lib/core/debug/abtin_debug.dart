import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'abtin_debug_reporter.dart';

/// دیباگر داخلی: رویدادهای مسیریابی/ناوبری/رسم مسیر را در حافظه نگه می‌دارد و
/// از «تنظیمات ← گزارش خطا (دیباگ)» قابل مشاهده و کپی است.
class AbtinDebug {
  AbtinDebug._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// وقتی لاگی با برچسب STALL یا ERROR ثبت شود صدا زده می‌شود (ارسال خودکار گزارش).
  static void Function(String tag, String message)? onProblem;
  static final List<String> _lines = <String>[];
  static const int _max = 1500;

  static String _t(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.'
        '${d.millisecond.toString().padLeft(3, '0')}';
  }

  static void log(String tag, String message) {
    final line = '${_t(DateTime.now())} [$tag] $message';
    _lines.add(line);
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    debugPrint('AbtinDebug $line');
    if (tag == 'STALL' || tag == 'ERROR') onProblem?.call(tag, message);
    _notifyLater();
  }

  static bool _notifyPending = false;

  // لاگ ممکن است وسط build صدا زده شود؛ اعلان به شنونده‌ها را عقب می‌اندازیم.
  static void _notifyLater() {
    if (_notifyPending) return;
    _notifyPending = true;
    Timer(Duration.zero, () {
      _notifyPending = false;
      revision.value++;
    });
  }

  static String dump() => _lines.join('\n');

  static void clear() {
    _lines.clear();
    _notifyLater();
  }

  static Future<void> showSheet(
    BuildContext context, {
    String Function()? snapshot,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xEE101418),
      builder: (ctx) => _AbtinDebugSheet(snapshot: snapshot),
    );
  }
}

class _AbtinDebugSheet extends StatelessWidget {
  const _AbtinDebugSheet({this.snapshot});
  final String Function()? snapshot;

  Future<void> _toggleAuto(BuildContext context, bool value) async {
    if (!value) {
      await AbtinDebugReporter.setAutoSend(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ارسال خودکار گزارش'),
        content: const Text(
          'با روشن‌کردن این گزینه، هنگام بروز مشکل (مثل هنگ نقشه یا خطا) '
          'گزارش فنی برای توسعه‌دهنده ایمیل می‌شود.\n\n'
          'گزارش شامل: نسخهٔ اپ و سیستم‌عامل، رویدادهای مسیریابی/نقشه، یک شناسهٔ '
          'تصادفی ناشناس و مختصات گردشده (حدود ۱۰۰ متر دقت) است. شمارهٔ تلفن، '
          'مخاطبین و نام شما ارسال نمی‌شود. هر وقت خواستید می‌توانید خاموشش کنید.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('نه'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('موافقم'),
          ),
        ],
      ),
    );
    if (ok == true) await AbtinDebugReporter.setAutoSend(true);
  }

  Future<void> _sendNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final opened = await AbtinDebugReporter.openMailFallback();
    if (!opened) {
      messenger?.showSnackBar(const SnackBar(
          content: Text('برنامهٔ ایمیل پیدا نشد؛ از «ارسال فایل کامل» یا «کپی» استفاده کنید')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.78;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: AbtinDebug.dump()));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('لاگ کپی شد')),
                    );
                  },
                  child: const Text('کپی'),
                ),
                OutlinedButton(
                  onPressed: () {
                    final s = snapshot?.call();
                    if (s != null) AbtinDebug.log('SNAPSHOT', s);
                  },
                  child: const Text('ثبت وضعیت فعلی'),
                ),
                OutlinedButton(
                  onPressed: AbtinDebug.clear,
                  child: const Text('پاک کردن'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendNow(context),
                  child: const Text('ایمیل به توسعه‌دهنده'),
                ),
                OutlinedButton(
                  onPressed: () => AbtinDebugReporter.shareLogFile(),
                  child: const Text('ارسال فایل کامل'),
                ),
              ],
            ),
          ),
          if (AbtinDebugReporter.hasEndpoint)
          ValueListenableBuilder<bool>(
            valueListenable: AbtinDebugReporter.autoSend,
            builder: (context, on, _) => SwitchListTile(
              dense: true,
              value: on,
              title: const Text(
                'ارسال خودکار گزارش مشکلات',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: const Text(
                'هنگام بروز هنگ نقشه یا خطا، لاگ برای توسعه‌دهنده ایمیل می‌شود',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
              onChanged: (v) => _toggleAuto(context, v),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: AbtinDebug.revision,
              builder: (context, _, __) {
                final text = AbtinDebug.dump();
                return SingleChildScrollView(
                  reverse: true,
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    text.isEmpty ? '(خالی)' : text,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      height: 1.35,
                      fontFamily: 'monospace',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
