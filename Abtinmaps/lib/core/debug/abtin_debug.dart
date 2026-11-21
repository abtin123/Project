import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// دیباگر داخلی: رویدادهای مسیریابی/ناوبری/رسم مسیر را در حافظه نگه می‌دارد و
/// از «تنظیمات ← گزارش خطا (دیباگ)» قابل مشاهده و کپی است.
class AbtinDebug {
  AbtinDebug._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
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
              ],
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
