import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/automix/set_flow.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/engine/native_engine.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/engine/usb_output.dart';
import 'package:sidedeck/state/automix_math.dart';

class DeckState {
  String? path;
  String title = 'Empty';
  String artist = '';
  bool loaded = false;
  bool playing = false;
  bool loopEnabled = false;
  double loopBars = 1;
  double loopStart = 0;
  double loopEnd = 0;
  double position = 0;
  double duration = 0;
  double bpm = 0;
  int key = -1;
  double rate = 1;
  // Key lock keeps the pitch fixed when tempo changes. The engine starts with
  // it on, so the app starts with it on too.
  bool keylock = true;
  /// Whole semitones the key is moved up or down (needs key lock on).
  int keyShift = 0;
  /// Deck is sent to the headphone cue bus.
  bool cue = false;

  /// The key as it sounds now: the detected key moved by [keyShift].
  int get soundingKey {
    if (key < 0 || key > 23) return key;
    final minor = key >= 12;
    final root = ((key % 12 + keyShift) % 12 + 12) % 12;
    return root + (minor ? 12 : 0);
  }
  /// Hot cue times in seconds, -1 when not set. Eight pads per deck.
  final List<double> hotcues = List<double>.filled(8, -1);
  bool synced = false;
  double beatOffset = 0;
  double gain = 1;
  double fader = 1;
  double filter = 0;
  double eqLow = 0;
  double eqMid = 0;
  double eqHigh = 0;
  Float32List waveMin = Float32List(0);
  Float32List waveMax = Float32List(0);
}

class DjController extends ChangeNotifier {
  DjController() {
    _engine = NativeEngine.open();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    if (!_engine.started) {
      engineError = 'Audio engine failed to start.';
    }
    restoreSamples();
    loadDeckSetting();
    if (Platform.isAndroid) {
      _usbSub = UsbOutput.events().listen(_onUsbEvent);
    }
  }

  late final NativeEngine _engine;
  late final Timer _ticker;
  StreamSubscription<UsbHotplugEvent>? _usbSub;
  final AnalysisCache _analysisCache = AnalysisCache.instance;
  final Set<int> _declinedMixerIds = {};

  final DeckState deckA = DeckState();
  final DeckState deckB = DeckState();
  final DeckState deckC = DeckState();
  final DeckState deckD = DeckState();
  static const int deckCount = 4;
  double xfader = 0.5;
  double master = 1.0;
  bool externalMixer = false;
  String usbDeviceName = '';
  int usbDeviceId = 0;
  UsbMixerOffer? mixerOffer;
  String? engineError;
  int? loadingDeck;
  String? loadingTitle;
  String? loadingPath;

  // Master graphic equaliser (10 bands) and spectrum analyser (14 bands).
  static const int eqBandCount = 10;
  static const int spectrumBandCount = NativeEngine.spectrumBands;
  final List<double> eqBands = List<double>.filled(eqBandCount, 0);
  final List<double> spectrum = List<double>.filled(spectrumBandCount, 0);
  final List<double> spectrumPeak = List<double>.filled(spectrumBandCount, 0);
  final List<int> _peakHold = List<int>.filled(spectrumBandCount, 0);
  bool spectrumOn = false;
  bool effectsOn = false;
  bool stripOn = false; // compact spectrum strip at the top of the controller

  /// The party effects need the levels too, even off the equaliser screen.
  void setEffectsOn(bool on) {
    effectsOn = on;
  }

  // Master effect: 0 off, 1 echo, 2 reverb, 3 flanger.
  int fxType = 0;
  double fxAmount = 0.5;
  double fxBeats = 0.5; // echo length / flanger speed

  double _heardBpm() {
    for (var i = 0; i < deckCount; i++) {
      final d = deck(i);
      if (d.playing && d.bpm > 1) return d.bpm * d.rate;
    }
    return 120;
  }

  // ---- Mix recording and tracklist.
  bool recording = false;
  double recordSeconds = 0;
  String? lastRecordingPath;
  final List<(double, String)> _trackLog = [];
  final List<String> _loggedFor = ['', '', '', ''];
  String? recordDirectory;

  /// Starts recording the master output into [dir]. Returns the file path,
  /// or null if it could not start.
  String? startRecording(String dir) {
    if (recording) return null;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final path = '$dir/BeatDeck mix ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}.${two(now.minute)}.wav';
    if (!_engine.recordStart(path)) return null;
    recording = true;
    recordSeconds = 0;
    lastRecordingPath = path;
    _trackLog.clear();
    for (var i = 0; i < 4; i++) {
      _loggedFor[i] = '';
    }
    // Anything already playing starts the list.
    for (var i = 0; i < deckCount; i++) {
      if (deck(i).playing) _logTrack(i);
    }
    notifyListeners();
    return path;
  }

  /// Stops recording and writes a tracklist text file next to the audio.
  String? stopRecording() {
    if (!recording) return null;
    _engine.recordStop();
    recording = false;
    final path = lastRecordingPath;
    if (path != null && _trackLog.isNotEmpty) {
      String ts(double s) {
        final m = (s ~/ 60).toString().padLeft(2, '0');
        final sec = (s.floor() % 60).toString().padLeft(2, '0');
        return '$m:$sec';
      }
      final text = [
        for (final e in _trackLog) '${ts(e.$1)}  ${e.$2}',
      ].join('\n');
      try {
        File(path.replaceFirst(RegExp(r'\.wav$'), '.txt'))
            .writeAsStringSync('$text\n');
      } catch (_) {}
    }
    notifyListeners();
    return path;
  }

