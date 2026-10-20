import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/dj_controller.dart';

/// Something a MIDI control can drive.
class MidiAction {
  MidiAction(this.id, this.label, this.continuous, this.apply);

  final String id;
  final String label;

  /// Knobs and faders (0..1). Otherwise a button that fires on press.
  final bool continuous;
  final void Function(DjController dj, double v) apply;
}

List<MidiAction> buildMidiActions() {
  final out = <MidiAction>[];
  for (var d = 0; d < DjController.deckCount; d++) {
    final n = d + 1;
    out.add(MidiAction('play$d', 'Deck $n  Play / pause', false, (dj, v) => dj.playPause(d)));
    out.add(MidiAction('cue$d', 'Deck $n  Cue', false, (dj, v) => dj.cue(d)));
    out.add(MidiAction('sync$d', 'Deck $n  Sync', false, (dj, v) => dj.sync(d)));
    out.add(MidiAction('fader$d', 'Deck $n  Channel fader', true, (dj, v) => dj.setFader(d, v)));
    out.add(MidiAction('gain$d', 'Deck $n  Gain', true, (dj, v) => dj.setGain(d, v * 1.5)));
    out.add(MidiAction('eqh$d', 'Deck $n  EQ high', true, (dj, v) => dj.setEq(d, high: v * 2)));
    out.add(MidiAction('eqm$d', 'Deck $n  EQ mid', true, (dj, v) => dj.setEq(d, mid: v * 2)));
    out.add(MidiAction('eql$d', 'Deck $n  EQ low', true, (dj, v) => dj.setEq(d, low: v * 2)));
    out.add(MidiAction('filter$d', 'Deck $n  Filter', true, (dj, v) => dj.setFilter(d, v * 2 - 1)));
    out.add(MidiAction('keyup$d', 'Deck $n  Key up', false, (dj, v) => dj.setKeyShift(d, dj.deck(d).keyShift + 1)));
    out.add(MidiAction('keydn$d', 'Deck $n  Key down', false, (dj, v) => dj.setKeyShift(d, dj.deck(d).keyShift - 1)));
    for (var h = 0; h < 8; h++) {
      out.add(MidiAction('hot$d.$h', 'Deck $n  Hot cue ${h + 1}', false, (dj, v) => dj.hotcue(d, h)));
    }
  }
  out.add(MidiAction('xfader', 'Crossfader', true, (dj, v) => dj.setXfader(v)));
  out.add(MidiAction('master', 'Master volume', true, (dj, v) => dj.setMaster(v)));
  for (var s = 0; s < DjController.samplerSlots; s++) {
    out.add(MidiAction('samp$s', 'Sampler pad ${s + 1}', false, (dj, v) => dj.fireSample(s)));
  }
  return out;
}

/// Connects to USB / Bluetooth MIDI controllers and maps their controls onto
/// the app, with a learn mode: pick an action, then move the control.
class MidiController extends ChangeNotifier {
  MidiController(this.dj) {
    _restore();
    _setupSub = _midi.onMidiSetupChanged?.listen((_) => refresh());
    _dataSub = _midi.onMidiDataReceived?.listen(_onData);
    refresh();
  }

  final DjController dj;
  final MidiCommand _midi = MidiCommand();
  final List<MidiAction> actions = buildMidiActions();
  StreamSubscription<dynamic>? _setupSub;
  StreamSubscription<dynamic>? _dataSub;

  List<MidiDevice> devices = [];
  final Set<String> connected = {};
  String? error;

  /// Action waiting for the next control to be moved.
  String? learning;

  /// What the last message looked like, for the screen.
  String lastSeen = '';

  /// "n:channel:number" or "c:channel:number" to action id.
  final Map<String, String> mapping = {};

  MidiAction? actionById(String id) {
    for (final a in actions) {
      if (a.id == id) return a;
    }
    return null;
  }

  String? keyFor(String actionId) {
    for (final e in mapping.entries) {
      if (e.value == actionId) return e.key;
    }
    return null;
  }

  Future<void> refresh() async {
    try {
      devices = await _midi.devices ?? <MidiDevice>[];
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> connect(MidiDevice d) async {
    try {
      await _midi.connectToDevice(d);
      connected.add(d.id);
      error = null;
    } catch (e) {
      error = 'Could not connect: $e';
    }
    notifyListeners();
  }

  void disconnect(MidiDevice d) {
    try {
      _midi.disconnectDevice(d);
    } catch (_) {}
    connected.remove(d.id);
    notifyListeners();
  }

  void startLearn(String actionId) {
    learning = actionId;
    notifyListeners();
  }

  void cancelLearn() {
    learning = null;
    notifyListeners();
  }

  void clear(String actionId) {
    mapping.removeWhere((_, v) => v == actionId);
    _save();
    notifyListeners();
  }

  void _onData(dynamic event) {
    final m = (event as MidiDataReceivedEvent).message;
    String? key;
    double value = 0;
    if (m is CCMessage) {
      key = 'c:${m.channel}:${m.controller}';
      value = m.value / 127.0;
      lastSeen = 'CC ${m.controller}  value ${m.value}  channel ${m.channel + 1}';
    } else if (m is NoteOnMessage) {
      key = 'n:${m.channel}:${m.note}';
      value = m.velocity > 0 ? 1.0 : 0.0;
      lastSeen = 'Note ${m.note}  velocity ${m.velocity}  channel ${m.channel + 1}';
    } else if (m is NoteOffMessage) {
      key = 'n:${m.channel}:${m.note}';
      value = 0;
      lastSeen = 'Note ${m.note} off';
    } else {
      return;
    }
    final want = learning;
    if (want != null) {
      // Only presses and moves teach, not releases.
      if (value == 0 && key.startsWith('n:')) return;
      mapping.removeWhere((k, v) => v == want || k == key);
      mapping[key] = want;
      learning = null;
      _save();
      notifyListeners();
      return;
    }
    final id = mapping[key];
    if (id == null) {
      notifyListeners();
      return;
    }
    final a = actionById(id);
    if (a == null) return;
    if (a.continuous) {
      a.apply(dj, value);
    } else if (value > 0) {
      a.apply(dj, 1);
    }
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('midi_map');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        mapping
          ..clear()
          ..addAll(j.map((k, v) => MapEntry(k, v as String)));
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('midi_map', jsonEncode(mapping));
    } catch (_) {}
  }

  @override
  void dispose() {
    _setupSub?.cancel();
    _dataSub?.cancel();
    super.dispose();
  }
}

/// One shared instance, created the first time the MIDI screen is opened.
MidiController? _shared;
MidiController midiFor(DjController dj) => _shared ??= MidiController(dj);
