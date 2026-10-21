import 'package:sidedeck/debug/debug_log.dart';
import 'dart:async';
import 'dart:io';

import 'package:sidedeck/engine/audio_check.dart';
import 'package:sidedeck/engine/tags.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/automix/set_flow.dart';
import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/automix/transition_style.dart';
import 'package:sidedeck/state/dislikes.dart';
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

  /// Called when nothing left in the queue fits the playing track (tempo or
  /// key); the app uses it to fetch a matching track from Soulseek.
  void Function(String artist, double bpm, CamelotKey? key, String title, String genre)? onNeedTrack;
  String? _needAsked;
  DateTime _needAskedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _needCheck = DateTime.fromMillisecondsSinceEpoch(0);

  void _checkNeedTrack() {
    final cb = onNeedTrack;
    if (cb == null || _automixIndex < 0 || _automixIndex >= _automixQueue.length) return;
    final now = DateTime.now();
    if (now.difference(_needCheck).inSeconds < 5) return;
    _needCheck = now;
    final path = _automixQueue[_automixIndex];
    if (_needAsked == path && now.difference(_needAskedAt).inSeconds < 20) return;
    final cur = _flowOf(path);
    if (cur == null) return;
    var fits = 0;
    for (var i = _automixIndex + 1; i < _automixQueue.length; i++) {
      final q = _automixQueue[i];
      if (_wasPlayed(q)) continue;
      final c = _flowOf(q);
      if (c == null) continue;
      if (_rejected.contains(q) || !_suits(q)) continue;
      if (cur.key != null && c.key != null && keyMatch(cur.key!, c.key!).score < 70) continue;
      fits++;
    }
    // With your own genres picked, a pinned download is wanted even when the
    // queue has other tracks that fit.
    final pinned = genrePinned?.call() ?? false;
    final fp = _forcePath;
    final waitingPinned = fp != null && !_wasPlayed(fp) && _automixQueue.contains(fp);
    // Always keep one fresh download on the way, even when the playlist still
    // has tracks that fit (when fetching is switched on).
    final wantFresh = fetchWanted?.call() ?? false;
    final waitingFresh = _fresh.any((f) => _automixQueue.contains(f) && !_wasPlayed(f) && !_rejected.contains(f));
    if (pinned ? waitingPinned : (wantFresh ? waitingFresh : fits > 0)) return;
    _needAsked = path;
    _needAskedAt = now;
    final name = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final dash = name.indexOf(' - ');
    var artist = cur.artist;
    var title = dash > 0 ? name.substring(dash + 3).trim() : name;
    if (artist.isEmpty) {
      // No "Artist - Title" name: use what comes before a bracket, e.g.
      // "baby ford & zip (glidin' along)-[perl 061]" gives "baby ford & zip".
      final cut = RegExp(r'\s*[\(\[]|\s-').firstMatch(name);
      final head = (cut != null && cut.start > 1 ? name.substring(0, cut.start) : name)
          .replaceFirst(RegExp(r'^\d+[\.\s-]+'), '')
          .trim();
      artist = head;
      title = name;
    }
    DebugLog.add('automix', 'nothing in the queue fits $name (${cur.bpm.round()} BPM), asking Soulseek for a match');
    cb(artist, cur.bpm, cur.key, title, genreOf?.call(path) ?? '');
  }

  /// A new track (for example a finished Soulseek download) joins the end of
  /// the automix queue if automix is running.
  void automixAppend(String path) {
    if (!automixOn || _automixQueue.contains(path)) return;
    if (_automixQueue.any((q) => _trackKey(q) == _trackKey(path))) return;
    _automixQueue.add(path);
    _learnAfterAnalysis(path);
    // A genre you chose yourself: this download plays next.
    final armed = _playNextArmed &&
        DateTime.now().difference(_playNextAt).inMinutes < 10 &&
        !_automixFading;
    if (armed) {
      _playNextArmed = false;
      _forcePath = path;
      _mixNow = true;
      _upNext = path;
      _automixPreloaded = false;
      _rejected.remove(path);
      DebugLog.add('automix', 'your genre choice arrived, playing it next: ${path.split(RegExp(r'[\\/]')).last}');
    }
    // A fresh download plays before the playlist's own tracks (the genre and
    // tempo checks still apply when it loads).
    _fresh.add(path);
    if (!armed && !_automixFading && _upNext != path) {
      _upNext = path;
      _automixPreloaded = false;
      _rejected.remove(path);
    }
    notifyListeners();
  }

  /// Downloads made for automix (not from the playlist you started with).
  final Set<String> _fresh = {};

  bool _playNextArmed = false;

  /// Wanted intensity 0..3 (see AutoFetch.intensity).
  int Function()? intensityWanted;

  /// True when automix should bring in new downloads all the time.
  bool Function()? fetchWanted;

  /// Genres picked by the user are in force: fetch them, skip the genre gate.
  bool Function()? genrePinned;
  bool _mixNow = false;
  DateTime? _skipAt;

  /// Skip: on the playing deck, mix into the next track now; on the waiting
  /// deck, drop that track and choose another.
  String? automixSkip(int deckIndex) {
    if (!automixOn || _automixDeck < 0) return 'Automix is not running.';
    if (_automixFading) return 'Wait for the mix to finish.';
    if (deckIndex == _automixDeck) {
      _skipAt = DateTime.now();
      DebugLog.add('automix', 'skip: mixing into the next track now');
      automixStatus = 'Skipping…';
      notifyListeners();
      return null;
    }
    final path = deck(deckIndex).path;
    if (path != null) {
      _markPlayed(path);
      _rejected.add(path);
    }
    DebugLog.add('automix', 'skip: choosing another track for deck ${deckIndex + 1}');
    _clearUpNext();
    _flowNext = null;
    notifyListeners();
    return null;
  }
  DateTime _playNextAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _forcePath;

  /// The next download is one you asked for: it goes to the front.
  void armPlayNext() {
    _playNextArmed = true;
    _playNextAt = DateTime.now();
  }

  /// A new download is analysed a little after it arrives; look again until
  /// its tempo and key are known so it can be matched.
  Future<void> _learnAfterAnalysis(String path) async {
    for (var i = 0; i < 15; i++) {
      _flowInfo.remove(path);
      await _flowLearn(path);
      if ((_flowInfo[path]?.bpm ?? 0) > 0) break;
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!automixOn) return;
    }
    notifyListeners();
  }

  // ---- Automix -----------------------------------------------------------
  // Plays a list of tracks one after another. Shortly before the playing deck
  // ends, the next track is loaded on the other deck, matched to the same
  // tempo, started on the same point in the beat, and crossfaded in.

  bool automixOn = false;
  /// How long before the end the mix starts (and how long it lasts).
  double automixFadeSeconds = 20;
  TransitionStyle automixStyle = TransitionStyle.auto;
  TransitionPlan? _plan;
  double _fadeLen = 20;

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

  // Tracks automix has played in the last 24 hours, kept across restarts, so
  // the same track is not mixed in again the same day.
  final Map<String, int> _recentPlayed = {};
  bool _recentLoaded = false;
  static const _recentHours = 24;

  Future<void> _loadRecent() async {
    if (_recentLoaded) return;
    _recentLoaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      for (final e in p.getStringList('automix_recent') ?? const <String>[]) {
        final i = e.lastIndexOf('|');
        if (i <= 0) continue;
        final t = int.tryParse(e.substring(i + 1));
        if (t != null) _recentPlayed[e.substring(0, i)] = t;
      }
    } catch (_) {}
    _pruneRecent();
  }

  void _pruneRecent() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _recentHours * 3600 * 1000;
    _recentPlayed.removeWhere((_, t) => t < cutoff);
  }

  bool _wasPlayed(String path) {
    if (Dislikes.instance.hasPath(path)) return true; // deleted = not liked
    final k = _trackKey(path);
    if (_automixPlayed.contains(k)) return true;
    if (_replayOk.contains(k)) return false; // replayed on purpose, nothing newer
    final t = _recentPlayed[k];
    return t != null &&
        DateTime.now().millisecondsSinceEpoch - t < _recentHours * 3600 * 1000;
  }

  void _markPlayed(String path) {
    _countPlay(path);
    final k = _trackKey(path);
    _automixPlayed.add(k);
    _recentPlayed[k] = DateTime.now().millisecondsSinceEpoch;
    _pruneRecent();
    SharedPreferences.getInstance().then((p) {
      p.setStringList('automix_recent',
          [for (final e in _recentPlayed.entries) '${e.key}|${e.value}']);
    }).catchError((_) {});
  }

  /// Loads the saved play history so screens can show what was played today.
  Future<void> loadPlayedHistory() async {
    await _loadRecent();
    await loadPlayCounts();
    notifyListeners();
  }

  bool playedRecently(String path) => _wasPlayed(path);

  // Tracks left out of the queue because they played in the last 24 hours.
  // Used only as a last resort so the music never stops.
  final List<String> _replayPool = [];
  final Set<String> _replayOk = {};

  int? _replayPick() {
    while (_replayPool.isNotEmpty) {
      _replayPool.sort((a, b) =>
          (_recentPlayed[_trackKey(a)] ?? 0).compareTo(_recentPlayed[_trackKey(b)] ?? 0));
      final path = _replayPool.removeAt(0);
      if (!File(path).existsSync() || Dislikes.instance.hasPath(path)) continue;
      if (_automixQueue.any((q) => _trackKey(q) == _trackKey(path))) continue;
      _replayOk.add(_trackKey(path));
      _automixQueue.add(path);
      _learnAfterAnalysis(path);
      DebugLog.add('automix', 'nothing new yet: replaying the track played longest ago: ${path.split(RegExp(r'[\\/]')).last}');
      return _automixQueue.length - 1;
    }
    return null;
  }

  // ---- Play counts (for the "Most played" sort) ----------------------------
  final Map<String, int> _plays = {};
  final Map<String, int> _playCountedAt = {};
  bool _playsLoaded = false;

  int playCountOf(String path) => _plays[_trackKey(path)] ?? 0;

  Future<void> loadPlayCounts() async {
    if (_playsLoaded) return;
    _playsLoaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      for (final e in p.getStringList('play_counts_v1') ?? const <String>[]) {
        final i = e.lastIndexOf('|');
        final n = i > 0 ? int.tryParse(e.substring(i + 1)) : null;
        if (n != null) _plays[e.substring(0, i)] = n;
      }
    } catch (_) {}
  }

  /// One more play for a track (not counted again within ten minutes, so
  /// pausing and resuming does not add up).
  void _countPlay(String path) {
    final k = _trackKey(path);
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _playCountedAt[k];
    if (last != null && now - last < 10 * 60 * 1000) return;
    _playCountedAt[k] = now;
    _plays[k] = (_plays[k] ?? 0) + 1;
    SharedPreferences.getInstance().then((p) {
      p.setStringList('play_counts_v1', [for (final e in _plays.entries) '${e.key}|${e.value}']);
    }).catchError((_) {});
  }

  /// The DJ deleted this track: take it out of the automix queue if it has
  /// not played yet.
  void automixDrop(String path) {
    if (!automixOn) return;
    final k = _trackKey(path);
    for (var i = _automixQueue.length - 1; i > _automixIndex; i--) {
      if (_trackKey(_automixQueue[i]) == k) {
        _automixQueue.removeAt(i);
        if (_flowNext == i) _flowNext = null;
      }
    }
    notifyListeners();
  }

  /// Takes the track off a deck for good: it is marked as disliked, dropped
  /// from the automix queue and unloaded. Returns a message when it cannot
  /// be done right now, otherwise null. If automix was playing that deck, the
  /// other deck carries on.
  String? removeFromDeck(int i) {
    final d = deck(i);
    if (!d.loaded) return 'Nothing is loaded on deck ${i + 1}.';
    if (automixOn && _automixFading) return 'Wait for the mix to finish, then remove it.';
    if (automixOn && _automixBusy) return 'Automix is loading a track. Try again in a moment.';
    final path = d.path ?? '';
    final wasCurrent = automixOn && i == _automixDeck;
    final wasNext = automixOn && _automixDeck >= 0 && i == 1 - _automixDeck;
    _engine.play(i, false);
    d.playing = false;
    _engine.unload(i);
    d.loaded = false;
    d.title = 'Empty';
    d.artist = '';
    d.path = null;
    d.position = 0;
    d.duration = 0;
    d.bpm = 0;
    d.key = -1;
    loadedPaths.remove(path);
    automixDrop(path);
    if (wasNext) {
      _upNext = null;
      _automixPreloaded = false;
    }
    if (wasCurrent) {
      // Same as a deck that ended: bring in the next suitable track.
      _automixDeckEnded(i, 1 - i);
    }
    notifyListeners();
    return null;
  }

  /// Forget what was played in the last 24 hours.
  Future<void> clearPlayedHistory() async {
    _recentPlayed.clear();
    _automixPlayed.clear();
    try {
      (await SharedPreferences.getInstance()).remove('automix_recent');
    } catch (_) {}
    notifyListeners();
  }

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
  /// Looks up a track's genre (set by the app from the library tags).
  String Function(String path)? genreOf;

  /// Does [path] suit the track now playing? Same or similar genre and a
  /// tempo within 8 %. Unknown genre or tempo does not rule it out.
  bool _suits(String path, {int tier = 0}) {
    final curPath = _automixIndex >= 0 && _automixIndex < _automixQueue.length
        ? _automixQueue[_automixIndex]
        : null;
    if (curPath == null || tier >= 2) return true;
    final cur = _flowOf(curPath);
    final c = _flowOf(path);
    final tol = tier == 0 ? 8.0 : 15.0;
    // A tempo not known yet does not rule a track out: it is loaded, read by
    // the engine, and checked before the mix (see _loadNext).
    if (cur != null && cur.bpm > 0 && c != null && c.bpm > 0) {
      if (bpmGapPercent(cur.bpm, c.bpm).abs() > tol) return false;
    }
    if (tier == 0) {
      final g = genreOf;
      if (g != null && !genresSimilar(g(curPath), g(path))) return false;
    }
    return true;
  }

  // ---- Up next ------------------------------------------------------------
  // The track committed to follow the playing one. It is chosen once, loaded
  // on the idle deck, checked against the playing track and then mixed in;
  // it does not change under the mix.
  String? _upNext;
  // Tracks tried and turned down for the track now playing (tempo too far).
  final Set<String> _rejected = {};
  int _busyTicks = 0;

  int? _upNextIndex() {
    final u = _upNext;
    if (u == null) return null;
    final i = _automixQueue.indexOf(u);
    if (i <= _automixIndex || _wasPlayed(u)) {
      _upNext = null;
      _automixPreloaded = false;
      return null;
    }
    return i;
  }

  void _clearUpNext() {
    _upNext = null;
    _automixPreloaded = false;
    _flowNext = null;
    _rejected.clear();
  }

  /// The committed next track, or a new pick for the given tier (0 = same
  /// genre and tempo, 1 = tempo within 15 %, 2 = anything not played).
  int? _nextUnplayed({int tier = 0}) {
    final held = _upNextIndex();
    if (held != null) return held;
    final i = _pickNext(tier);
    if (i != null) {
      _upNext = _automixQueue[i];
      _automixPreloaded = false;
    }
    return i;
  }

  int? _pickNext(int tier) {
    final flow = _flow;
    if (flow != null && flow.arc != FlowArc.off) {
      final held = _flowNext;
      if (held != null &&
          held > _automixIndex &&
          held < _automixQueue.length &&
          !_wasPlayed(_automixQueue[held])) {
        return held;
      }
      final cands = <(int, FlowTrack)>[];
      for (var i = _automixIndex + 1; i < _automixQueue.length; i++) {
        final path = _automixQueue[i];
        if (_wasPlayed(path)) continue;
        if (failedPaths.contains(path)) continue;
        if (tier < 2 && _rejected.contains(path)) continue;
        if (!_suits(path, tier: tier)) continue;
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
      automixFadeSeconds = (_baseFade * flow.arc.fadeScale(pick.energy)).clamp(6.0, 180.0).toDouble();
      return pick.index;
    }
    // No set flow: the best fit by tempo first, then key.
    final curPath = _automixIndex >= 0 && _automixIndex < _automixQueue.length
        ? _automixQueue[_automixIndex]
        : null;
    final cur = curPath == null ? null : _flowOf(curPath);
    int? best;
    var bestScore = -1e9;
    for (var i = _automixIndex + 1; i < _automixQueue.length; i++) {
      final path = _automixQueue[i];
      if (_wasPlayed(path)) continue;
      if (failedPaths.contains(path)) continue;
      if (tier < 2 && _rejected.contains(path)) continue;
      if (!_suits(path, tier: tier)) continue;
      final c = _flowOf(path);
      var score = 0.0;
      if (cur != null && c != null) {
        if (cur.bpm > 0 && c.bpm > 0) score -= bpmGapPercent(cur.bpm, c.bpm).abs() * 4;
        if (cur.bpm > 0 && c.bpm <= 0) score -= 12; // unknown tempo: after the known fits
        if (cur.key != null && c.key != null) score += keyMatch(cur.key!, c.key!).score * 0.3;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  int get automixQueueLength => _automixQueue.length;
  int get automixIndex => _automixIndex;

  Future<void> startAutomix(
    List<String> paths, {
    double fadeSeconds = 20,
    double startOffsetSeconds = 10,
    FlowArc arc = FlowArc.off,
    double lengthMinutes = 60,
    TransitionStyle style = TransitionStyle.auto,
  }) async {
    if (paths.isEmpty && !(deckA.loaded && deckA.path != null)) return;
    stopAutomix();
    // The track already on deck A (if any) starts the set; then the list.
    final onA = deckA.loaded ? deckA.path : null;
    await _loadRecent();
    await Dislikes.instance.load();
    final seen = <String>{};
    _automixQueue = [
      if (onA != null && File(onA).existsSync())
        if (seen.add(_trackKey(onA))) onA,
      for (final p in paths)
        if (File(p).existsSync() && !_wasPlayed(p) && seen.add(_trackKey(p))) p,
    ];
    if (_automixQueue.isEmpty) {
      // Everything was played in the last 24 hours: start with the one played
      // longest ago (never a deleted one) and let the helper find new tracks.
      final again = <String>[
        for (final p in paths)
          if (File(p).existsSync() && !Dislikes.instance.hasPath(p)) p,
      ]..sort((a, b) => (_recentPlayed[_trackKey(a)] ?? 0).compareTo(_recentPlayed[_trackKey(b)] ?? 0));
      if (again.isEmpty) {
        automixStatus = 'No playable files in that list';
        notifyListeners();
        return;
      }
      _automixQueue = [again.first];
      DebugLog.add('automix', 'everything was played in the last 24 hours: starting with the oldest, new tracks will be fetched');
    }
    _automixPlayed.clear();
    _replayOk.clear();
    _fresh.clear();
    _replayPool
      ..clear()
      ..addAll({
        for (final p in paths)
          if (File(p).existsSync() &&
              !Dislikes.instance.hasPath(p) &&
              !_automixQueue.any((q) => _trackKey(q) == _trackKey(p)))
            p,
      });
    automixFadeSeconds = fadeSeconds.clamp(4.0, 180.0).toDouble();
    _baseFade = automixFadeSeconds;
    _flowNext = null;
    automixStyle = style;
    _flow = arc == FlowArc.off ? null : SetFlow(arc, lengthMinutes: lengthMinutes);
    for (final p in _automixQueue) {
      await _flowLearn(p);
    }
    automixStartOffset = startOffsetSeconds.clamp(0.0, 90.0).toDouble();
    DebugLog.add('automix', 'start with ${_automixQueue.length} tracks, flow ${arc.label}, mix starts ${automixFadeSeconds.round()} s from the end, next track starts ${automixStartOffset.round()} s in');
    automixOn = true;
    automixStatus = 'Loading first track';
    _automixBusy = true;
    notifyListeners();
    var ok = false;
    if (onA != null && _automixQueue.first == onA) {
      ok = true; // already loaded on deck A
    } else {
      // Try each track until one loads.
      while (_automixQueue.isNotEmpty && automixOn) {
        ok = await loadFile(0, _automixQueue.first);
        if (ok) break;
        DebugLog.add('automix', 'first track would not load, skipping: ${_automixQueue.first}');
        _automixQueue.removeAt(0);
      }
    }
    _automixBusy = false;
    if (!automixOn) return; // stopped while loading
    if (!ok) {
      automixOn = false;
      DebugLog.flow('Automix start', false, 'none of the tracks would load');
      DebugLog.fail('automix', 'none of the tracks would load');
      automixStatus = 'None of the tracks would load';
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
    _markPlayed(_automixQueue.first);
    DebugLog.flow('Automix start', true);
    DebugLog.ok('automix', 'playing first track on deck 1: ${_automixQueue.first.split(RegExp(r'[\\/]')).last}');
    _clearUpNext();
    _automixFading = false;
    automixStatus = null;
    notifyListeners();
    onAutomixStart?.call();
  }

  /// Switches what comes next while automix keeps running: the track now
  /// playing carries on, then the new list follows.
  void automixSwitchTo(List<String> paths) {
    if (!automixOn || _automixIndex < 0 || _automixIndex >= _automixQueue.length) return;
    if (_automixFading) return; // wait for the mix in progress to finish
    final current = _automixQueue[_automixIndex];
    final seen = <String>{_trackKey(current)};
    _automixQueue = [
      current,
      for (final p in paths)
        if (seen.add(_trackKey(p))) p,
    ];
    _automixIndex = 0;
    _clearUpNext();
    DebugLog.ok('automix', 'switched list, ${_automixQueue.length - 1} tracks follow');
    automixStatus = 'Switched: new list plays after this track';
    notifyListeners();
  }

  void stopAutomix() {
    final wasOn = automixOn;
    if (wasOn) DebugLog.add('automix', 'stopped');
    if (_automixFading && _automixDeck >= 0) {
      _restoreMixEq(_automixDeck, 1 - _automixDeck);
    }
    automixOn = false;
    _automixFading = false;
    _clearUpNext();
    _automixDeck = -1;
    _automixIndex = -1;
    _flow = null;
    if (wasOn) {
      automixStatus = null;
      notifyListeners();
      onAutomixStop?.call();
    }
  }

  /// Returns true if something on screen changed.
  bool _automixTick() {
    if (!automixOn || _automixDeck < 0) return false;
    if (_automixBusy) {
      // A load that never finishes must not freeze automix: give it a minute.
      if (++_busyTicks > 1200) {
        DebugLog.fail('automix', 'a track load took over a minute, carrying on');
        _automixBusy = false;
        _busyTicks = 0;
        _upNext = null;
        _automixPreloaded = false;
      }
      return false;
    }
    _busyTicks = 0;
    if (_automixFading) {
      final jump = _skipJump(_automixDeck);
      if (jump != 0) {
        DebugLog.add('automix', 'you moved the playing track ${jump > 0 ? 'forward' : 'back'} ${jump.abs().toStringAsFixed(0)} s during a mix: mix cancelled and planned again');
        _abortFade(_automixDeck, 1 - _automixDeck);
        return true;
      }
      _automixAdvanceFade();
      return true;
    }
    final cur = _automixDeck;
    final other = 1 - cur;
    final d = deck(cur);
    // The playing deck ran to its end (or its track was removed): carry on.
    if (!d.loaded ||
        (!d.playing && d.duration > 0 && _engine.position(cur) >= d.duration - 0.6)) {
      return _automixDeckEnded(cur, other);
    }
    if (!d.playing) return false; // paused by the DJ: wait
    final jump = _skipJump(cur);
    if (jump != 0) {
      DebugLog.add('automix', 'you moved the playing track ${jump > 0 ? 'forward' : 'back'} ${jump.abs().toStringAsFixed(0)} s, timing worked out again');
    }
    final remaining = remainingSeconds(
      position: _engine.position(cur),
      duration: d.duration,
      rate: d.rate,
    );
    _checkNeedTrack();
    // The fit relaxes as the end gets close, so something always plays:
    // same genre and tempo, then tempo within 15 %, then anything unplayed.
    final skipping = _skipAt != null && DateTime.now().difference(_skipAt!).inMinutes < 3;
    if (!skipping) _skipAt = null;
    final tier = skipping ? 1 : (remaining > 45 ? 0 : (remaining > 20 ? 1 : 2));
    var next = _nextUnplayed(tier: tier);
    // Never silent: with the end near and nothing new yet, replay the track
    // played longest ago (never a deleted one) while the helper keeps looking.
    if (next == null && remaining <= 25 && _replayPick() != null) {
      next = _nextUnplayed(tier: 2);
    }
    if (next == null) {
      // Nothing to put on the other deck yet: say so, and keep asking.
      final text = (fetchBusy?.call() ?? false)
          ? (fetchStatus?.call() ?? 'Finding the next track…')
          : _idleReason('No track fits yet. Looking for one (Soulseek helper), or add music.');
      if (automixStatus != text) {
        automixStatus = text;
        return true;
      }
      return false;
    }
    if (!_automixPreloaded) {
      // Load the next track on the other deck as soon as one is chosen, so
      // both decks are loaded from the start.
      _automixBusy = true;
      _loadNext(other, _automixQueue[next], tier);
      return false;
    }
    final mixNow = skipping || (_mixNow && _forcePath != null && _forcePath == _automixQueue[next]);
    if (mixNow || shouldStartFade(remaining: remaining, fadeSeconds: automixFadeSeconds)) {
      var breakLeft = 0.0;
      if (kindFor(automixStyle, d.bpm, deck(other).bpm) == TransitionKind.breakdown) {
        final amp = [
          for (var k = 0; k < math.min(d.waveMax.length, d.waveMin.length); k++)
            (d.waveMax[k] - d.waveMin[k]).toDouble(),
        ];
        final pos = _engine.position(cur);
        final end = breakdownEnd(amp, d.duration, pos, 6);
        final barNow = d.bpm > 1 ? 4 * 60.0 / d.bpm : 2.0;
        // Wait for a breakdown on a bar line; give up when the track is nearly over.
        if (end == null || !nearBarLine(pos, d.bpm, d.beatOffset)) {
          if (remaining > 4 * barNow + 6) return false;
        } else {
          breakLeft = (end - pos) / (d.rate <= 0 ? 1 : d.rate);
        }
      }
      final plan = planFor(automixStyle,
          outBpm: d.bpm, inBpm: deck(other).bpm, baseSeconds: skipping ? 8.0 : automixFadeSeconds, breakSeconds: breakLeft);
      // A cut lands on the first beat of a bar, so wait for the bar line
      // (unless the track is about to end).
      final bar = d.bpm > 1 ? 4 * 60.0 / d.bpm : 2.0;
      if (plan.onBarLine &&
          remaining > bar + 1 &&
          !nearBarLine(_engine.position(cur), d.bpm, d.beatOffset)) {
        return false;
      }
      _plan = plan;
      _mixNow = false;
      _skipAt = null;
      _automixBeginFade(cur, other, next);
      return true;
    }
    return false;
  }

  final Map<String, String> _genreCache = {};

  /// A track's genre: the library's, else read from the file's own tags.
  Future<String> _genreFor(String path) async {
    final known = genreOf?.call(path) ?? '';
    if (known.isNotEmpty) return known;
    final c = _genreCache[path];
    if (c != null) return c;
    var g = '';
    try {
      g = (await readTrackTags(path)).genre;
    } catch (_) {}
    return _genreCache[path] = g;
  }

  /// Loads the committed next track on the idle deck, reads its real tempo
  /// and turns it down if it is too far from the playing track.
  Future<void> _loadNext(int other, String path, int tier) async {
    try {
      // Look at the file first; a bad one never reaches the deck.
      final bad = await AudioCheck.problem(path);
      var ok = false;
      if (bad == null) {
        ok = await loadFile(other, path);
      } else {
        DebugLog.add('automix', 'not loaded (${path.split(RegExp(r'[\\/]')).last}): $bad');
        failedPaths.add(path);
      }
      if (!automixOn || _automixDeck != 1 - other) return;
      if (!ok) {
        DebugLog.flow('Automix mix to next deck', false, 'next track would not load');
        DebugLog.fail('automix', 'next track would not load, skipped: ${path.split(RegExp(r'[\\/]')).last}');
        _automixQueue.remove(path);
        _upNext = null;
        _flowNext = null;
        automixStatus = 'Skipped a track that would not load';
        return;
      }
      final out = deck(1 - other);
      final inc = deck(other);
      final old = _flowInfo[path];
      _flowInfo[path] = FlowTrack(path,
          bpm: inc.bpm > 1 ? inc.bpm : (old?.bpm ?? 0),
          key: inc.key >= 0 ? CamelotKey.fromIndex(inc.key) : old?.key,
          artist: old?.artist ?? '');
      // Genre check on the file's own tags (a new download is not in the
      // library tags yet): never dub after minimal house, except as a last
      // resort when time has run out.
      final forced = _forcePath == path || (genrePinned?.call() ?? false);
      if (!forced && tier < 2 && _automixIndex >= 0 && _automixIndex < _automixQueue.length) {
        final cg = await _genreFor(_automixQueue[_automixIndex]);
        final ng = await _genreFor(path);
        if (cg.isNotEmpty && ng.isNotEmpty && !genresSimilar(cg, ng)) {
          DebugLog.add('automix',
              'turned down ${path.split(RegExp(r'[\\/]')).last}: "$ng" does not go with "$cg", choosing another');
          _rejected.add(path);
          _upNext = null;
          _flowNext = null;
          _automixPreloaded = false;
          return;
        }
      }
      // Intensity: how dense and steady the loudness is across the track
      // (average height of the waveform against its tallest part).
      final want = intensityWanted?.call() ?? 0;
      if (want > 0) {
        final n = math.min(inc.waveMax.length, inc.waveMin.length);
        if (n > 20) {
          var sum = 0.0, top = 0.0;
          for (var k = 0; k < n; k++) {
            final a = (inc.waveMax[k] - inc.waveMin[k]).toDouble();
            sum += a;
            if (a > top) top = a;
          }
          final dens = top > 0 ? sum / n / top : 0.0;
          const need = [0.0, 0.40, 0.52, 0.62];
          DebugLog.add('automix',
              'intensity of ${path.split(RegExp(r'[\\/]')).last}: ${(dens * 100).round()} (wanted ${(need[want] * 100).round()})');
          if (tier < 2 && dens < need[want]) {
            DebugLog.add('automix', 'turned down: not intense enough, choosing another');
            _rejected.add(path);
            _upNext = null;
            _flowNext = null;
            _automixPreloaded = false;
            return;
          }
        }
      }
      final tol = forced ? 30.0 : (tier == 0 ? 10.0 : (tier == 1 ? 16.0 : 1e9));
      if (out.bpm > 1 && inc.bpm > 1 && bpmGapPercent(out.bpm, inc.bpm).abs() > tol) {
        DebugLog.add('automix',
            'turned down ${path.split(RegExp(r'[\\/]')).last}: ${inc.bpm.round()} BPM against ${out.bpm.round()}, choosing another');
        _rejected.add(path);
        _upNext = null;
        _flowNext = null;
        _automixPreloaded = false;
        return;
      }
      DebugLog.ok('automix', 'next track ready on deck ${other + 1} (${inc.bpm.round()} BPM)');
      _automixPreloaded = true;
    } catch (e) {
      DebugLog.fail('automix', 'loading the next track failed: $e');
      _upNext = null;
      _automixPreloaded = false;
    } finally {
      _automixBusy = false;
      notifyListeners();
    }
  }

  /// True while tracks are still being downloaded for automix.
  bool Function()? fetchBusy;

  /// What the helper is doing now (for the status line and the empty deck).
  String Function()? fetchStatus;

  void refresh() => notifyListeners();

  /// After a failed search, say why instead of a generic line.
  String _idleReason(String fallback) {
    final st = fetchStatus?.call() ?? '';
    return st.startsWith('Next track:') ? '$st. Trying again shortly.' : fallback;
  }

  /// Text for an empty deck while automix is looking for its next track.
  String? deckHint(int i) {
    if (!automixOn || _automixDeck < 0 || i == _automixDeck) return null;
    // Only show the helper's line while it is working, not an old result.
    final st = (fetchBusy?.call() ?? false) ? (fetchStatus?.call() ?? '') : '';
    return st.isNotEmpty ? st : automixStatus;
  }

  /// Automix started or stopped (the app switches AUTO and Soulseek with it).
  void Function()? onAutomixStart;
  void Function()? onAutomixStop;

  /// A deck finished by itself (no mix happened, for example because the next
  /// track was not ready or a mix was cancelled): load a fitting track on the
  /// other deck if needed and start it straight away.
  bool _automixDeckEnded(int cur, int other) {
    final waiting = fetchBusy?.call() ?? false;
    int? picked = _nextUnplayed(tier: 0) ?? (waiting ? null : _nextUnplayed(tier: 2));
    if (picked == null && _replayPick() != null) picked = _nextUnplayed(tier: 2);
    if (picked == null) {
      // The deck ended and nothing suitable is queued: stay on, ask for a
      // match, and start it the moment it arrives.
      _checkNeedTrack();
      final busy = fetchBusy?.call() ?? false;
      final text = busy
          ? (fetchStatus?.call() ?? 'Finding a matching track…')
          : 'No suitable track left. Looking for one (Soulseek helper), or add music.';
      if (automixStatus != text) {
        automixStatus = text;
        return true;
      }
      return false;
    }
    final int next = picked;
    DebugLog.add('automix', 'deck ${cur + 1} finished on its own, starting deck ${other + 1} straight away');
    _automixBusy = true;
    () async {
      try {
        if (!_automixPreloaded) {
          final ok = await loadFile(other, _automixQueue[next]);
          if (!automixOn) return;
          if (!ok) {
            DebugLog.flow('Automix mix to next deck', false, 'next track would not load');
            DebugLog.fail('automix', 'next track would not load, skipped: ${_automixQueue[next].split(RegExp(r'[\\/]')).last}');
            _automixQueue.removeAt(next);
            _flowNext = null;
            automixStatus = 'Skipped a track that would not load';
            return;
          }
        }
        final inc = deck(other);
        inc.synced = false;
        _engine.setFader(other, inc.fader);
        _engine.setFader(cur, deck(cur).fader);
        _engine.setEq(other, inc.eqLow, inc.eqMid, inc.eqHigh);
        _engine.setFilter(other, inc.filter);
        _engine.setXfader(crossfaderEndFor(other));
        xfader = crossfaderEndFor(other);
        final start = inc.beatOffset > 0 ? inc.beatOffset : 0.0;
        _engine.seek(other, start);
        inc.position = start;
        _engine.play(other, true);
        inc.playing = true;
        DebugLog.flow('Automix mix to next deck', true);
        final prevTrack = _flowOf(_automixQueue[_automixIndex]);
        _automixDeck = other;
        final donePath = _automixQueue[_automixIndex];
        _automixIndex = next;
        onTrackDone?.call(donePath);
        _markPlayed(_automixQueue[next]);
        if (prevTrack != null) _flow?.played(prevTrack, _flowMove);
        _clearUpNext();
        automixStatus = null;
      } finally {
        _automixBusy = false;
        notifyListeners();
      }
    }();
    return true;
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
    // Never plan a mix longer than what is left of the playing track, or the
    // old track ends before the new one is heard.
    final left = remainingSeconds(position: outPosition, duration: out.duration, rate: out.rate);
    final cap = left > 5 ? left - 1.0 : math.max(2.0, left - 0.3);
    _fadeLen = math.min(_plan?.seconds ?? automixFadeSeconds, cap).toDouble();
    if (_fadeLen < (_plan?.seconds ?? automixFadeSeconds)) {
      DebugLog.add('automix', 'only ${left.toStringAsFixed(0)} s left, mix shortened to ${_fadeLen.toStringAsFixed(0)} s');
    }
    final room = math.max(0.0, inc.duration - _fadeLen - 5);
    final start = math.min(startRaw + offset, room).clamp(0.0, math.max(0.0, inc.duration)).toDouble();
    _engine.seek(other, start);
    inc.position = start;
    _automixFadeFrom = crossfaderEndFor(cur);
    xfader = _automixFadeFrom;
    // Both decks open at the centre; the channel faders do the fading.
    _fadeOutBase = out.fader;
    _fadeInBase = inc.fader;
    _engine.setXfader(0.5);
    _engine.setFader(other, 0.0);
    _eqBaseOut = EqMove(out.eqLow, out.eqMid, out.eqHigh);
    _eqBaseIn = EqMove(inc.eqLow, inc.eqMid, inc.eqHigh);
    final barReal = (inc.bpm > 1 ? 4 * 60.0 / inc.bpm : 2.0) / (inc.rate <= 0 ? 1 : inc.rate);
    _swapAt = bassSwapAt(_plan?.kind ?? TransitionKind.smooth, _fadeLen, barReal);
    _applyMixEq(cur, other, 0);
    _phaseFixed = false;
    _xfaderByHand = false;
    _engine.play(other, true);
    inc.playing = true;
    _automixFadeStart = DateTime.now();
    DebugLog.add('automix', 'mixing deck ${cur + 1} into deck ${other + 1}: ${_plan?.label ?? 'blend'}, ${_fadeLen.toStringAsFixed(1)} s (${out.bpm.round()} to ${inc.bpm.round()} BPM)');
    _automixNextTarget = next;
    _automixFading = true;
    automixStatus = null;
  }

  double _fadeOutBase = 1;
  EqMove _eqBaseOut = EqMove.none;
  EqMove _eqBaseIn = EqMove.none;
  double _swapAt = 0.6;
  bool _phaseFixed = false;

  /// Set when the DJ moves the crossfader during an automix mix; automix then
  /// stops moving it (the channel faders still fade) and leaves it where it is.
  bool _xfaderByHand = false;

  // Spots a manual skip or scrub of the playing deck: its position moves by
  // more than the time that passed.
  double _watchPos = -1;
  DateTime _watchAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _watchDeck = -1;

  /// Returns the jump in seconds (negative = back) when the playhead of the
  /// playing deck was moved by hand since the last look, else 0.
  double _skipJump(int deckIndex) {
    final d = deck(deckIndex);
    final pos = _engine.position(deckIndex);
    final now = DateTime.now();
    var jump = 0.0;
    if (_watchDeck == deckIndex && _watchPos >= 0 && d.playing) {
      final dt = now.difference(_watchAt).inMilliseconds / 1000.0;
      final expected = dt * (d.rate <= 0 ? 1 : d.rate);
      final diff = pos - _watchPos - expected;
      if (dt < 2.0 && diff.abs() > 1.5) jump = diff;
    }
    _watchDeck = deckIndex;
    _watchPos = pos;
    _watchAt = now;
    return jump;
  }

  /// A skip during a mix: undo the mix so far and let it start again from
  /// the new position (the next track stays loaded).
  void _abortFade(int cur, int other) {
    _engine.play(other, false);
    deck(other).playing = false;
    _engine.setFader(cur, _fadeOutBase);
    _engine.setFader(other, _fadeInBase);
    _restoreMixEq(cur, other);
    if (!_xfaderByHand) {
      _engine.setXfader(crossfaderEndFor(cur));
      xfader = crossfaderEndFor(cur);
    }
    _automixFading = false;
    _automixPreloaded = true;
  }

  void _applyMixEq(int cur, int other, double t) {
    final (inc, out) = eqMoves(_plan?.kind ?? TransitionKind.smooth, t, _swapAt);
    double c(double base, double off) => math.max(-24.0, base + off);
    _engine.setEq(other, c(_eqBaseIn.low, inc.low), c(_eqBaseIn.mid, inc.mid), c(_eqBaseIn.high, inc.high));
    _engine.setEq(cur, c(_eqBaseOut.low, out.low), c(_eqBaseOut.mid, out.mid), c(_eqBaseOut.high, out.high));
    final (fIn, fOut) = filterMoves(_plan?.kind ?? TransitionKind.smooth, t);
    if (fIn != 0 || fOut != 0 || t > 0) {
      _engine.setFilter(other, fIn != 0 ? fIn : deck(other).filter);
      _engine.setFilter(cur, fOut != 0 ? fOut : deck(cur).filter);
    }
  }

  /// Starting a deck takes a moment, so the new track lands slightly late.
  /// A fraction of a second in, measure how far its beats are from the old
  /// track's and move it onto them (it is still very quiet).
  void _fixMixPhase(int cur, int other) {
    final out = deck(cur);
    final inc = deck(other);
    if (out.bpm <= 1 || inc.bpm <= 1) return;
    final pOut = beatPhase(position: _engine.position(cur), bpm: out.bpm, beatOffset: out.beatOffset);
    final pIn = beatPhase(position: _engine.position(other), bpm: inc.bpm, beatOffset: inc.beatOffset);
    var delta = pOut - pIn;
    if (delta > 0.5) delta -= 1;
    if (delta < -0.5) delta += 1;
    DebugLog.add('automix', 'beat check: new track is ${(-delta * 60000.0 / inc.bpm / (inc.rate <= 0 ? 1 : inc.rate)).round()} ms off the beat (grid out ${out.beatOffset.toStringAsFixed(3)} in ${inc.beatOffset.toStringAsFixed(3)})');
    if (delta.abs() < 0.01) return;
    final target = (_engine.position(other) + delta * 60.0 / inc.bpm)
        .clamp(0.0, math.max(0.0, inc.duration))
        .toDouble();
    _engine.seek(other, target);
    inc.position = target;
  }

  void _restoreMixEq(int cur, int other) {
    _engine.setEq(other, _eqBaseIn.low, _eqBaseIn.mid, _eqBaseIn.high);
    _engine.setEq(cur, _eqBaseOut.low, _eqBaseOut.mid, _eqBaseOut.high);
    _engine.setFilter(other, deck(other).filter);
    _engine.setFilter(cur, deck(cur).filter);
  }
  double _fadeInBase = 1;

  void _automixAdvanceFade() {
    final cur = _automixDeck;
    final other = 1 - cur;
    final elapsed =
        DateTime.now().difference(_automixFadeStart).inMilliseconds / 1000.0;
    // The on-screen crossfader moves in a straight line; the sound uses the
    // two channel faders on a smooth curve: the new track rises gently from
    // silence (sin squared) while the old one falls away (cosine).
    if (!_xfaderByHand) {
      xfader = crossfaderAt(
        elapsed: elapsed,
        fadeSeconds: _fadeLen,
        from: _automixFadeFrom,
        to: crossfaderEndFor(other),
      );
    }
    final t = (elapsed / _fadeLen).clamp(0.0, 1.0);
    final (gIn, gOut) = gains(_plan?.kind ?? TransitionKind.smooth, t);
    _engine.setFader(other, _fadeInBase * gIn);
    _engine.setFader(cur, _fadeOutBase * gOut);
    _applyMixEq(cur, other, t);
    if (!_phaseFixed && elapsed >= 0.35) {
      _phaseFixed = true;
      _fixMixPhase(cur, other);
    }
    if (elapsed >= _fadeLen) {
      _engine.play(cur, false);
      deck(cur).playing = false;
      // Put both faders back and park the crossfader on the new deck.
      _engine.setFader(cur, _fadeOutBase);
      _engine.setFader(other, _fadeInBase);
      _restoreMixEq(cur, other);
      if (!_xfaderByHand) {
        _engine.setXfader(crossfaderEndFor(other));
        xfader = crossfaderEndFor(other);
      }
      DebugLog.flow('Automix mix to next deck', true);
      DebugLog.ok('automix', 'mix finished, deck ${other + 1} now playing');
      _automixDeck = other;
      final prevTrack = _flowOf(_automixQueue[_automixIndex]);
      final donePath = _automixQueue[_automixIndex];
      _automixIndex = _automixNextTarget;
      onTrackDone?.call(donePath);
      _markPlayed(_automixQueue[_automixIndex]);
      if (prevTrack != null) _flow?.played(prevTrack, _flowMove);
      _clearUpNext();
      _automixFading = false;
    }
  }

  /// True when the track is in the running automix list.
  bool inAutomixQueue(String path) => automixOn && _automixQueue.contains(path);

  /// A track has been played through in automix and is no longer needed.
  void Function(String path)? onTrackDone;

  /// Called when a library file turns out to be missing.
  void Function(String path)? onFileMissing;

  Future<bool> loadFile(
    int deckIndex,
    String path, {
    String? title,
    String? artist,
  }) async {
    DebugLog.add('load', 'deck ${deckIndex + 1} requested: ${path.split(RegExp(r'[\\/]')).last}');
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
      var detail = _engine.lastError();
      try {
        final f = File(path);
        if (!f.existsSync()) {
          detail = 'The file is gone (moved or deleted). It has been removed from the library.';
          onFileMissing?.call(path);
        } else {
          final len = f.lengthSync();
          final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '?';
          if (len == 0) {
            detail = 'The file is empty (0 bytes): the download did not save. Delete it and fetch again.';
          } else if (detail.isNotEmpty) {
            detail = '$detail [.$ext, ${(len / 1048576).toStringAsFixed(1)} MB]';
          }
        }
      } catch (e) {
        detail = 'Android will not let the app open this file ($e).';
      }
      DebugLog.flow('Load a track on a deck', false, detail);
      DebugLog.add('load', 'FAILED $path -> $detail | ${await DebugLog.describeFile(path)}');
      engineError = detail.isNotEmpty
          ? 'Could not load $name - $detail'
          : 'Could not decode $name (need MP3, WAV, FLAC, Opus, or AAC M4A).';
      notifyListeners();
      return false;
    }
    loadedPaths.add(path);
    DebugLog.flow('Load a track on a deck', true);
    DebugLog.ok('load', 'deck ${deckIndex + 1} loaded: ${path.split(RegExp(r'[\\/]')).last}');
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
    if (!d.loaded) {
      DebugLog.fail('deck', 'play pressed on deck ${deckIndex + 1} but nothing is loaded');
      return;
    }
    final next = !d.playing;
    _engine.play(deckIndex, next);
    d.playing = next;
    DebugLog.ok('deck', 'deck ${deckIndex + 1} ${next ? 'playing' : 'paused'}: ${d.title}');
    // A synced deck finds the master's beat again every time it starts.
    if (next && d.synced) _alignPhase(deckIndex);
    if (next) _logTrack(deckIndex);
    if (next && d.path != null) _countPlay(d.path!);
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
    if (_automixFading) _xfaderByHand = true; // the DJ takes over the crossfader
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