  void _logTrack(int deckIndex) {
    if (!recording) return;
    final d = deck(deckIndex);
    final id = d.path ?? d.title;
    if (_loggedFor[deckIndex] == id) return;
    _loggedFor[deckIndex] = id;
    final name = d.artist.isEmpty ? d.title : '${d.artist} - ${d.title}';
    _trackLog.add((_engine.recordSeconds(), name));
  }

  /// The eight effect pads. Each pad holds one effect; any pad can be given
  /// any effect.
  static const fxNames = [
    'ECHO', 'REVERB', 'FLANGER', 'PHASER', 'FILTER', 'CRUSH', 'NOISE', 'ROLL',
  ];
  final List<List<int>> padFx =
      List.generate(4, (_) => List<int>.generate(8, (i) => i));
  final List<Set<int>> deckFxOn = List.generate(4, (_) => <int>{});

  void toggleDeckFx(int deckIndex, int pad) {
    final e = padFx[deckIndex][pad];
    final on = deckFxOn[deckIndex];
    if (!on.add(e)) on.remove(e);
    _applyDeckFx(deckIndex);
    notifyListeners();
  }

  void assignPadFx(int deckIndex, int pad, int effect) {
    deckFxOn[deckIndex].remove(padFx[deckIndex][pad]);
    padFx[deckIndex][pad] = effect.clamp(0, 7);
    _applyDeckFx(deckIndex);
    notifyListeners();
  }

  void _applyDeckFx(int deckIndex) {
    var mask = 0;
    for (final e in deckFxOn[deckIndex]) {
      mask |= 1 << e;
    }
    final d = deck(deckIndex);
    final heard = d.bpm > 1 ? d.bpm * d.rate : 120.0;
    _engine.setDeckFx(deckIndex, mask, fxAmount, fxBeats * 60 / heard);
  }

  void setFx({int? type, double? amount, double? beats}) {
    if (type != null) fxType = type.clamp(0, 3);
    if (amount != null) fxAmount = amount.clamp(0.0, 1.0).toDouble();
    if (beats != null) fxBeats = beats;
    _applyFx();
    for (var i = 0; i < deckCount; i++) {
      if (deckFxOn[i].isNotEmpty) _applyDeckFx(i);
    }
    notifyListeners();
  }

  void _applyFx() {
    final sec = fxType == 3 ? fxBeats * 4 : fxBeats * 60 / _heardBpm();
    _engine.setFx(fxType, fxAmount, sec);
  }

  void setStripOn(bool on) {
    stripOn = on;
    notifyListeners();
  }

  void setMasterEq(int band, double db) {
    if (band < 0 || band >= eqBandCount) return;
    eqBands[band] = db.clamp(-12.0, 12.0).toDouble();
    _engine.setMasterEq(band, eqBands[band]);
    notifyListeners();
  }

  void resetMasterEq() {
    for (var b = 0; b < eqBandCount; b++) {
      eqBands[b] = 0;
      _engine.setMasterEq(b, 0);
    }
    notifyListeners();
  }

  /// Turn on while the equaliser screen is showing; off saves a little CPU.
  void setSpectrumOn(bool on) {
    spectrumOn = on;
    if (!on) {
      for (var i = 0; i < spectrumBandCount; i++) {
        spectrum[i] = 0;
        spectrumPeak[i] = 0;
      }
    }
  }

  void _updateSpectrum() {
    final raw = _engine.spectrum();
    for (var i = 0; i < spectrumBandCount; i++) {
      final amp = raw[i];
      final db = amp > 1e-6 ? 20 * math.log(amp) / math.ln10 : -120.0;
      final level = ((db + 54) / 48).clamp(0.0, 1.0).toDouble();
      // Rise fast, fall slowly, like an old analyser.
      spectrum[i] = level > spectrum[i] ? level : spectrum[i] * 0.82 + level * 0.18;
      if (spectrum[i] >= spectrumPeak[i]) {
        spectrumPeak[i] = spectrum[i];
        _peakHold[i] = 14; // about 0.7 s at 50 ms per tick
      } else if (_peakHold[i] > 0) {
        _peakHold[i]--;
      } else {
        spectrumPeak[i] = math.max(0.0, spectrumPeak[i] - 0.03);
      }
    }
  }

  DeckState deck(int i) {
    switch (i) {
      case 0:
        return deckA;
      case 1:
        return deckB;
      case 2:
        return deckC;
      default:
        return deckD;
    }
  }

  void clearError() {
    engineError = null;
    notifyListeners();
  }

  void _onUsbEvent(UsbHotplugEvent event) {
    if (event.attached) {
      _onUsbAttached(event);
    } else {
      _onUsbDetached(event);
    }
  }

  void _onUsbAttached(UsbHotplugEvent event) {
    if (externalMixer) return;
    if (_declinedMixerIds.contains(event.id)) return;
    if (mixerOffer?.id == event.id) return;
    mixerOffer = UsbMixerOffer(
      id: event.id,
      channels: event.channels,
      name: event.name,
    );
    notifyListeners();
  }

  void _onUsbDetached(UsbHotplugEvent event) {
    _declinedMixerIds.remove(event.id);
    final offeringThis = mixerOffer?.id == event.id;
    if (offeringThis) mixerOffer = null;
    if (externalMixer && usbDeviceId == event.id) {
      final name = UsbOutput.deviceLabel(
        usbDeviceName.isEmpty ? event.name : usbDeviceName,
      );
      setExternalMixer(false).then((_) {
        engineError = '$name disconnected; audio is back on the phone.';
        notifyListeners();
      });
      return;
    }
    if (offeringThis) notifyListeners();
  }

  Future<void> acceptMixerOffer() async {
    mixerOffer = null;
    notifyListeners();
    await setExternalMixer(true);
  }

