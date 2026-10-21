import 'dart:math' as math;

/// How automix moves from one track to the next. Based on how DJs actually
/// mix each genre: long smooth blends for house/techno, short tight blends
/// for garage and breaks, and cuts on the bar line (drop swaps) for drum &
/// bass, jungle and hip hop.
enum TransitionStyle {
  auto('Auto', 'Chooses by tempo: slow and house = smooth, 130-160 = quick, 160+ and 80-100 = cut.'),
  smooth('Smooth', 'Long gradual blend. House, techno, trance, disco.'),
  quick('Quick', '8 bars blend. UK garage, breaks, electro, mid-tempo.'),
  filter('Filter', 'Sweeps a filter: old track thins out, new track opens up from muffled. Liquid DnB, ambient, chill.'),
  breakdown('Breakdown', 'Waits for a breakdown in the playing track and brings the new one in so its beat drops as the break ends. Trance, progressive, DnB.'),
  cut('Cut', 'Drops in on the bar line within one bar. Drum & bass, jungle, hip hop, breakbeat.');

  const TransitionStyle(this.label, this.blurb);
  final String label;
  final String blurb;
}

enum TransitionKind { smooth, quick, cut, filter, breakdown }

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
        TransitionKind.filter => 'filter sweep',
        TransitionKind.breakdown => 'breakdown swap',
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
    case TransitionStyle.filter:
      return TransitionKind.filter;
    case TransitionStyle.breakdown:
      return TransitionKind.breakdown;
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
  double breakSeconds = 0,
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
    case TransitionKind.filter:
      return TransitionPlan(kind, math.min(baseSeconds, 32 * bar));
    case TransitionKind.breakdown:
      final len = breakSeconds > 0 ? breakSeconds : 16 * bar;
      return TransitionPlan(kind, len.clamp(4 * bar, 32 * bar).toDouble());
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
    case TransitionKind.filter:
      return (math.sin(t * math.pi / 2), math.cos(t * math.pi / 2));
    case TransitionKind.breakdown:
      // New track fully in by the middle; old one stays until the drop swap.
      return (_ramp(t, 0, 0.5, 0, 1), _ramp(t, 0.9, 1.0, 1, 0));
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

/// EQ offsets in dB (added to the deck's own EQ) during a mix.
class EqMove {
  const EqMove(this.low, this.mid, this.high);
  final double low;
  final double mid;
  final double high;
  static const none = EqMove(0, 0, 0);
}

const double _kill = -24;

double _ramp(double t, double a, double b, double from, double to) {
  if (t <= a) return from;
  if (t >= b) return to;
  return from + (to - from) * (t - a) / (b - a);
}

/// Where the bass swap happens, as a fraction of the mix, snapped to a
/// phrase (8 bars for long mixes, 4 for short ones) so the low ends trade
/// places on a downbeat. [barSeconds] is one bar in real time.
double bassSwapAt(TransitionKind kind, double lengthSeconds, double barSeconds) {
  if (kind == TransitionKind.breakdown) return 0.9;
  final want = kind == TransitionKind.smooth ? 0.6 : 0.5;
  if (barSeconds <= 0 || lengthSeconds <= 0) return want;
  final grid = barSeconds * (lengthSeconds > 60 ? 8 : 4);
  final at = ((want * lengthSeconds) / grid).round() * grid;
  return (at / lengthSeconds).clamp(0.25, 0.8).toDouble();
}

/// The standard club blend: the new track comes in with its bass cut and a
/// little less mid and treble, which open up slowly; at the swap point the
/// bass changes hands (new track's low in, old track's low out); then the old
/// track's mids and treble fall away. Cuts need no EQ.
(EqMove, EqMove) eqMoves(TransitionKind kind, double t, double swap) {
  t = t.clamp(0.0, 1.0);
  if (kind == TransitionKind.cut) return (EqMove.none, EqMove.none);
  if (kind == TransitionKind.breakdown) {
    // No bass in the outgoing track during a break, so only the incoming
    // bass is held back until the drop.
    return (
      EqMove(_ramp(t, swap, swap + 0.02, _kill, 0), _ramp(t, 0, 0.5, -8, 0), _ramp(t, 0, 0.5, -10, 0)),
      EqMove.none,
    );
  }
  final quick = kind != TransitionKind.smooth;
  if (!quick) {
    // Long blend: the new track comes in with no bass and almost no treble
    // and opens up gradually (slow at first), so a thin minimal track and a
    // heavy dub track do not fight. The old track's treble and mids are
    // thinned out from the third of the way in.
    double ease(double x) => x * x * (3 - 2 * x);
    final openMid = ease(_ramp(t, 0, 0.8, 0, 1));
    final openHigh = ease(_ramp(t, 0, 0.88, 0, 1));
    return (
      EqMove(_ramp(t, swap, swap + 0.02, _kill, 0), -14 * (1 - openMid), -24 * (1 - openHigh)),
      EqMove(_ramp(t, swap, swap + 0.02, 0, _kill), _ramp(t, 0.3, 1, 0, -10), _ramp(t, 0.3, 1, 0, -18)),
    );
  }
  final inMid = -4.0;
  final inHigh = -6.0;
  final open = 0.5;
  final w = 0.04;
  final incoming = EqMove(
    _ramp(t, swap, swap + w, _kill, 0),
    _ramp(t, 0, open, inMid, 0),
    _ramp(t, 0, open, inHigh, 0),
  );
  final outgoing = EqMove(
    _ramp(t, swap, swap + w, 0, _kill),
    _ramp(t, swap, 1, 0, -4),
    _ramp(t, swap, 1, 0, -6),
  );
  return (incoming, outgoing);
}

/// Filter amounts (-1 high-pass .. +1 low-pass) for (incoming, outgoing).
(double, double) filterMoves(TransitionKind kind, double t) {
  t = t.clamp(0.0, 1.0);
  switch (kind) {
    case TransitionKind.filter:
      return (_ramp(t, 0, 0.6, 0.9, 0), _ramp(t, 0.4, 1, 0, -0.8));
    case TransitionKind.breakdown:
      return (_ramp(t, 0, 0.9, 0.8, 0), 0);
    default:
      return (0, 0);
  }
}

/// Finds, from [amp] (loudness per slice of the track), the end time of the
/// breakdown (a quiet stretch) that [position] is inside, or null when the
/// track is not in a breakdown or it is nearly over (< [minLeft] seconds).
double? breakdownEnd(List<double> amp, double duration, double position, double minLeft) {
  if (amp.length < 20 || duration <= 0) return null;
  final sorted = [...amp]..sort();
  final loud = sorted[(sorted.length * 0.75).floor()];
  if (loud <= 0) return null;
  final quiet = loud * 0.5;
  final binSec = duration / amp.length;
  var i = (position / binSec).floor().clamp(0, amp.length - 1);
  // Smooth over about two seconds so single quiet beats do not count.
  final w = math.max(1, (2.0 / binSec).round());
  double avg(int k) {
    var sum = 0.0;
    var n = 0;
    for (var j = k; j < math.min(amp.length, k + w); j++) {
      sum += amp[j];
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  if (avg(i) >= quiet) return null;
  var j = i;
  while (j < amp.length && avg(j) < quiet) {
    j++;
  }
  final end = j * binSec;
  return end - position >= minLeft ? end : null;
}
