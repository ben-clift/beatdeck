import 'dart:math' as math;

import 'package:sidedeck/suggest/harmony.dart';

/// The shape of energy over a set.
enum FlowArc {
  off('Off', 'Plays in list order'),
  journey('Journey', 'Warm up, build, peak late, ease down'),
  peak('Peak', 'High from start to finish'),
  build('Build', 'Energy only rises'),
  steady('Steady', 'Narrow band, interest from variety'),
  cooldown('Cool-down', 'Starts high and eases off');

  const FlowArc(this.label, this.blurb);
  final String label;
  final String blurb;

  /// Target energy 0..1 at [t] (0 = start of the set, 1 = end).
  double energy(double t) {
    t = t.clamp(0.0, 1.0);
    switch (this) {
      case FlowArc.off:
        return 0.5;
      case FlowArc.journey:
        // Rise to a main peak about two thirds through, then ease down.
        if (t < 0.66) return 0.2 + 0.75 * (t / 0.66);
        return 0.95 - 0.5 * ((t - 0.66) / 0.34);
      case FlowArc.peak:
        return 0.85;
      case FlowArc.build:
        return 0.2 + 0.75 * t;
      case FlowArc.steady:
        return 0.5;
      case FlowArc.cooldown:
        return 0.9 - 0.65 * t;
    }
  }

  /// Longer blends when calm, quicker switches at the peak.
  double fadeScale(double energy) => 1.35 - 0.7 * energy.clamp(0.0, 1.0);
}

/// What the picker knows about a track.
class FlowTrack {
  FlowTrack(this.path, {this.bpm = 0, this.key, this.artist = ''});
  final String path;
  final double bpm;
  final CamelotKey? key;
  final String artist;
}

class FlowPick {
  FlowPick(this.index, this.energy, this.moveLabel);
  final int index;
  final double energy;
  final String moveLabel;
}

/// Chooses what plays next so a set follows an arc and does not repeat the
/// same kind of move: key moves rotate, artists are spaced out, tempo steps
/// are small, and the target wobbles up and down a little.
class SetFlow {
  SetFlow(this.arc, {required this.lengthMinutes, math.Random? random})
      : _rnd = random ?? math.Random();

  FlowArc arc;
  final double lengthMinutes;
  final math.Random _rnd;
  final List<String> _moves = [];
  final List<String> _artists = [];
  DateTime started = DateTime.now();

  double get progress =>
      (DateTime.now().difference(started).inSeconds / 60.0 / lengthMinutes)
          .clamp(0.0, 1.0);

  void played(FlowTrack t, String move) {
    _moves.add(move);
    if (t.artist.isNotEmpty) _artists.add(t.artist.toLowerCase());
  }

  static String moveOf(CamelotKey? a, CamelotKey? b) {
    if (a == null || b == null) return '?';
    return keyMatch(a, b).label;
  }

  /// [candidates] are unplayed tracks with their queue index.
  FlowPick? pick(FlowTrack? current, List<(int, FlowTrack)> candidates) {
    if (candidates.isEmpty) return null;
    final bpms = [for (final c in candidates) if (c.$2.bpm > 0) c.$2.bpm];
    if (current != null && current.bpm > 0) bpms.add(current.bpm);
    bpms.sort();
    final lo = bpms.isEmpty ? 0.0 : bpms.first;
    final hi = bpms.isEmpty ? 0.0 : bpms.last;
    double energyOf(FlowTrack t) {
      if (t.bpm <= 0 || hi - lo < 3) return 0.5;
      return (t.bpm - lo) / (hi - lo);
    }

    // Wobble: alternate a little up and down so energy is never a straight line.
    final wobble = (_moves.length.isEven ? 0.07 : -0.07);
    final target = (arc.energy(progress) + wobble).clamp(0.0, 1.0);
    FlowPick? best;
    var bestScore = -1e9;
    for (final (i, c) in candidates) {
      var s = 0.0;
      final e = energyOf(c);
      s -= (e - target).abs() * 100;
      if (c.bpm <= 0) s -= 15;
      if (current != null && current.bpm > 0 && c.bpm > 0) {
        final gap = bpmGapPercent(current.bpm, c.bpm).abs();
        s -= gap > 8 ? 60 : gap * 2;
      }
      final move = moveOf(current?.key, c.key);
      if (current?.key != null && c.key != null) {
        final m = keyMatch(current!.key!, c.key!).score;
        s += (m - 60) * 0.4;
        if (_moves.isNotEmpty && _moves.last == move) s -= 10;
        if (_moves.length > 1 && _moves.last == move && _moves[_moves.length - 2] == move) {
          s -= 20;
        }
      }
      final recent = _artists.length > 5 ? _artists.sublist(_artists.length - 5) : _artists;
      if (c.artist.isNotEmpty && recent.contains(c.artist.toLowerCase())) s -= 40;
      s += _rnd.nextDouble() * 10;
      if (s > bestScore) {
        bestScore = s;
        best = FlowPick(i, e, move);
      }
    }
    return best;
  }
}
