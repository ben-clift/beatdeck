import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CreateC = Pointer<Void> Function();
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _StartC = Int32 Function(Pointer<Void>);
typedef _StopC = Void Function(Pointer<Void>);
typedef _SetModeC = Int32 Function(Pointer<Void>, Int32);
typedef _GetIntC = Int32 Function(Pointer<Void>);
typedef _LoadC = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LoadAnalyzedC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf8>,
  Float,
  Int32,
  Float,
);
typedef _UnloadC = Void Function(Pointer<Void>, Int32);
typedef _PlayC = Void Function(Pointer<Void>, Int32, Int32);
typedef _SeekC = Void Function(Pointer<Void>, Int32, Double);
typedef _PosC = Double Function(Pointer<Void>, Int32);
typedef _PlayingC = Int32 Function(Pointer<Void>, Int32);
typedef _SetFloatDeckC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetEqC = Void Function(Pointer<Void>, Int32, Float, Float, Float);
typedef _SetXfaderC = Void Function(Pointer<Void>, Float);
typedef _SetMasterC = Void Function(Pointer<Void>, Float);
typedef _GetBpmC = Float Function(Pointer<Void>, Int32);
typedef _GetKeyC = Int32 Function(Pointer<Void>, Int32);
typedef _NudgeC = Void Function(Pointer<Void>, Int32, Float);
typedef _SetLoopC = Void Function(Pointer<Void>, Int32, Int32, Float);
typedef _BeatJumpC = Void Function(Pointer<Void>, Int32, Int32);
typedef _DeckC = Void Function(Pointer<Void>, Int32);
typedef _HotcueSetC = Void Function(Pointer<Void>, Int32, Int32, Double);
typedef _HotcueGetC = Double Function(Pointer<Void>, Int32, Int32);
typedef _WaveBinsC = Int32 Function();
typedef _WaveCopyC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Float>,
  Pointer<Float>,
  Int32,
);

class NativeEngine {
  NativeEngine._(this._lib, this._handle);

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;
  bool started = false;

