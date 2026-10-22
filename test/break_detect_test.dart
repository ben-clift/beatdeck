import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/state/break_detect.dart';

void main() {
  test('finds a breakdown between two loud parts', () {
    const dur = 300.0;
    const bpm = 120.0; // beat 0.5 s, bar 2 s
    const n = 30000;
    final mn = Float32List(n), mx = Float32List(n);
    for (var k = 0; k < n; k++) {
      final t = k / n * dur;
      final inBreak = t >= 120 && t < 152;
      final amp = inBreak ? 0.15 : 0.8;
      mx[k] = amp;
      mn[k] = -amp;
    }
    final b = findBreaks(min: mn, max: mx, duration: dur, bpm: bpm, beatOffset: 0);
    expect(b.length, 1);
    expect(b.first.start, closeTo(120, 2.1));
    expect(b.first.end, closeTo(152, 2.1));
  });

  test('an outro is not a break', () {
    const dur = 300.0;
    const n = 30000;
    final mn = Float32List(n), mx = Float32List(n);
    for (var k = 0; k < n; k++) {
      final t = k / n * dur;
      final amp = t > 260 ? 0.1 : 0.8;
      mx[k] = amp;
      mn[k] = -amp;
    }
    expect(findBreaks(min: mn, max: mx, duration: dur, bpm: 120, beatOffset: 0), isEmpty);
  });
}
