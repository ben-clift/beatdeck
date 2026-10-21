import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Star ratings, 0 to 3, per track. A starred track is never deleted by the
/// app (not by the bin, the library, duplicate clean-up or played-track
/// clean-up).
class Ratings extends ChangeNotifier {
  Ratings._();
  static final Ratings instance = Ratings._();

  static const key = 'track_stars_v1';
  final Map<String, int> _stars = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final m = jsonDecode(p.getString(key) ?? '{}') as Map<String, dynamic>;
      for (final e in m.entries) {
        _stars[e.key] = (e.value as num).toInt();
      }
      notifyListeners();
    } catch (_) {}
  }

  int starsOf(String path) => _stars[path] ?? 0;

  /// Paths with at least one star.
  Iterable<String> get starred => [
        for (final e in _stars.entries)
          if (e.value > 0) e.key,
      ];

  Future<void> set(String path, int stars) async {
    final n = stars.clamp(0, 3);
    if (n == 0) {
      _stars.remove(path);
    } else {
      _stars[path] = n;
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(_stars));
    } catch (_) {}
  }

  /// One tap on a star: that many stars, or none when it is already that many.
  Future<void> tap(String path, int n) => set(path, starsOf(path) == n ? 0 : n);
}
