/// Ready-made settings for the 10-band master equaliser
/// (31, 62, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz), in dB.
class EqPreset {
  const EqPreset(this.name, this.hint, this.bands);
  final String name;
  final String hint;
  final List<double> bands;
}

const List<EqPreset> eqPresets = [
  EqPreset('Flat', 'No change', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqPreset('Bass boost', 'More low end for small or thin systems', [8, 7, 5, 2, 0, 0, 0, 0, 0, 0]),
  EqPreset('Club', 'Big-room punch: strong lows, crisp highs', [5, 4, 1, -1, -2, 0, 1, 3, 4, 3]),
  EqPreset('Warehouse', 'Dark and heavy: lows up, highs rolled off', [4, 4, 2, 0, -1, -2, -3, -3, -4, -5]),
  EqPreset('Warm', 'Softer, smoother, less harsh', [3, 3, 2, 1, 0, 0, -1, -2, -3, -4]),
  EqPreset('Bright', 'More air and sparkle on top', [0, 0, 0, -1, 0, 1, 2, 4, 6, 7]),
  EqPreset('Vocal', 'Pushes voices and leads forward', [-3, -3, -2, 0, 2, 4, 4, 2, 0, -1]),
  EqPreset('Smile (V)', 'Lows and highs up, mids scooped', [6, 5, 2, -2, -4, -3, 0, 3, 5, 6]),
  EqPreset('Loudness', 'Fuller sound at low volume', [5, 4, 2, 0, 0, 0, 0, 1, 3, 4]),
  EqPreset('Headphones', 'Gentle lift at both ends', [3, 2, 1, 0, 0, 0, -1, 0, 2, 3]),
  EqPreset('Car', 'Cuts road-noise mud, lifts bass and treble', [5, 4, 1, -1, -1, 0, 2, 2, 3, 2]),
  EqPreset('Dub / sub', 'Huge sub bass, tame mids', [8, 6, 2, -2, -3, -2, -1, 0, 1, 0]),
  EqPreset('Cut the mud', 'Clears boxy low-mids', [0, 0, -2, -5, -3, 0, 0, 0, 0, 0]),
  EqPreset('Phone speaker', 'Little bass, strong mids: for tiny speakers', [-12, -12, -6, -2, 2, 3, 3, 2, 1, 0]),
  EqPreset('Radio', 'Mid-range focus, like an old radio', [-6, -4, 0, 2, 3, 3, 2, 1, 0, -2]),
  EqPreset('No bass', 'Cuts the low end for a bass-free breakdown', [-12, -12, -12, -8, -2, 0, 0, 0, 0, 0]),
];
