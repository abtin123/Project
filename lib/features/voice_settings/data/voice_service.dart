import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:just_audio/just_audio.dart';

import 'voice_pack_catalog.dart';

enum VoiceState { playing, stopped }

/// راهنمای مسیر از یک فایل دانلودی واحد پخش می‌شود. هر فرمان فقط با seek به
/// بازهٔ cue خودش اجرا می‌شود؛ فایل‌های جمله‌ای و چسباندن صوت در دستگاه نداریم.
class VoiceService extends ChangeNotifier {
  VoiceService({VoicePackService? packs})
      : _packs = packs ?? VoicePackService() {
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) _finish();
    });
    _player.positionStream.listen(_stopAtCueBoundary);
  }

  final VoicePackService _packs;
  // افزایندهٔ بلندی (LoudnessEnhancer) اندروید: سقف volume در just_audio همان 1.0
  // است و فایل‌های صوتی بسته‌ی صدا کم‌سطح‌اند؛ این افکت سطح خروجی را بالا می‌برد.
  static const double _maxBoostDb = 4.0;
  late final AndroidLoudnessEnhancer? _enhancer =
      Platform.isAndroid ? AndroidLoudnessEnhancer() : null;
  late final AndroidLoudnessEnhancer? _beepEnhancer =
      Platform.isAndroid ? AndroidLoudnessEnhancer() : null;
  late final AudioPlayer _player = _newPlayer(_enhancer);
  late final AudioPlayer _alertBeepPlayer = _newPlayer(_beepEnhancer);

  static AudioPlayer _newPlayer(AndroidLoudnessEnhancer? enhancer) =>
      AudioPlayer(
        audioPipeline: enhancer == null
            ? null
            : AudioPipeline(androidAudioEffects: [enhancer]),
      );

  static Future<void>? _sessionReady;

  /// صدای راهنما به‌صورت «گفتار ناوبری» ثبت می‌شود و موزیک پس‌زمینه فقط کم
  /// می‌شود (duck) و قطع نمی‌شود.
  static Future<void> _configureSession() {
    return _sessionReady ??= () async {
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.duckOthers,
          avAudioSessionMode: AVAudioSessionMode.voicePrompt,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.assistanceNavigationGuidance,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ));
      } catch (_) {
        _sessionReady = null;
      }
    }();
  }

  Future<void> _applyGain() async {
    for (final e in <AndroidLoudnessEnhancer?>[_enhancer, _beepEnhancer]) {
      if (e == null) continue;
      try {
        await e.setEnabled(true);
        await e.setTargetGain(_maxBoostDb * _volume);
      } catch (_) {}
    }
  }
  bool _beepLoaded = false;
  VoiceState _state = VoiceState.stopped;
  bool _disposed = false;
  double _volume = 1.0;
  double _playbackRate = 1.0;
  int _generation = 0;
  final List<_VoiceRequest> _queue = <_VoiceRequest>[];
  bool _queueRunning = false;
  final Map<String, DateTime> _lastQueuedAt = <String, DateTime>{};
  Timer? _cueStopTimer;
  Duration? _activeCueEnd;
  int _activeCueGeneration = 0;
  String? _activeDownloadedVoice;
  String? _loadedAudioPath;
  Future<void>? _activePreload;
  Completer<void>? _cueDone;

  VoiceState get state => _state;

  void setActiveDownloadedVoice(String? fileName) {
    _activeDownloadedVoice = fileName;
    if (fileName != null && fileName.isNotEmpty) {
      _activePreload = _preloadVoiceBundle(fileName);
      unawaited(_activePreload!);
    } else {
      _activePreload = null;
    }
  }

  /// نمونه نیز هرگز فایل کامل نیست: یک cue قابل‌فهم از همان ABV حداکثر برای
  /// چند ثانیه پخش می‌شود و با همان guard انتهای cue متوقف خواهد شد.
  Future<bool> playDownloadedSample(String fileName) =>
      _playShortPreviewCue(fileName);

  Future<void> playAlert() async {
    await playAlertBeep();
  }

  /// مستقل از Voice Pack، برای هشدارهای جاده‌ای همیشه یک بوق کوتاه محلی
  /// وجود دارد؛ بنابراین نبودن/قدیمی بودن بسته صوتی هیچ‌وقت هشدار را بی‌صدا نمی‌کند.
  Future<void> playAlertBeep() async {
    try {
      await _configureSession();
      if (!_beepLoaded) {
        await _alertBeepPlayer.setAsset('assets/audio/navigation_alert_beep.wav');
        _beepLoaded = true;
      }
      await _applyGain();
      await _alertBeepPlayer.setVolume(_volume);
      await _alertBeepPlayer.seek(Duration.zero);
      unawaited(_alertBeepPlayer.play());
    } catch (_) {
      _beepLoaded = false;
      // هشدار بصری همچنان نمایش داده می‌شود حتی اگر موتور صوتی دستگاه خطا دهد.
    }
  }

  /// پخش دقیق یک cue از فایل واحد انتخاب‌شده. در بسته‌های قدیمی که cue ندارند
  /// هیچ صدایی پخش نمی‌شود تا به‌اشتباه کل فایل به‌جای یک فرمان شنیده نشود.
  Future<bool> playCue(String cue) => playGuidance(chain: <String>[cue]);

  /// یک اعلام کامل: [prefix] اختیاری (مثل `in_200m`) و بعد اولین cueی از
  /// [chain] که در بستهٔ فعال وجود دارد. دو بخش پشت‌سرهم و بدون قطع‌شدن
  /// یکدیگر پخش می‌شوند.
  Future<bool> playGuidance({String? prefix, required List<String> chain}) async {
    final selected = _activeDownloadedVoice;
    if (selected == null || selected.isEmpty || chain.isEmpty) return false;

    // GPS چند بار در ثانیه همان مانور را می‌خواهد؛ یک اعلام یکسان در ۷ ثانیه
    // فقط یک‌بار وارد صف می‌شود.
    final key = '$selected|${prefix ?? ''}|${chain.first}';
    final now = DateTime.now();
    final last = _lastQueuedAt[key];
    if (last != null && now.difference(last) < const Duration(seconds: 7)) {
      return false;
    }
    _lastQueuedAt[key] = now;

    final request = _VoiceRequest(
      fileName: selected,
      prefix: prefix,
      chain: List<String>.unmodifiable(chain),
      priority: _voicePriority(chain.first),
      createdAt: now,
    );
    _queue.add(request);
    _queue.sort((a, b) => b.priority.compareTo(a.priority));
    unawaited(_drainVoiceQueue());
    return true;
  }

  int _voicePriority(String cue) {
    final c = cue.toLowerCase();
    if (c.contains('off_route') || c.contains('recalculating') ||
        c.contains('arriv')) return 100;
    if (c.contains('roundabout') || c.contains('u_turn')) return 90;
    if (c.contains('turn')) return 80;
    if (c.contains('continue') || c.contains('straight')) return 50;
    return 40;
  }

  Future<void> _drainVoiceQueue() async {
    if (_queueRunning || _disposed) return;
    _queueRunning = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final request = _queue.removeAt(0);
        // اعلامی که پشت صف مانده و دیگر به‌روز نیست (مانور رد شده) گفته نمی‌شود.
        final age = DateTime.now().difference(request.createdAt);
        if (age > const Duration(seconds: 10) && request.priority < 100) continue;

        final bundle = await _packs.playableVoiceBundle(request.fileName);
        if (bundle == null) continue;
        String? main;
        for (final cue in request.chain) {
          if (bundle.cues.containsKey(cue)) {
            main = cue;
            break;
          }
        }
        if (main == null) continue; // هیچ cueی در بسته نیست؛ بوق/کارت بصری کافی است.
        final prefix = request.prefix;
        if (prefix != null && bundle.cues.containsKey(prefix)) {
          await _playCueAndWait(request.fileName, prefix);
        }
        await _playCueAndWait(request.fileName, main);
      }
    } finally {
      _queueRunning = false;
    }
  }

  /// پخش یک cue و منتظر ماندن تا همان cue تمام شود؛ بدون این انتظار فرمان بعدی
  /// صف، فرمان قبلی را وسط جمله قطع می‌کرد.
  Future<void> _playCueAndWait(String fileName, String cue) async {
    final started = await _playCueFromFile(fileName, cue);
    if (!started) return;
    final done = _cueDone;
    if (done == null) return;
    await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
  }

  Future<bool> _playShortPreviewCue(
    String fileName, {
    String? preferredCue,
  }) async {
    final bundle = await _packs.playableVoiceBundle(fileName);
    if (bundle == null || bundle.cues.isEmpty) return false;
    const candidates = <String>[
      'sample',
      'continue_straight',
      'straight',
      'turn_right',
      'turn_left',
      'speed_camera_ahead',
    ];
    final cueName =
        preferredCue != null && bundle.cues.containsKey(preferredCue)
            ? preferredCue
            : candidates.firstWhere(
                bundle.cues.containsKey,
                orElse: () => bundle.cues.keys.first,
              );
    return _playCueFromFile(
      fileName,
      cueName,
      previewLimit: const Duration(seconds: 4),
    );
  }

  Future<bool> _playCueFromFile(
    String fileName,
    String cueName, {
    Duration? previewLimit,
  }) async {
    final generation = ++_generation;
    _cueStopTimer?.cancel();
    _activeCueEnd = null;
    final previousDone = _cueDone;
    if (previousDone != null && !previousDone.isCompleted) previousDone.complete();
    _cueDone = Completer<void>();
    try {
      if (fileName == _activeDownloadedVoice) await _activePreload;
      final bundle = await _packs.playableVoiceBundle(fileName);
      final cue = bundle?.cues[cueName];
      if (bundle == null || cue == null || generation != _generation)
        return false;
      await _configureSession();
      await _player.stop();
      // فایل ABV فقط در اولین فرمان یا پس از تغییر صدا باز می‌شود. فرمان‌های
      // بعدی صرفاً seek روی decoder آماده‌اند و تاخیر ساخت/دانلود صوت ندارند.
      if (_loadedAudioPath != bundle.file.path) {
        await _player.setAudioSource(AudioSource.uri(bundle.file.uri));
        _loadedAudioPath = bundle.file.path;
      }
      if (generation != _generation) return false;
      await _applyGain();
      await _player.setVolume(_volume);
      await _player.setSpeed(_playbackRate);
      await _player.seek(cue.start);
      final previewEndMs = cue.start.inMilliseconds +
          (previewLimit?.inMilliseconds ??
              (cue.end - cue.start).inMilliseconds);
      final limitedEnd = Duration(
        milliseconds: previewEndMs < cue.end.inMilliseconds
            ? previewEndMs
            : cue.end.inMilliseconds,
      );
      _activeCueEnd = limitedEnd;
      _activeCueGeneration = generation;
      // play() در just_audio تا پایان پخش تمام نمی‌شود؛ پس اول وضعیت و تایمر
      // انتهای cue تنظیم می‌شود و بعد منتظر پایان همان cue می‌مانیم.
      final playing = _player.play();
      _state = VoiceState.playing;
      _notify();
      final duration = limitedEnd - cue.start;
      final realDuration = Duration(
          milliseconds: (duration.inMilliseconds / _playbackRate).ceil());
      _cueStopTimer = Timer(
        realDuration + const Duration(milliseconds: 80),
        () => unawaited(_finishCueAtBoundary(generation)),
      );
      await playing;
      return true;
    } catch (error) {
      
      return false;
    }
  }

  /// علاوه بر timer، موقعیت واقعی decoder هم کنترل می‌شود تا پخش هیچ‌وقت از
  /// انتهای cue JSON عبور نکند؛ حتی با تغییر سرعت پخش یا تأخیر زمان‌سنج.
  void _stopAtCueBoundary(Duration position) {
    final end = _activeCueEnd;
    if (end == null || position < end || _activeCueGeneration != _generation)
      return;
    unawaited(_finishCueAtBoundary(_activeCueGeneration));
  }

  Future<void> _finishCueAtBoundary(int generation) async {
    if (generation != _generation || _activeCueEnd == null) return;
    _activeCueEnd = null;
    _cueStopTimer?.cancel();
    await _player.stop();
    _finish();
  }

  /// بستهٔ انتخاب‌شده را پس از انتخاب کاربر، پیش از شروع مسیریابی باز می‌کند.
  /// این فراخوانی عمداً await نمی‌شود تا UI تنظیمات مکث نکند؛ فرمان بعدی فقط
  /// روی decoder بازشده seek خواهد شد.
  Future<void> _preloadVoiceBundle(String fileName) async {
    try {
      final bundle = await _packs.playableVoiceBundle(fileName);
      if (bundle == null || _activeDownloadedVoice != fileName) return;
      if (_loadedAudioPath != bundle.file.path) {
        await _player.setAudioSource(AudioSource.uri(bundle.file.uri));
        _loadedAudioPath = bundle.file.path;
      }
    } catch (error) {
      // خطای preload نباید انتخاب بسته را باطل کند؛ _playCueFromFile در زمان
      // فرمان دوباره تلاش می‌کند و خطای واقعی را ثبت می‌کند.
      
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    await _applyGain();
  }

  Future<void> setPlaybackRate(double rate) async {
    _playbackRate = rate.clamp(0.5, 2.0);
    await _player.setSpeed(_playbackRate);
  }

  Future<void> stop() async {
    _generation++;
    _cueStopTimer?.cancel();
    _activeCueEnd = null;
    await _player.stop();
    _finish();
  }

  void _finish() {
    _state = VoiceState.stopped;
    final done = _cueDone;
    if (done != null && !done.isCompleted) done.complete();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cueStopTimer?.cancel();
    _activeCueEnd = null;
    _player.dispose();
    _alertBeepPlayer.dispose();
    super.dispose();
  }
}

class _VoiceRequest {
  const _VoiceRequest({
    required this.fileName,
    required this.chain,
    required this.priority,
    required this.createdAt,
    this.prefix,
  });
  final String fileName;
  final String? prefix;
  final List<String> chain;
  final int priority;
  final DateTime createdAt;
}
