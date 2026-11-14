import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_debugger.dart';

/// In-app debugger: Dart log, Android native log, logcat, system snapshot.
class DebugConsoleScreen extends StatefulWidget {
  const DebugConsoleScreen({super.key});

  @override
  State<DebugConsoleScreen> createState() => _DebugConsoleScreenState();
}

class _DebugConsoleScreenState extends State<DebugConsoleScreen> {
  DbgLevel _min = DbgLevel.debug;
  String _query = '';

  Color _color(DbgLevel l) => switch (l) {
        DbgLevel.debug => const Color(0xFF8A94A6),
        DbgLevel.info => const Color(0xFFD7DEE9),
        DbgLevel.warn => const Color(0xFFFFC857),
        DbgLevel.error => const Color(0xFFFF6B6B),
        DbgLevel.fatal => const Color(0xFFFF2E63),
      };

  void _toast(String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  Future<void> _copyAll() async {
    final text = await AppDebugger.instance.buildReport();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _toast('گزارش کامل کپی شد');
  }

  Future<void> _share() async {
    _toast('در حال ساخت گزارش…');
    await AppDebugger.instance.shareReport();
  }

  Future<void> _save() async {
    final p = await AppDebugger.instance.saveReport();
    if (mounted) _toast(p == null ? 'ذخیره نشد' : 'ذخیره شد: $p');
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTabController(
        length: 4,
        child: Scaffold(
          backgroundColor: const Color(0xFF0A0D12),
          appBar: AppBar(
            backgroundColor: const Color(0xFF11161E),
            foregroundColor: Colors.white,
            title: const Text('Debugger', style: TextStyle(fontSize: 16)),
            actions: [
              IconButton(
                tooltip: 'Copy full report',
                icon: const Icon(Icons.copy_all_rounded),
                onPressed: _copyAll,
              ),
              IconButton(
                tooltip: 'Share report file',
                icon: const Icon(Icons.ios_share_rounded),
                onPressed: _share,
              ),
              IconButton(
                tooltip: 'Save report to log folder',
                icon: const Icon(Icons.save_alt_rounded),
                onPressed: _save,
              ),
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  await AppDebugger.instance.clear();
                  if (mounted) setState(() {});
                },
              ),
            ],
            bottom: const TabBar(
              isScrollable: true,
              labelColor: Color(0xFF2FE6C4),
              unselectedLabelColor: Colors.white60,
              indicatorColor: Color(0xFF2FE6C4),
              tabs: [
                Tab(text: 'Dart'),
                Tab(text: 'Android'),
                Tab(text: 'Logcat'),
                Tab(text: 'System'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _dartTab(),
              const _TextTab(loader: _loadNative, autoRefresh: true),
              const _TextTab(loader: _loadLogcat),
              const _SystemTab(),
            ],
          ),
        ),
      ),
    );
  }

  static Future<String> _loadNative() => AppDebugger.instance.nativeLog();
  static Future<String> _loadLogcat() => AppDebugger.instance.logcat(1500);

  Widget _dartTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'filter…',
                    hintStyle: TextStyle(color: Colors.white38),
                    prefixIcon: Icon(Icons.search, size: 18, color: Colors.white54),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v.toLowerCase()),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<DbgLevel>(
                value: _min,
                dropdownColor: const Color(0xFF11161E),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                underline: const SizedBox.shrink(),
                items: [
                  for (final l in DbgLevel.values)
                    DropdownMenuItem(value: l, child: Text('≥ ${l.name}')),
                ],
                onChanged: (v) => setState(() => _min = v ?? DbgLevel.debug),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: AppDebugger.instance.revision,
            builder: (context, _, __) {
              final all = AppDebugger.instance.entries;
              final list = all
                  .where((e) =>
                      e.level.index >= _min.index &&
                      (_query.isEmpty || e.line.toLowerCase().contains(_query)))
                  .toList(growable: false);
              if (list.isEmpty) {
                return const Center(
                  child: Text('no entries', style: TextStyle(color: Colors.white54)),
                );
              }
              return ListView.builder(
                reverse: true,
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final e = list[list.length - 1 - i];
                  return InkWell(
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: e.line));
                      _toast('copied');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
                      child: Text(
                        e.line,
                        style: TextStyle(
                          color: _color(e.level),
                          fontSize: 11,
                          fontFamily: 'monospace',
                          height: 1.25,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TextTab extends StatefulWidget {
  const _TextTab({required this.loader, this.autoRefresh = false});
  final Future<String> Function() loader;
  final bool autoRefresh;

  @override
  State<_TextTab> createState() => _TextTabState();
}

class _TextTabState extends State<_TextTab> {
  String _text = 'loading…';
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.autoRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    }
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    final t = await widget.loader();
    _busy = false;
    if (mounted) setState(() => _text = t.isEmpty ? '(empty)' : t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SingleChildScrollView(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 72),
          child: SelectableText(
            _text,
            style: const TextStyle(
              color: Color(0xFFD7DEE9),
              fontSize: 10.5,
              fontFamily: 'monospace',
              height: 1.25,
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: FloatingActionButton.small(
            backgroundColor: const Color(0xFF2FE6C4),
            foregroundColor: Colors.black,
            onPressed: _load,
            child: const Icon(Icons.refresh_rounded),
          ),
        ),
      ],
    );
  }
}

class _SystemTab extends StatefulWidget {
  const _SystemTab();

  @override
  State<_SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<_SystemTab> {
  String _snap = 'loading…';
  String _crash = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppDebugger.instance.nativeSnapshot();
    final c = await AppDebugger.instance.lastCrash();
    if (mounted) {
      setState(() {
        _snap = s;
        _crash = c;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = AppDebugger.instance;
    const style = TextStyle(
        color: Color(0xFFD7DEE9), fontSize: 12, fontFamily: 'monospace', height: 1.35);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('app: ${d.appInfo}\nuptime: ${DateTime.now().difference(d.startedAt)}\n'
            'errors since start: ${d.errorCount}\nlog folder: ${d.logDir?.path}',
            style: style),
        const SizedBox(height: 12),
        if (d.previousSessionVerdict != null)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x33FF2E63),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Text(d.previousSessionVerdict!,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        const SizedBox(height: 12),
        Text(_snap, style: style),
        if (_crash.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('LAST NATIVE CRASH', style: TextStyle(color: Color(0xFFFF6B6B))),
          Text(_crash, style: style),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: d.openBatterySettings,
              child: const Text('Battery optimization settings'),
            ),
            OutlinedButton(
              onPressed: () {
                Future<void>(() => throw StateError('TEST async error from debugger'));
              },
              child: const Text('Test: async error'),
            ),
            OutlinedButton(
              onPressed: _load,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Small bug button shown on top of the app when something went wrong
/// (abnormal previous exit or errors since launch).
class DebugBadge extends StatelessWidget {
  const DebugBadge({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final d = AppDebugger.instance;
    return ValueListenableBuilder<int>(
      valueListenable: d.revision,
      builder: (context, _, __) {
        final show = d.previousSessionVerdict != null || d.errorCount > 0;
        if (!show) return const SizedBox.shrink();
        final top = MediaQuery.of(context).padding.top;
        return Positioned(
          left: 8,
          top: top + 6,
          child: Material(
            color: const Color(0xCCFF2E63),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bug_report_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      d.errorCount > 0 ? '${d.errorCount}' : '!',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