  late final _destroy = _lib.lookupFunction<_DestroyC, void Function(Pointer<Void>)>(
    'dj_destroy',
  );
  late final _start = _lib.lookupFunction<_StartC, int Function(Pointer<Void>)>(
    'dj_start',
  );
  late final _stop = _lib.lookupFunction<_StopC, void Function(Pointer<Void>)>(
    'dj_stop',
  );
  late final _setMode = _lib
      .lookupFunction<_SetModeC, int Function(Pointer<Void>, int)>(
        'dj_set_output_mode',
      );
  late final _getChannels = _lib.lookupFunction<_GetIntC, int Function(Pointer<Void>)>(
    'dj_get_output_channels',
  );
  late final _load = _lib
      .lookupFunction<_LoadC, int Function(Pointer<Void>, int, Pointer<Utf8>)>(
        'dj_load',
      );
  late final _lastError = _lib
      .lookupFunction<_LastErrorC, Pointer<Utf8> Function()>('dj_last_error');
  late final _loadAnalyzed = _lib.lookupFunction<
    _LoadAnalyzedC,
    int Function(Pointer<Void>, int, Pointer<Utf8>, double, int, double)
  >('dj_load_with_analysis');
  late final _unload = _lib
      .lookupFunction<_UnloadC, void Function(Pointer<Void>, int)>('dj_unload');
  late final _play = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>('dj_play');
  late final _seek = _lib
      .lookupFunction<_SeekC, void Function(Pointer<Void>, int, double)>('dj_seek');
  late final _position = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_position');
  late final _duration = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_duration');
  late final _playing = _lib
      .lookupFunction<_PlayingC, int Function(Pointer<Void>, int)>('dj_playing');
  late final _setGain = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_gain',
      );
  late final _setEq = _lib
      .lookupFunction<
        _SetEqC,
        void Function(Pointer<Void>, int, double, double, double)
      >('dj_set_eq');
  late final _setFilter = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_filter',
      );
  late final _setFader = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_fader',
      );
  late final _setXfader = _lib
      .lookupFunction<_SetXfaderC, void Function(Pointer<Void>, double)>(
        'dj_set_xfader',
      );
  late final _setMaster = _lib
      .lookupFunction<_SetMasterC, void Function(Pointer<Void>, double)>(
        'dj_set_master',
      );
  late final _setRate = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_rate',
      );
  late final _setMasterEq = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_master_eq',
      );
  late final _setFx = _lib.lookupFunction<
      Void Function(Pointer<Void>, Int32, Float, Float),
      void Function(Pointer<Void>, int, double, double)>('dj_set_fx');
  late final _setDeckFx = _lib.lookupFunction<
      Void Function(Pointer<Void>, Int32, Int32, Float, Float),
      void Function(Pointer<Void>, int, int, double, double)>('dj_set_deck_fx');
  late final _recStart = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>),
      int Function(Pointer<Void>, Pointer<Utf8>)>('dj_record_start');
  late final _recStop = _lib.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('dj_record_stop');
  late final _recSeconds = _lib.lookupFunction<Double Function(Pointer<Void>),
      double Function(Pointer<Void>)>('dj_record_seconds');
  late final _getSpectrum = _lib.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Float>, Int32),
      void Function(Pointer<Void>, Pointer<Float>, int)>('dj_get_spectrum');
  late final _setBpm = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_bpm',
      );
  late final _setKeylock = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>(
        'dj_set_keylock',
      );
  late final _samplerLoad = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>),
      int Function(Pointer<Void>, int, Pointer<Utf8>)>('dj_sampler_load');
  late final _samplerFire = _lib
      .lookupFunction<_DeckC, void Function(Pointer<Void>, int)>('dj_sampler_fire');
  late final _samplerStop = _lib
      .lookupFunction<_DeckC, void Function(Pointer<Void>, int)>('dj_sampler_stop');
  late final _samplerVolume = _lib.lookupFunction<
      Void Function(Pointer<Void>, Float),
      void Function(Pointer<Void>, double)>('dj_sampler_volume');
  late final _setCueDeck = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>(
        'dj_set_cue_deck',
      );
  late final _setCueMode = _lib.lookupFunction<
      Void Function(Pointer<Void>, Int32, Float, Float),
      void Function(Pointer<Void>, int, double, double)>('dj_set_cue_mode');
  late final _setKeyShift = _lib
      .lookupFunction<_SetFloatDeckC, void Function(Pointer<Void>, int, double)>(
        'dj_set_key_shift',
      );
  late final _setCue = _lib
      .lookupFunction<_DeckC, void Function(Pointer<Void>, int)>('dj_set_cue');
  late final _jumpCue = _lib
      .lookupFunction<_DeckC, void Function(Pointer<Void>, int)>('dj_jump_cue');
  late final _setHotcue = _lib
      .lookupFunction<_HotcueSetC, void Function(Pointer<Void>, int, int, double)>(
        'dj_set_hotcue',
      );
  late final _jumpHotcue = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>(
        'dj_jump_hotcue',
      );
  late final _getHotcue = _lib
      .lookupFunction<_HotcueGetC, double Function(Pointer<Void>, int, int)>(
        'dj_get_hotcue',
      );
  late final _clearHotcue = _lib
      .lookupFunction<_PlayC, void Function(Pointer<Void>, int, int)>(
        'dj_clear_hotcue',
      );
  late final _getBpm = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>('dj_get_bpm');
  late final _getKey = _lib
      .lookupFunction<_GetKeyC, int Function(Pointer<Void>, int)>('dj_get_key');
  late final _getBeatOffset = _lib
      .lookupFunction<_GetBpmC, double Function(Pointer<Void>, int)>(
        'dj_get_beat_offset',
      );
  late final _nudgeGrid = _lib
      .lookupFunction<_NudgeC, void Function(Pointer<Void>, int, double)>(
        'dj_nudge_grid',
      );
  late final _setLoop = _lib
      .lookupFunction<_SetLoopC, void Function(Pointer<Void>, int, int, double)>(
        'dj_set_loop',
      );
  late final _loopStart = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_start');
  late final _loopEnd = _lib
      .lookupFunction<_PosC, double Function(Pointer<Void>, int)>('dj_loop_end');
  late final _beatJump = _lib
      .lookupFunction<_BeatJumpC, void Function(Pointer<Void>, int, int)>(
        'dj_beat_jump',
      );
  late final _waveBins = _lib.lookupFunction<_WaveBinsC, int Function()>(
    'dj_waveform_bins',
  );
  late final _waveCopy = _lib
      .lookupFunction<
        _WaveCopyC,
        int Function(
          Pointer<Void>,
          int,
          Pointer<Float>,
          Pointer<Float>,
          int,
        )
      >('dj_waveform_copy');

  static NativeEngine open() {
    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libdj_engine.so')
        : DynamicLibrary.process();
    final create = lib.lookupFunction<_CreateC, _CreateC>('dj_create');
    final handle = create();
    final engine = NativeEngine._(lib, handle);
    engine.started = engine._start(handle) == 1;
    return engine;
  }

  void dispose() {
    _stop(_handle);
    _destroy(_handle);
  }

  bool setExternalMixer(bool enabled) {
    final ok = _setMode(_handle, enabled ? 1 : 0) == 1;
    if (ok) started = true;
    return ok;
  }

  int get outputChannels => _getChannels(_handle);
  int get nativeHandle => _handle.address;

  bool load(
    int deck,
    String path, {
    double? bpm,
    int? key,
    double? beatOffset,
  }) {
    final p = path.toNativeUtf8();
    try {
      if (bpm != null && bpm > 1) {
        return _loadAnalyzed(
              _handle,
              deck,
              p,
              bpm,
              key ?? -1,
              beatOffset ?? 0,
            ) ==
            1;
      }
      return _load(_handle, deck, p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  /// Reason for the last failed [load], or empty if none / success.
  String lastError() {
    final ptr = _lastError();
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }

  void unload(int deck) => _unload(_handle, deck);
  void play(int deck, bool playing) => _play(_handle, deck, playing ? 1 : 0);
  void seek(int deck, double seconds) => _seek(_handle, deck, seconds);
  double position(int deck) => _position(_handle, deck);
  double duration(int deck) => _duration(_handle, deck);
  bool isPlaying(int deck) => _playing(_handle, deck) == 1;
  void setGain(int deck, double v) => _setGain(_handle, deck, v);
  void setEq(int deck, double low, double mid, double high) =>
      _setEq(_handle, deck, low, mid, high);
  void setFilter(int deck, double amount) => _setFilter(_handle, deck, amount);
  void setFader(int deck, double v) => _setFader(_handle, deck, v);
  void setXfader(double x) => _setXfader(_handle, x);
  void setMaster(double v) => _setMaster(_handle, v);
  void setRate(int deck, double rate) => _setRate(_handle, deck, rate);
  void setBpm(int deck, double bpm) => _setBpm(_handle, deck, bpm);

  /// Master graphic equaliser: [band] 0..9, [db] -12..+12.
  void setMasterEq(int band, double db) => _setMasterEq(_handle, band, db);

  /// Master effect: [type] 0 off, 1 echo, 2 reverb, 3 flanger.
  void setFx(int type, double amount, double timeSec) =>
      _setFx(_handle, type, amount, timeSec);

  /// Effect pads on one deck. [mask] bit 0..7 = effect on or off.
  void setDeckFx(int deck, int mask, double amount, double timeSec) =>
      _setDeckFx(_handle, deck, mask, amount, timeSec);

  /// Records the master output to a WAV file.
  bool recordStart(String path) {
    final p = path.toNativeUtf8();
    try {
      return _recStart(_handle, p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  void recordStop() => _recStop(_handle);

  double recordSeconds() => _recSeconds(_handle);

  static const int spectrumBands = 14;

  /// Linear levels (0..1ish) of the 14 analyser bands.
  List<double> spectrum() {
    final ptr = malloc<Float>(spectrumBands);
    try {
      _getSpectrum(_handle, ptr, spectrumBands);
      return [for (var i = 0; i < spectrumBands; i++) ptr[i]];
    } finally {
      malloc.free(ptr);
    }
  }
  void setCue(int deck) => _setCue(_handle, deck);
  void jumpCue(int deck) => _jumpCue(_handle, deck);
  /// Sets hot cue [index] at [seconds], or at the playhead if negative.
  void setHotcue(int deck, int index, double seconds) =>
      _setHotcue(_handle, deck, index, seconds);
  void jumpHotcue(int deck, int index) => _jumpHotcue(_handle, deck, index);
  double hotcue(int deck, int index) => _getHotcue(_handle, deck, index);
  void clearHotcue(int deck, int index) => _clearHotcue(_handle, deck, index);
  bool samplerLoad(int slot, String path) {
    final p = path.toNativeUtf8();
    try {
      return _samplerLoad(_handle, slot, p) == 1;
    } finally {
      malloc.free(p);
    }
  }

  void samplerFire(int slot) => _samplerFire(_handle, slot);

  void samplerStop(int slot) => _samplerStop(_handle, slot);

  void samplerVolume(double v) => _samplerVolume(_handle, v);

  void setCueDeck(int deck, bool on) => _setCueDeck(_handle, deck, on ? 1 : 0);

  void setCueMode(int mode, double volume, double mix) =>
      _setCueMode(_handle, mode, volume, mix);

  void setKeyShift(int deck, double semitones) =>
      _setKeyShift(_handle, deck, semitones);

  void setKeylock(int deck, bool enabled) =>
      _setKeylock(_handle, deck, enabled ? 1 : 0);
  double bpm(int deck) => _getBpm(_handle, deck);
  int key(int deck) => _getKey(_handle, deck);
  double beatOffset(int deck) => _getBeatOffset(_handle, deck);
  void nudgeGrid(int deck, double seconds) => _nudgeGrid(_handle, deck, seconds);
  void setLoop(int deck, bool enabled, double bars) =>
      _setLoop(_handle, deck, enabled ? 1 : 0, bars);
  double loopStart(int deck) => _loopStart(_handle, deck);
  double loopEnd(int deck) => _loopEnd(_handle, deck);
  void beatJump(int deck, int beats) => _beatJump(_handle, deck, beats);

  ({Float32List min, Float32List max}) waveform(int deck) {
    final bins = _waveBins();
    final minPtr = malloc<Float>(bins);
    final maxPtr = malloc<Float>(bins);
    try {
      final n = _waveCopy(_handle, deck, minPtr, maxPtr, bins);
      return (
        min: Float32List.fromList(minPtr.asTypedList(n)),
        max: Float32List.fromList(maxPtr.asTypedList(n)),
      );
    } finally {
      malloc.free(minPtr);
      malloc.free(maxPtr);
    }
  }
}