  void declineMixerOffer() {
    final id = mixerOffer?.id;
    if (id != null) _declinedMixerIds.add(id);
    mixerOffer = null;
    notifyListeners();
  }

  void _tick() {
    if (fxType == 1) _applyFx(); // echo length follows the tempo
    for (var i = 0; i < deckCount; i++) {
      if (deckFxOn[i].isNotEmpty) _applyDeckFx(i);
    }
    var dirty = false;
    if (recording) {
      recordSeconds = _engine.recordSeconds();
      dirty = true;
    }
    if (spectrumOn || effectsOn || stripOn) {
      _updateSpectrum();
      dirty = true;
    }
    for (var i = 0; i < deckCount; i++) {
      final d = deck(i);
      if (!d.loaded || !d.playing) continue;
      d.position = _engine.position(i);
      d.playing = _engine.isPlaying(i);
      if (d.loopEnabled) {
        _readLoop(i);
      }
      dirty = true;
    }
    if (_automixTick()) dirty = true;
    if (dirty) notifyListeners();
  }

  // ---- Decks 3 and 4 are hidden unless switched on in settings.
  bool showDecks34 = false;

  /// How many decks the screens offer.
  int get visibleDecks => showDecks34 ? 4 : 2;

  Future<void> loadDeckSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      showDecks34 = prefs.getBool('show_decks_34') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setShowDecks34(bool v) async {
    showDecks34 = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('show_decks_34', v);
    } catch (_) {}
  }

  /// Files that have been put on a deck, and files that would not load.
  final Set<String> loadedPaths = {};
  final Set<String> failedPaths = {};

  /// Tracks queued after the one now playing in automix.
  int get automixWaiting =>
      automixOn ? math.max(0, _automixQueue.length - _automixIndex - 1) : 0;

  /// A new track (for example a finished Soulseek download) joins the end of
  /// the automix queue if automix is running.
  void automixAppend(String path) {
    if (!automixOn || _automixQueue.contains(path)) return;
    if (_automixQueue.any((q) => _trackKey(q) == _trackKey(path))) return;
    _automixQueue.add(path);
    _flowLearn(path);
    notifyListeners();
  }

  // ---- Automix -----------------------------------------------------------
  // Plays a list of tracks one after another. Shortly before the playing deck
  // ends, the next track is loaded on the other deck, matched to the same
  // tempo, started on the same point in the beat, and crossfaded in.

  bool automixOn = false;
  /// How long before the end the mix starts (and how long it lasts).
  double automixFadeSeconds = 20;

  /// How far into the next track it starts playing, rounded to whole bars.
  double automixStartOffset = 10;
  String? automixStatus;
  List<String> _automixQueue = [];
  int _automixIndex = -1; // queue index of the track on the current deck
  int _automixDeck = -1; // deck playing that track
  int _automixNextTarget = -1;
  bool _automixBusy = false;
  bool _automixPreloaded = false;
  bool _automixFading = false;
  DateTime _automixFadeStart = DateTime.fromMillisecondsSinceEpoch(0);
  double _automixFadeFrom = 0;

  // Tracks already played this run, by a name that ignores copies such as
  // "Song (1)", so the same track is never mixed in twice.
  final Set<String> _automixPlayed = {};

  static String _trackKey(String path) {
    var name = path.split(RegExp(r'[\\/]')).last;
    name = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    name = name.replaceFirst(RegExp(r'\s*\(\d+\)$'), '');
    return name.toLowerCase().trim();
  }

  // ---- Set flow ----------------------------------------------------------
  SetFlow? _flow;
  double _baseFade = 20;
  int? _flowNext;
  String _flowMove = '?';
  final Map<String, FlowTrack> _flowInfo = {};
  String? flowStatus;

  Future<void> _flowLearn(String path) async {
    if (_flowInfo.containsKey(path)) return;
    var bpm = 0.0;
    CamelotKey? key;
    try {
      final stat = await File(path).stat();
      final a = await _analysisCache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
      if (a != null) {
        bpm = a.bpm;
        key = CamelotKey.fromIndex(a.key);
      }
    } catch (_) {}
    final name = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final hints = parseNameHints(name);
    if (bpm <= 0) bpm = hints.bpm ?? 0;
    key ??= hints.key;
    var artist = '';
    final dash = name.indexOf(' - ');
    if (dash > 0) artist = name.substring(0, dash).trim();
    _flowInfo[path] = FlowTrack(path, bpm: bpm, key: key, artist: artist);
  }

  FlowTrack? _flowOf(String path) => _flowInfo[path];

  /// The next queue entry that has not been played yet, or null.
  int? _nextUnplayed() {
    final flow = _flow;
    if (flow != null && flow.arc != FlowArc.off) {
      final held = _flowNext;
      if (held != null &&
          held > _automixIndex &&
          held < _automixQueue.length &&
          !_automixPlayed.contains(_trackKey(_automixQueue[held]))) {
        return held;
      }
      final cands = <(int, FlowTrack)>[];
      for (var i = _automixIndex + 1; i < _automixQueue.length; i++) {
        final path = _automixQueue[i];
        if (_automixPlayed.contains(_trackKey(path))) continue;
        cands.add((i, _flowOf(path) ?? FlowTrack(path)));
      }
      if (cands.isEmpty) return null;
      final cur = _automixIndex >= 0 && _automixIndex < _automixQueue.length
          ? _flowOf(_automixQueue[_automixIndex])
          : null;
      final pick = flow.pick(cur, cands);
      if (pick == null) return null;
      _flowNext = pick.index;
      _flowMove = pick.moveLabel;
      automixFadeSeconds = (_baseFade * flow.arc.fadeScale(pick.energy)).clamp(6.0, 60.0).toDouble();
      return pick.index;
    }
    for (var i = _automixIndex + 1; i < _automixQueue.length; i++) {
      if (!_automixPlayed.contains(_trackKey(_automixQueue[i]))) return i;
    }
    return null;
  }

  int get automixQueueLength => _automixQueue.length;
  int get automixIndex => _automixIndex;

  Future<void> startAutomix(
    List<String> paths, {
    double fadeSeconds = 20,
    double startOffsetSeconds = 10,
    FlowArc arc = FlowArc.off,
    double lengthMinutes = 60,
  }) async {
    if (paths.isEmpty) return;
    stopAutomix();
    // One copy of each track only.
    final seen = <String>{};
    _automixQueue = [
      for (final p in paths)
        if (seen.add(_trackKey(p))) p,
    ];
    _automixPlayed.clear();
    automixFadeSeconds = fadeSeconds.clamp(4.0, 60.0).toDouble();
    _baseFade = automixFadeSeconds;
    _flowNext = null;
    _flow = arc == FlowArc.off ? null : SetFlow(arc, lengthMinutes: lengthMinutes);
    for (final p in _automixQueue) {
      await _flowLearn(p);
    }
    automixStartOffset = startOffsetSeconds.clamp(0.0, 90.0).toDouble();
    automixOn = true;
    automixStatus = 'Loading first track';
    _automixBusy = true;
    notifyListeners();
    final ok = await loadFile(0, _automixQueue.first);
    _automixBusy = false;
    if (!automixOn) return; // stopped while loading
    if (!ok) {
      automixOn = false;
      automixStatus = 'Could not load the first track';
      notifyListeners();
      return;
    }
    if (deckB.playing) {
      _engine.play(1, false);
      deckB.playing = false;
    }
    setXfader(0.0);
    _engine.play(0, true);
    deckA.playing = true;
    _automixDeck = 0;
    _automixIndex = 0;
    _automixPlayed.add(_trackKey(_automixQueue.first));
    _automixPreloaded = false;
    _automixFading = false;
    automixStatus = null;
    notifyListeners();
  }

  void stopAutomix() {
    final wasOn = automixOn;
    automixOn = false;
    _automixFading = false;
    _automixPreloaded = false;
    _automixDeck = -1;
    _automixIndex = -1;
    _flowNext = null;
    _flow = null;
    if (wasOn) {
      automixStatus = null;
      notifyListeners();
    }
  }

  /// Returns true if something on screen changed.
  bool _automixTick() {
    if (!automixOn || _automixBusy || _automixDeck < 0) return false;
    if (_automixFading) {
      _automixAdvanceFade();
      return true;
    }
    final cur = _automixDeck;
    final other = 1 - cur;
    final d = deck(cur);
    if (!d.loaded || !d.playing) return false; // paused by the DJ: wait
    final remaining = remainingSeconds(
      position: d.position,
      duration: d.duration,
      rate: d.rate,
    );
    final next = _nextUnplayed();
    if (next == null) {
      if (remaining <= 0.5) {
        automixOn = false;
        automixStatus = 'Automix finished';
        return true;
      }
      return false;
    }
    if (!_automixPreloaded) {
      if (shouldPreload(remaining: remaining, fadeSeconds: automixFadeSeconds)) {
        _automixBusy = true;
        final path = _automixQueue[next];
        loadFile(other, path).then((ok) {
          _automixBusy = false;
          if (!automixOn) return;
          if (ok) {
            _automixPreloaded = true;
          } else {
            // Skip a track that will not load.
            _automixQueue.removeAt(next);
            _flowNext = null;
            automixStatus = 'Skipped a track that would not load';
          }
          notifyListeners();
        });
      }
      return false;
    }
    if (shouldStartFade(remaining: remaining, fadeSeconds: automixFadeSeconds)) {
      _automixBeginFade(cur, other, next);
      return true;
    }
    return false;
  }

  void _automixBeginFade(int cur, int other, int next) {
    final out = deck(cur);
    final inc = deck(other);
    final outPosition = _engine.position(cur);
    inc.rate = incomingRate(
      outBpm: out.bpm,
      outRate: out.rate,
      inBpm: inc.bpm,
    );
    inc.synced = false;
    _applyRate(other);
    final startRaw = incomingStartPosition(
      outPosition: outPosition,
      outBpm: out.bpm,
      outBeatOffset: out.beatOffset,
      inBpm: inc.bpm,
      inBeatOffset: inc.beatOffset,
    );
    // Skip the first part of the next track, in whole bars so the beats still line up.
    var offset = automixStartOffset;
    if (inc.bpm > 1 && offset > 0) {
      final bar = 4 * 60.0 / inc.bpm;
      offset = (offset / bar).round() * bar;
    }
    final room = math.max(0.0, inc.duration - automixFadeSeconds - 5);
    final start = math.min(startRaw + offset, room).clamp(0.0, math.max(0.0, inc.duration)).toDouble();
    _engine.seek(other, start);
    inc.position = start;
    _automixFadeFrom = crossfaderEndFor(cur);
    xfader = _automixFadeFrom;
    _engine.setXfader(xfader);
    _engine.play(other, true);
    inc.playing = true;
    _automixFadeStart = DateTime.now();
    _automixNextTarget = next;
    _automixFading = true;
    automixStatus = null;
  }

  void _automixAdvanceFade() {
    final cur = _automixDeck;
    final other = 1 - cur;
    final elapsed =
        DateTime.now().difference(_automixFadeStart).inMilliseconds / 1000.0;
    xfader = crossfaderAt(
      elapsed: elapsed,
      fadeSeconds: automixFadeSeconds,
      from: _automixFadeFrom,
      to: crossfaderEndFor(other),
    );
    _engine.setXfader(xfader);
    if (elapsed >= automixFadeSeconds) {
      _engine.play(cur, false);
      deck(cur).playing = false;
      _automixDeck = other;
      final prevTrack = _flowOf(_automixQueue[_automixIndex]);
      _automixIndex = _automixNextTarget;
      _automixPlayed.add(_trackKey(_automixQueue[_automixIndex]));
      if (prevTrack != null) _flow?.played(prevTrack, _flowMove);
      _flowNext = null;
      _automixPreloaded = false;
      _automixFading = false;
    }
  }

  Future<bool> loadFile(
    int deckIndex,
    String path, {
    String? title,
    String? artist,
  }) async {
    loadingDeck = deckIndex;
    loadingTitle = title ?? path.split(RegExp(r'[\\/]')).last;
    loadingPath = path;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 16));

    TrackAnalysis? cached;
    try {
      final stat = await File(path).stat();
      cached = await _analysisCache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {}

    final ok = _engine.load(
      deckIndex,
      path,
      bpm: cached?.bpm,
      key: cached?.key,
      beatOffset: cached?.beatOffset,
    );
    final d = deck(deckIndex);
    if (!ok) {
      loadingDeck = null;
      loadingTitle = null;
      loadingPath = null;
      failedPaths.add(path);
      final name = title ?? path.split(RegExp(r'[\\/]')).last;
      final detail = _engine.lastError();
      engineError = detail.isNotEmpty
          ? 'Could not load $name - $detail'
          : 'Could not decode $name (need MP3, WAV, FLAC, Opus, or AAC M4A).';
      notifyListeners();
      return false;
    }
    loadedPaths.add(path);
    d.path = path;
    d.title = title ?? path.split(RegExp(r'[\\/]')).last;
    d.artist = artist ?? '';
    d.loaded = true;
    d.playing = false;
    d.position = 0;
    d.duration = _engine.duration(deckIndex);
    d.bpm = _engine.bpm(deckIndex);
    d.key = _engine.key(deckIndex);
    d.keyShift = 0;
    _engine.setKeyShift(deckIndex, 0);
    d.beatOffset = _engine.beatOffset(deckIndex);
    d.rate = 1;
    d.synced = false;
    if (masterDeck == deckIndex) _followMasterBpm(deckIndex);
    d.hotcues.fillRange(0, d.hotcues.length, -1.0);
    d.loopEnabled = false;
    d.loopStart = 0;
    d.loopEnd = 0;
    final wave = _engine.waveform(deckIndex);
    d.waveMin = wave.min;
    d.waveMax = wave.max;
    _engine.setRate(deckIndex, 1);
    _nudgeBend[deckIndex] = 0;
    _engine.setGain(deckIndex, d.gain);
    _engine.setFader(deckIndex, d.fader);
    _engine.setFilter(deckIndex, d.filter);
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);

    if (cached == null) {
      try {
        final file = File(path);
        final stat = await file.stat();
        await _analysisCache.put(
          path: path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          bpm: d.bpm,
          key: d.key,
          beatOffset: d.beatOffset,
        );
      } catch (_) {}
    }

    loadingDeck = null;
    loadingTitle = null;
    loadingPath = null;
    _followMasterBpm(deckIndex);
    notifyListeners();
    return true;
  }

  /// Re-read a track that was just re-analyzed, so a deck holding it picks up
  /// the new BPM and beat grid instead of keeping the stale one.
  Future<void> reloadIfLoaded(
    String path, {
    String? title,
    String? artist,
  }) async {
    for (var i = 0; i < deckCount; i++) {
      final d = deck(i);
      if (d.path != path) continue;
      await loadFile(
        i,
        path,
        title: title ?? d.title,
        artist: artist ?? d.artist,
      );
    }
  }

  void playPause(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final next = !d.playing;
    _engine.play(deckIndex, next);
    d.playing = next;
    // A synced deck finds the master's beat again every time it starts.
    if (next && d.synced) _alignPhase(deckIndex);
    if (next) _logTrack(deckIndex);
    notifyListeners();
  }

  final List<bool> _jogResume = [false, false, false, false];

  /// Finger down on the jog platter: the track stops dead, like a vinyl-mode
  /// controller. Turning the platter then moves the playhead.
  void jogTouch(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    _jogResume[deckIndex] = d.playing;
    if (d.playing) {
      _engine.play(deckIndex, false);
      d.playing = false;
      notifyListeners();
    }
  }

  /// Finger up: if the track was playing, it carries on from where the
  /// platter was left (and finds the master's beat again if synced).
  void jogRelease(int deckIndex) {
    final d = deck(deckIndex);
    if (!_jogResume[deckIndex]) return;
    _jogResume[deckIndex] = false;
    if (!d.loaded || d.playing) return;
    _engine.play(deckIndex, true);
    d.playing = true;
    if (d.synced) _alignPhase(deckIndex);
    notifyListeners();
  }

  /// Waveform tap: jump exactly 4 beats toward the tap. No grid snap —
  /// integer beat jumps keep relative phase.
  void seek(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;

    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    if (d.bpm > 1) {
      final dir = target.compareTo(d.position);
      if (dir == 0) return;
      _engine.beatJump(deckIndex, dir * 4);
      d.position = _engine.position(deckIndex);
      _readLoop(deckIndex);
      notifyListeners();
      return;
    }

    seekTo(deckIndex, target);
  }

  /// Absolute seek (overview scrub / pause nudge). Ignores beat-jump mode.
  void seekTo(int deckIndex, double seconds) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final target = seconds.clamp(0.0, math.max(0.0, d.duration)).toDouble();
    _engine.seek(deckIndex, target);
    d.position = target;
    _readLoop(deckIndex);
    notifyListeners();
  }

  void setGain(int deckIndex, double v) {
    deck(deckIndex).gain = v;
    _engine.setGain(deckIndex, v);
    notifyListeners();
  }

  void setFader(int deckIndex, double v) {
    deck(deckIndex).fader = v;
    _engine.setFader(deckIndex, v);
    notifyListeners();
  }

  void setEq(int deckIndex, {double? low, double? mid, double? high}) {
    final d = deck(deckIndex);
    d.eqLow = low ?? d.eqLow;
    d.eqMid = mid ?? d.eqMid;
    d.eqHigh = high ?? d.eqHigh;
    _engine.setEq(deckIndex, d.eqLow, d.eqMid, d.eqHigh);
    notifyListeners();
  }

  void setFilter(int deckIndex, double amount) {
    deck(deckIndex).filter = amount;
    _engine.setFilter(deckIndex, amount);
    notifyListeners();
  }

  void setXfader(double x) {
    xfader = x;
    _engine.setXfader(x);
    notifyListeners();
  }

  void setMaster(double v) {
    master = v;
    _engine.setMaster(v);
    notifyListeners();
  }

  void setRate(int deckIndex, double rate) {
    final d = deck(deckIndex);
    d.rate = rate;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// CUE button. While playing: jump back to the cue point and stop.
  /// While stopped: set the cue point where the playhead is.
  void cue(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    if (d.playing) {
      _engine.jumpCue(deckIndex);
      _engine.play(deckIndex, false);
      d.playing = false;
      d.position = _engine.position(deckIndex);
    } else {
      _engine.setCue(deckIndex);
    }
    notifyListeners();
  }

  /// Hot cue pad: sets the cue if empty, otherwise jumps to it.
  void hotcue(int deckIndex, int index) {
    final d = deck(deckIndex);
    if (!d.loaded || index < 0 || index >= d.hotcues.length) return;
    if (d.hotcues[index] < 0) {
      _engine.setHotcue(deckIndex, index, -1);
      d.hotcues[index] = _engine.hotcue(deckIndex, index);
    } else {
      _engine.jumpHotcue(deckIndex, index);
      d.position = _engine.position(deckIndex);
    }
    notifyListeners();
  }

  void clearHotcue(int deckIndex, int index) {
    final d = deck(deckIndex);
    if (!d.loaded || index < 0 || index >= d.hotcues.length) return;
    _engine.clearHotcue(deckIndex, index);
    d.hotcues[index] = -1;
    notifyListeners();
  }

  void setKeylock(int deckIndex, bool enabled) {
    final d = deck(deckIndex);
    d.keylock = enabled;
    _engine.setKeylock(deckIndex, enabled);
    notifyListeners();
  }

  // ---- Sampler: eight pads that fire short sounds into the master.
  static const int samplerSlots = 8;
  final List<String?> samplePaths = List<String?>.filled(samplerSlots, null);
  final List<String> sampleNames = List<String>.filled(samplerSlots, '');
  double samplerVolume = 0.9;

  Future<bool> loadSample(int slot, String path) async {
    final ok = _engine.samplerLoad(slot, path);
    if (ok) {
      samplePaths[slot] = path;
      sampleNames[slot] = path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('sample_$slot', path);
      } catch (_) {}
      notifyListeners();
    }
    return ok;
  }

  Future<void> clearSample(int slot) async {
    samplePaths[slot] = null;
    sampleNames[slot] = '';
    _engine.samplerStop(slot);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('sample_$slot');
    } catch (_) {}
    notifyListeners();
  }

  void fireSample(int slot) {
    if (samplePaths[slot] != null) _engine.samplerFire(slot);
  }

  void stopSample(int slot) => _engine.samplerStop(slot);

  void setSamplerVolume(double v) {
    samplerVolume = v;
    _engine.samplerVolume(v);
    notifyListeners();
  }

  Future<void> restoreSamples() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (var i = 0; i < samplerSlots; i++) {
        final p = prefs.getString('sample_$i');
        if (p != null && File(p).existsSync()) await loadSample(i, p);
      }
    } catch (_) {}
  }

  // ---- Headphone cue.
  /// 0 off, 1 splitter cable (master left, cue right), 2 multichannel interface.
  int cueMode = 0;
  double cueVolume = 0.8;
  /// 0 = cue only, 1 = master only in the headphones.
  double cueMix = 0.0;

  void setCueMode(int mode, {double? volume, double? mix}) {
    cueMode = mode;
    if (volume != null) cueVolume = volume;
    if (mix != null) cueMix = mix;
    _engine.setCueMode(cueMode, cueVolume, cueMix);
    notifyListeners();
  }

  void toggleDeckCue(int deckIndex) {
    final d = deck(deckIndex);
    d.cue = !d.cue;
    _engine.setCueDeck(deckIndex, d.cue);
    if (d.cue && cueMode == 0) setCueMode(1);
    notifyListeners();
  }

  void setKeyShift(int deckIndex, int semitones) {
    final d = deck(deckIndex);
    d.keyShift = semitones.clamp(-6, 6);
    if (d.keyShift != 0 && !d.keylock) setKeylock(deckIndex, true);
    _engine.setKeyShift(deckIndex, d.keyShift.toDouble());
    notifyListeners();
  }

  void toggleKeylock(int deckIndex) =>
      setKeylock(deckIndex, !deck(deckIndex).keylock);

  final List<double> _nudgeBend = [0, 0, 0, 0]; // temporary pitch bend while held
  final List<Timer?> _nudgeHold = [null, null, null, null];

  /// The one deck every synced deck follows, or -1 when there is none.
  int masterDeck = -1;

  void _applyRate(int deckIndex) {
    final d = deck(deckIndex);
    final effective = (d.rate * (1.0 + _nudgeBend[deckIndex])).clamp(0.5, 2.0);
    _engine.setRate(deckIndex, effective);
  }

  /// ±0.1 BPM (heard tempo). Rate is derived from the track's original BPM.
  void nudgeBpm(int deckIndex, double delta) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 0) return;
    final heard = d.bpm * d.rate;
    final tenths = (heard * 10).round() + (delta * 10).round();
    final next = (tenths / 10.0).clamp(d.bpm * 0.5, d.bpm * 2.0);
    d.rate = next / d.bpm;
    d.synced = false;
    _applyRate(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// Hold to briefly speed up (+) or slow down (−) for beatmatching.
  /// While paused, the same buttons jog the playhead so you can cue visually.
  void startNudge(int deckIndex, {required bool faster}) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    _nudgeHold[deckIndex]?.cancel();
    if (d.playing) {
      _nudgeBend[deckIndex] = faster ? 0.08 : -0.08;
      _applyRate(deckIndex);
      notifyListeners();
      return;
    }
    _jogPaused(deckIndex, faster: faster);
    _nudgeHold[deckIndex] = Timer(const Duration(milliseconds: 350), () {
      _nudgeHold[deckIndex] = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) {
        if (!deck(deckIndex).playing) {
          _jogPaused(deckIndex, faster: faster);
        }
      });
    });
  }

  void endNudge(int deckIndex) {
    _nudgeHold[deckIndex]?.cancel();
    _nudgeHold[deckIndex] = null;
    _nudgeBend[deckIndex] = 0;
    _applyRate(deckIndex);
    notifyListeners();
  }

  void _jogPaused(int deckIndex, {required bool faster}) {
    final d = deck(deckIndex);
    if (!d.loaded || d.playing) return;
    const step = 0.04; // 40 ms — visible on the 8 s zoom window, still fine
    final t = (d.position + (faster ? step : -step))
        .clamp(0.0, math.max(0.0, d.duration))
        .toDouble();
    _engine.seek(deckIndex, t);
    d.position = t;
    notifyListeners();
  }

  void setLoop(int deckIndex, bool enabled, [double? bars]) {
    final d = deck(deckIndex);
    if (bars != null) d.loopBars = bars.clamp(0.25, 8.0);
    d.loopEnabled = enabled;
    _engine.setLoop(deckIndex, enabled, d.loopBars);
    _readLoop(deckIndex);
    notifyListeners();
  }

  static const loopBeats = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0];

  void halfLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    final i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    final next = i <= 0 ? loopBeats.first : loopBeats[i - 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void doubleLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final beats = d.loopBars * 4;
    var i = loopBeats.indexWhere((b) => (b - beats).abs() < 0.05);
    if (i < 0) i = 0;
    final next = i >= loopBeats.length - 1 ? loopBeats.last : loopBeats[i + 1];
    setLoop(deckIndex, d.loopEnabled, next / 4.0);
  }

  void _readLoop(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loopEnabled) {
      d.loopStart = 0;
      d.loopEnd = 0;
      return;
    }
    d.loopStart = _engine.loopStart(deckIndex);
    d.loopEnd = _engine.loopEnd(deckIndex);
  }

  void beatJump(int deckIndex, int beats) {
    _engine.beatJump(deckIndex, beats);
    deck(deckIndex).position = _engine.position(deckIndex);
    _readLoop(deckIndex);
    notifyListeners();
  }

  /// MASTER button: make this deck the tempo and beat reference. Only one
  /// deck can be master. Pressing it again on the master clears it.
  void setMasterDeck(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    if (masterDeck == deckIndex) {
      masterDeck = -1;
      notifyListeners();
      return;
    }
    masterDeck = deckIndex;
    d.synced = false;
    _followMasterBpm(deckIndex);
    notifyListeners();
  }

  /// SYNC button: follow the master. Matches the tempo and moves the playhead
  /// onto the master's beat. A paused deck finds the beat when it starts.
  /// With no master chosen yet, the playing deck (else the first loaded deck)
  /// becomes master.
  void sync(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded || masterDeck == deckIndex) return;
    if (masterDeck < 0 || !deck(masterDeck).loaded) {
      final pick = _pickMaster(deckIndex);
      if (pick < 0) return;
      masterDeck = pick;
      deck(pick).synced = false;
    }
    _nudgeBend[deckIndex] = 0;
    d.synced = true;
    _applySlaveTempo(deckIndex);
    if (d.playing) _alignPhase(deckIndex);
    notifyListeners();
  }

  /// Long press on SYNC: stop following the master.
  void unsync(int deckIndex) {
    deck(deckIndex).synced = false;
    notifyListeners();
  }

  int _pickMaster(int except) {
    var fallback = -1;
    for (var i = 0; i < deckCount; i++) {
      if (i == except || !deck(i).loaded) continue;
      if (deck(i).playing) return i;
      if (fallback < 0) fallback = i;
    }
    return fallback;
  }

  /// Move [deckIndex] by less than half a beat so its beats fall exactly on
  /// the master's beats. Does nothing unless the master is playing.
  void _alignPhase(int deckIndex) {
    final m = masterDeck;
    if (m < 0 || m == deckIndex) return;
    final d = deck(deckIndex);
    final md = deck(m);
    if (!d.loaded || !md.loaded || !md.playing) return;
    if (d.bpm <= 1 || md.bpm <= 1) return;
    final posM = _engine.position(m);
    final posF = _engine.position(deckIndex);
    final pm = beatPhase(
      position: posM,
      bpm: md.bpm,
      beatOffset: md.beatOffset,
    );
    final pf = beatPhase(
      position: posF,
      bpm: d.bpm,
      beatOffset: d.beatOffset,
    );
    var delta = pm - pf;
    if (delta > 0.5) delta -= 1;
    if (delta < -0.5) delta += 1;
    final target = (posF + delta * 60.0 / d.bpm)
        .clamp(0.0, math.max(0.0, d.duration))
        .toDouble();
    _engine.seek(deckIndex, target);
    d.position = target;
    _readLoop(deckIndex);
  }

  double _tempoMatchRate(DeckState slave, DeckState master) {
    final slaveBpm = slave.bpm <= 0 ? 1.0 : slave.bpm;
    return (master.bpm * master.rate / slaveBpm).clamp(0.5, 2.0);
  }

  void _applySlaveTempo(int slave) {
    final d = deck(slave);
    if (masterDeck < 0 || masterDeck == slave) return;
    final master = deck(masterDeck);
    if (!d.loaded || !master.loaded) return;
    d.rate = _tempoMatchRate(d, master);
    _applyRate(slave);
  }

  /// If [deckIndex] is the master, keep every synced deck matched to it.
  void _followMasterBpm(int deckIndex) {
    if (deckIndex != masterDeck) return;
    for (var i = 0; i < deckCount; i++) {
      if (i != deckIndex && deck(i).synced) _applySlaveTempo(i);
    }
  }

  /// Change the beat-grid tempo only. The audio keeps its speed.
  void setGridBpm(int deckIndex, double bpm) {
    final d = deck(deckIndex);
    if (!d.loaded) return;
    final next = bpm.clamp(20.0, 400.0).toDouble();
    d.bpm = next;
    _engine.setBpm(deckIndex, next);
    if (d.synced) _applySlaveTempo(deckIndex);
    _followMasterBpm(deckIndex);
    notifyListeners();
    _persistAnalysis(d);
  }

  /// Fix a detected tempo that is twice too fast.
  void halveGridBpm(int deckIndex) {
    final d = deck(deckIndex);
    if (d.bpm > 1) setGridBpm(deckIndex, d.bpm / 2);
  }

  /// Fix a detected tempo that is half the real one.
  void doubleGridBpm(int deckIndex) {
    final d = deck(deckIndex);
    if (d.bpm > 1) setGridBpm(deckIndex, d.bpm * 2);
  }

  /// Move the grid so a beat falls exactly at the playhead. Pause on a kick
  /// drum, then tap this.
  void setBeatHere(int deckIndex) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    final beat = 60.0 / d.bpm;
    var phase = (d.position - d.beatOffset) % beat;
    if (phase < 0) phase += beat;
    if (phase > beat / 2) phase -= beat;
    nudgeGrid(deckIndex, phase);
  }

  void nudgeGrid(int deckIndex, double seconds) {
    _engine.nudgeGrid(deckIndex, seconds);
    final d = deck(deckIndex);
    d.beatOffset = _engine.beatOffset(deckIndex);
    notifyListeners();
    _persistAnalysis(d);
  }

  /// Shift the painted grid. Negative = earlier (yellow moves left).
  void shiftGridBeats(int deckIndex, int beats) {
    final d = deck(deckIndex);
    if (!d.loaded || d.bpm <= 1) return;
    nudgeGrid(deckIndex, beats * (60.0 / d.bpm));
  }

  void shiftGridMs(int deckIndex, int milliseconds) {
    if (!deck(deckIndex).loaded) return;
    nudgeGrid(deckIndex, milliseconds / 1000.0);
  }

  Future<void> _persistAnalysis(DeckState d) async {
    final path = d.path;
    if (path == null || path.isEmpty || d.bpm <= 0) return;
    try {
      final stat = await File(path).stat();
      await _analysisCache.put(
        path: path,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        bpm: d.bpm,
        key: d.key,
        beatOffset: d.beatOffset,
      );
    } catch (_) {}
  }

  Future<void> setExternalMixer(bool enabled) async {
    if (mixerOffer != null) {
      mixerOffer = null;
      notifyListeners();
    }
    var deviceId = 0;
    var usbChannels = 4;
    usbDeviceName = '';
    usbDeviceId = 0;
    await UsbOutput.stopPlayback();
    if (enabled && Platform.isAndroid) {
      final usb = await UsbOutput.find();
      if (usb != null) {
        deviceId = usb.id;
        usbDeviceName = usb.name;
        if (usb.channels >= 8) usbChannels = 8;
      }
    }
    final prepared = _engine.setExternalMixer(enabled);
    if (enabled && prepared && Platform.isAndroid) {
      final res = await UsbOutput.startPlayback(
        engineHandle: _engine.nativeHandle,
        deviceId: deviceId,
        channels: usbChannels,
      );
      externalMixer = res.ok;
      if (res.ok) {
        usbDeviceId = res.routedId != 0 ? res.routedId : deviceId;
        if (res.routedName.isNotEmpty) usbDeviceName = res.routedName;
        engineError = null;
      } else {
        await UsbOutput.stopPlayback();
        engineError =
            'This USB device cannot take Deck A and Deck B on separate '
            'channels; audio stayed on the phone.';
        _engine.setExternalMixer(false);
        externalMixer = false;
      }
    } else if (enabled && !prepared) {
      engineError = '4-channel USB open failed; audio stayed on phone stereo.';
      externalMixer = false;
    } else {
      externalMixer = false;
      if (!enabled) engineError = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _usbSub?.cancel();
    _ticker.cancel();
    _nudgeHold[0]?.cancel();
    _nudgeHold[1]?.cancel();
    UsbOutput.stopPlayback();
    _engine.dispose();
    super.dispose();
  }
}
