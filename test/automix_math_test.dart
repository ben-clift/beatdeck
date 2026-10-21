import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/state/automix_math.dart';

void main() {
  test('remainingSeconds uses rate and never goes negative', () {
    expect(remainingSeconds(position: 60, duration: 180, rate: 1.0), 120);
    expect(remainingSeconds(position: 60, duration: 180, rate: 2.0), 60);
    expect(remainingSeconds(position: 200, duration: 180, rate: 1.0), 0);
    expect(remainingSeconds(position: 10, duration: 180, rate: 0), 0);
  });

  test('beatPhase at 120 bpm', () {
    // 120 bpm = 0.5 s per beat, first beat at 1.0 s.
    expect(beatPhase(position: 1.0, bpm: 120, beatOffset: 1.0), closeTo(0, 1e-9));
    expect(beatPhase(position: 1.25, bpm: 120, beatOffset: 1.0), closeTo(0.5, 1e-9));
    expect(beatPhase(position: 1.5, bpm: 120, beatOffset: 1.0), closeTo(0, 1e-9));
    // Before the first beat still gives a value from 0 up to 1.
    expect(beatPhase(position: 0.75, bpm: 120, beatOffset: 1.0), closeTo(0.5, 1e-9));
    expect(beatPhase(position: 5, bpm: 0, beatOffset: 0), 0);
  });

  test('incoming start lines up the beat', () {
    // Outgoing is half way through a beat (120 bpm). Incoming is 100 bpm
    // (0.6 s per beat) with its first beat at 0.2 s.
    final pos = incomingStartPosition(
      outPosition: 1.25,
      outBpm: 120,
      outBeatOffset: 1.0,
      inBpm: 100,
      inBeatOffset: 0.2,
    );
    expect(pos, closeTo(0.2 + 0.5 * 0.6, 1e-9));
  });

  test('incoming start falls back without beat data', () {
    expect(
      incomingStartPosition(
        outPosition: 30,
        outBpm: 0,
        outBeatOffset: 0,
        inBpm: 128,
        inBeatOffset: 0.4,
      ),
      0.4,
    );
    expect(
      incomingStartPosition(
        outPosition: 30,
        outBpm: 120,
        outBeatOffset: 0,
        inBpm: 128,
        inBeatOffset: -1,
      ),
      0.0,
    );
  });

  test('incomingRate matches heard tempo, limited to 8 %', () {
    expect(incomingRate(outBpm: 120, outRate: 1.0, inBpm: 110), closeTo(120 / 110, 1e-9));
    expect(incomingRate(outBpm: 120, outRate: 1.0, inBpm: 100), 1.08);
    expect(incomingRate(outBpm: 120, outRate: 1.05, inBpm: 126), closeTo(1.0, 1e-9));
    expect(incomingRate(outBpm: 0, outRate: 1.0, inBpm: 100), 1.0);
    expect(incomingRate(outBpm: 200, outRate: 1.0, inBpm: 60), 1.08);
    // half / double-time reads match on the same beat
    expect(incomingRate(outBpm: 65, outRate: 1.0, inBpm: 130), closeTo(1.0, 1e-9));
    expect(incomingRate(outBpm: 130, outRate: 1.0, inBpm: 65), closeTo(1.0, 1e-9));
  });

  test('preload and fade timing', () {
    expect(shouldPreload(remaining: 60, fadeSeconds: 12), isFalse);
    expect(shouldPreload(remaining: 37, fadeSeconds: 12), isTrue);
    expect(shouldStartFade(remaining: 13, fadeSeconds: 12), isFalse);
    expect(shouldStartFade(remaining: 12, fadeSeconds: 12), isTrue);
  });

  test('crossfaderAt ramps and clamps', () {
    expect(crossfaderAt(elapsed: 0, fadeSeconds: 10, from: 0, to: 1), 0);
    expect(crossfaderAt(elapsed: 5, fadeSeconds: 10, from: 0, to: 1), 0.5);
    expect(crossfaderAt(elapsed: 12, fadeSeconds: 10, from: 0, to: 1), 1);
    expect(crossfaderAt(elapsed: 5, fadeSeconds: 10, from: 1, to: 0), 0.5);
    expect(crossfaderAt(elapsed: 1, fadeSeconds: 0, from: 0, to: 1), 1);
    expect(crossfaderEndFor(0), 0.0);
    expect(crossfaderEndFor(1), 1.0);
  });

  test('nextIndex ends or loops', () {
    expect(nextIndex(current: 0, length: 3), 1);
    expect(nextIndex(current: 2, length: 3), isNull);
    expect(nextIndex(current: 2, length: 3, loop: true), 0);
    expect(nextIndex(current: 0, length: 0), isNull);
  });
}
