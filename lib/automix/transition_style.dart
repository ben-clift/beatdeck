import 'dart:math' as math;

/// How automix moves from one track to the next. Based on how DJs actually
/// mix each genre: long smooth blends for house/techno, short tight blends
/// for garage and breaks, and cuts on the bar line (drop swaps) for drum &
/// bass, jungle and hip hop.
enum TransitionStyle {
  auto('Auto', 'Chooses by tempo: slow and house = smooth, 130-160 = quick, 160+ and 80-100 = cut.'),
  smooth('Smooth', 'Long gradual blend. House, techno, trance, disco.'),
  quick('Quick', '8 bars blend. UK garage, breaks, electro, mid-tempo.'),
  cut('Cut', 'Drops in on the bar line within one bar. Drum & bass, jungle, hip hop, breakbeat.');

  const TransitionStyle(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum TransitionKind { smooth, quick, cut }

class TransitionPlan {
  const TransitionPlan(this.kind, this.seconds);
  final TransitionKind kind;

  /// Length of the fade itself.
  final double seconds;

  /// The cut waits for the next bar line of the playing track.
  bool get onBarLine => kind == TransitionKind.cut;

  String get label => switch (kind) {
        TransitionKind.smooth => 'smooth blend',
        TransitionKind.quick => 'quick blend',
        TransitionKind.cut => 'cut on the bar line',
      };
}

/// Picks the kind of transition from the style and the two tempos.
TransitionKind kindFor(TransitionStyle style, double outBpm, double inBpm) {
  switch (style) {
    case TransitionStyle.smooth:
      return TransitionKind.smooth;
    case TransitionStyle.quick:
      return TransitionKind.quick;
    case TransitionStyle.cut:
      return TransitionKind.cut;
    case TransitionStyle.auto:
      final b = inBpm > 1 ? inBpm : outBpm;
      if (b <= 1) return TransitionKind.smooth;
      if (b >= 160) return TransitionKind.cut; // drum & bass, jungle
      if (b >= 78 && b <= 100) return TransitionKind.cut; // hip hop, R&B
      if (b >= 130) return TransitionKind.quick; // garage, breaks, grime
      return TransitionKind.smooth; // house, techno, disco
  }
}

/// [baseSeconds] is the user's mix length; quick and cut shorten it.
TransitionPlan planFor(
  TransitionStyle style, {
  required double outBpm,
  required double inBpm,
  required double baseSeconds,
}) {
  final kind = kindFor(style, outBpm, inBpm);
  final bpm = inBpm > 1 ? inBpm : (outBpm > 1 ? outBpm : 120.0);
  final bar = 4 * 60.0 / bpm;
  switch (kind) {
    case TransitionKind.smooth:
      return TransitionPlan(kind, baseSeconds);
    case TransitionKind.quick:
      return TransitionPlan(kind, math.min(baseSeconds, 8 * bar));
    case TransitionKind.cut:
      return TransitionPlan(kind, math.min(baseSeconds, bar));
  }
}

/// Fader levels (0..1) for the incoming and outgoing deck at progress [t].
(double, double) gains(TransitionKind kind, double t) {
  t = t.clamp(0.0, 1.0);
  switch (kind) {
    case TransitionKind.smooth:
      return (math.pow(math.sin(t * math.pi / 2), 2).toDouble(), math.cos(t * math.pi / 2));
    case TransitionKind.quick:
      // Straighter: the new track is heard sooner.
      return (math.sin(t * math.pi / 2), math.cos(t * math.pi / 2));
    case TransitionKind.cut:
      // Sharp crossfader curve: swapped within the first quarter.
      final s = (t * 4).clamp(0.0, 1.0);
      return (s, 1 - s);
  }
}

/// True when [position] is just after a bar line of a track with [bpm] and
/// first beat at [beatOffset]. [window] is a little wider than one tick.
bool nearBarLine(double position, double bpm, double beatOffset, {double window = 0.07}) {
  if (bpm <= 1) return true;
  final bar = 4 * 60.0 / bpm;
  final into = (position - beatOffset) % bar;
  return into >= 0 && into <= window;
}
