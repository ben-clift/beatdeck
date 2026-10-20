import 'package:sidedeck/engine/music_utils.dart';

/// A key on the Camelot wheel: number 1..12 and A (minor) or B (major).
class CamelotKey {
  const CamelotKey(this.number, this.minor);

  final int number;
  final bool minor;

  String get code => '$number${minor ? 'A' : 'B'}';

  CamelotKey step(int n) => CamelotKey(((number - 1 + n) % 12 + 12) % 12 + 1, minor);

  CamelotKey get relative => CamelotKey(number, !minor);

  /// From the engine's key index: 0..11 major, 12..23 minor.
  static CamelotKey? fromIndex(int k) {
    if (k < 0 || k > 23) return null;
    return parse(k < 12 ? camelotMajor[k] : camelotMinor(k - 12));
  }

  /// Reads "8A", "11b" and the like.
  static CamelotKey? parse(String s) {
    final m = RegExp(r'^(1[0-2]|[1-9])\s*([ABab])$').firstMatch(s.trim());
    if (m == null) return null;
    return CamelotKey(int.parse(m.group(1)!), m.group(2)!.toUpperCase() == 'A');
  }

  /// The key index again (root pitch class + mode).
  int get index {
    for (var r = 0; r < 12; r++) {
      if (!minor && camelotMajor[r] == code) return r;
      if (minor && camelotMinor(r) == code) return 12 + r;
    }
    return 0;
  }

  @override
  bool operator ==(Object o) => o is CamelotKey && o.number == number && o.minor == minor;

  @override
  int get hashCode => number * 2 + (minor ? 1 : 0);
}

/// How two keys sit together, as DJ software with a wheel shows it.
class KeyMatch {
  const KeyMatch(this.score, this.label);

  /// 0 means clashing.
  final int score;
  final String label;
}

KeyMatch keyMatch(CamelotKey from, CamelotKey to) {
  if (from == to) return const KeyMatch(100, 'Same key');
  if (to == from.step(1) || to == from.step(-1)) {
    return const KeyMatch(90, 'Next to it on the wheel');
  }
  if (to == from.relative) return const KeyMatch(85, 'Relative key, new mood');
  if (to == from.step(2)) return const KeyMatch(70, 'Energy lift (+2)');
  if (to == from.step(7)) return const KeyMatch(60, 'Energy boost (+7)');
  return const KeyMatch(0, 'Clashes');
}

/// Every key that mixes well with [k], best first.
List<(CamelotKey, KeyMatch)> compatibleKeys(CamelotKey k) {
  final all = <CamelotKey>[
    k,
    k.step(1),
    k.step(-1),
    k.relative,
    k.step(2),
    k.step(7),
  ];
  return [for (final c in all) (c, keyMatch(k, c))];
}

/// A clashing key can often be rescued by shifting its pitch a little. Returns
/// the smallest shift (semitones, -2..2) that makes [other] mix with [from],
/// or null when none does. 0 means it already mixes.
int? semitoneFix(CamelotKey from, int otherIndex) {
  final minor = otherIndex >= 12;
  final root = otherIndex % 12;
  for (final s in [0, 1, -1, 2, -2]) {
    final idx = ((root + s) % 12 + 12) % 12 + (minor ? 12 : 0);
    final c = CamelotKey.fromIndex(idx);
    if (c != null && keyMatch(from, c).score >= 85) return s;
  }
  return null;
}

/// Percent tempo change needed to bring [other] to [target], trying half and
/// double time too. Smallest absolute value wins.
double bpmGapPercent(double target, double other) {
  if (target <= 0 || other <= 0) return 999;
  double best = 999;
  for (final f in [0.5, 1.0, 2.0]) {
    final g = (target / (other * f) - 1) * 100;
    if (g.abs() < best.abs()) best = g;
  }
  return best;
}

/// Camelot code and tempo that people put in file names, e.g.
/// "8A - 124 - Artist - Title.mp3" or "Title [124 BPM]".
({CamelotKey? key, double? bpm}) parseNameHints(String name) {
  CamelotKey? key;
  double? bpm;
  final k = RegExp(r'(?<![0-9A-Za-z])(1[0-2]|[1-9])\s?([ABab])(?![0-9A-Za-z])')
      .firstMatch(name);
  if (k != null) key = CamelotKey.parse('${k.group(1)}${k.group(2)}');
  final b = RegExp(r'(?<![0-9])(\d{2,3})(?:\.\d+)?\s?bpm', caseSensitive: false)
      .firstMatch(name);
  if (b != null) {
    bpm = double.tryParse(b.group(1)!);
  } else if (k != null) {
    final n = RegExp(r'(?<![0-9])(\d{2,3})(?![0-9])').allMatches(name);
    for (final m in n) {
      final v = double.parse(m.group(1)!);
      if (v >= 70 && v <= 200 && m.start != k.start) {
        bpm = v;
        break;
      }
    }
  }
  return (key: key, bpm: bpm);
}
