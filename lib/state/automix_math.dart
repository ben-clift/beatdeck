/// Plain Dart maths for automix (no Flutter, no engine), so it can be tested.
///
/// Terms: "position" is seconds into the track file. "rate" is the tempo
/// multiplier (1.0 = original speed). "beatOffset" is where the first beat of
/// the beat grid falls in the file, in seconds. "bpm" is the file's original
/// tempo, so the tempo you hear is bpm * rate.

/// Seconds of real time left in a track at its current rate.
double remainingSeconds({
  required double position,
  required double duration,
  required double rate,
}) {
  if (rate <= 0 || duration <= position) return 0;
  return (duration - position) / rate;
}

/// How far through the current beat the playhead is, from 0 up to (not
/// including) 1. Returns 0 when there is no usable beat grid.
double beatPhase({
  required double position,
  required double bpm,
  required double beatOffset,
}) {
  if (bpm <= 1) return 0;
  final beats = (position - beatOffset) * bpm / 60.0;
  final frac = beats - beats.floorToDouble();
  return frac < 0 ? frac + 1 : frac;
}

/// Where to start the incoming track so its beat lines up with the outgoing
/// track right now. If either track has no beat grid the incoming track simply
/// starts from its first beat (or 0).
double incomingStartPosition({
  required double outPosition,
  required double outBpm,
  required double outBeatOffset,
  required double inBpm,
  required double inBeatOffset,
}) {
  final inOffset = inBeatOffset < 0 ? 0.0 : inBeatOffset;
  if (outBpm <= 1 || inBpm <= 1) return inOffset;
  final phase = beatPhase(
    position: outPosition,
    bpm: outBpm,
    beatOffset: outBeatOffset,
  );
  return inOffset + phase * 60.0 / inBpm;
}

/// Tempo multiplier that makes the incoming track play at the outgoing
/// track's heard tempo. Falls back to 1.0 without BPM data and is limited to
/// the engine's range (0.5 to 2.0).
double incomingRate({
  required double outBpm,
  required double outRate,
  required double inBpm,
}) {
  if (outBpm <= 1 || inBpm <= 1) return 1.0;
  return (outBpm * outRate / inBpm).clamp(0.5, 2.0).toDouble();
}

/// True when the incoming track should start now: the outgoing track has
/// [fadeSeconds] or less to run.
bool shouldStartFade({
  required double remaining,
  required double fadeSeconds,
}) {
  return remaining <= fadeSeconds;
}

/// True when the next track should be loaded onto the idle deck: it needs
/// time to load and analyse before the fade starts.
bool shouldPreload({
  required double remaining,
  required double fadeSeconds,
  double leadSeconds = 25,
}) {
  return remaining <= fadeSeconds + leadSeconds;
}

/// Crossfader value [elapsed] seconds into a fade lasting [fadeSeconds],
/// moving from [from] to [to] (0 = deck A, 1 = deck B).
double crossfaderAt({
  required double elapsed,
  required double fadeSeconds,
  required double from,
  required double to,
}) {
  if (fadeSeconds <= 0 || elapsed >= fadeSeconds) return to;
  if (elapsed <= 0) return from;
  return from + (to - from) * (elapsed / fadeSeconds);
}

/// The crossfader end that favours [deck] (0 = A, 1 = B).
double crossfaderEndFor(int deck) => deck == 0 ? 0.0 : 1.0;

/// Index to play after [current] in a list of [length] tracks, or null at the
/// end. With [loop] it wraps round to the start.
int? nextIndex({required int current, required int length, bool loop = false}) {
  if (length <= 0) return null;
  final next = current + 1;
  if (next < length) return next;
  return loop ? 0 : null;
}
