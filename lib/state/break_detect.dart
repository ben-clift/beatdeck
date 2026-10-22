import 'dart:math' as math;
import 'dart:typed_data';

/// A breakdown: the loud, driving part drops away for a while, then the track
/// hits again. Times are seconds into the track, snapped to bar lines.
class BreakSpan {
  const BreakSpan(this.start, this.end);
  final double start;
  final double end;
}

/// Finds breakdowns from the waveform overview (loudness over the track).
/// A break is a stretch of at least 12 beats that is clearly quieter than the
/// body of the track, with loud music both before it and after it (so intros
/// and outros are not breaks).
List<BreakSpan> findBreaks({
  required Float32List min,
  required Float32List max,
  required double duration,
  required double bpm,
  required double beatOffset,
}) {
  final n = math.min(min.length, max.length);
  if (n < 64 || duration < 60 || bpm < 60 || bpm > 200) return const [];
  final beat = 60.0 / bpm;
  final bar = beat * 4;
  // One loudness value per beat.
  final m = (duration / beat).floor();
  if (m < 64) return const [];
  final binsPerBeat = n / (duration / beat);
  final env = List<double>.filled(m, 0);
  for (var j = 0; j < m; j++) {
    final a = (j * binsPerBeat).floor();
    final b = math.min(n, math.max(a + 1, ((j + 1) * binsPerBeat).floor()));
    var sum = 0.0;
    for (var k = a; k < b; k++) {
      sum += (max[k] - min[k]).abs();
    }
    env[j] = sum / (b - a);
  }
  // Smooth over one bar.
  final s = List<double>.filled(m, 0);
  for (var j = 0; j < m; j++) {
    var sum = 0.0;
    var c = 0;
    for (var k = math.max(0, j - 2); k <= math.min(m - 1, j + 1); k++) {
      sum += env[k];
      c++;
    }
    s[j] = sum / c;
  }
  // The body of the track: the 70th percentile of the middle 80 %.
  final mid = s.sublist((m * 0.1).floor(), (m * 0.9).ceil())..sort();
  if (mid.isEmpty) return const [];
  final base = mid[(mid.length * 0.7).floor().clamp(0, mid.length - 1)];
  if (base <= 0.02) return const [];
  final low = base * 0.55;
  final out = <BreakSpan>[];
  var j = 0;
  while (j < m) {
    if (s[j] >= low) {
      j++;
      continue;
    }
    var e = j;
    while (e < m && s[e] < low) {
      e++;
    }
    final len = e - j;
    final loudBefore = j >= 8 && s[j - 8] >= base * 0.8;
    final loudAfter = e + 8 <= m && s[math.min(m - 1, e + 4)] >= base * 0.75;
    if (len >= 12 && len <= 160 && loudBefore && loudAfter) {
      double snap(double t) => beatOffset + ((t - beatOffset) / bar).round() * bar;
      final st = snap(j * beat);
      final en = snap(e * beat);
      if (en - st >= bar * 2) out.add(BreakSpan(st, en));
    }
    j = e + 1;
  }
  return out;
}
