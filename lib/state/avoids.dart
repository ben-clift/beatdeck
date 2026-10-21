import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/genre_family.dart';

/// "Less of this": what the DJ pressed the Less button on. Automix and
/// auto-fetch steer away from the same artist, and from the same kind of
/// genre at about the same tempo. Nothing is deleted or disliked, and
/// [clear] puts everything back.
class Avoids extends ChangeNotifier {
  Avoids._();
  static final Avoids instance = Avoids._();

  static const _prefKey = 'avoids_v1';
  final List<({String artist, String family, double bpm})> _items = [];
  bool _loaded = false;

  int get count => _items.length;
  bool get isEmpty => _items.isEmpty;

  static String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      for (final raw in p.getStringList(_prefKey) ?? const <String>[]) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        _items.add((
          artist: m['a'] as String? ?? '',
          family: m['f'] as String? ?? '',
          bpm: (m['b'] as num?)?.toDouble() ?? 0,
        ));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_prefKey, [
        for (final i in _items) jsonEncode({'a': i.artist, 'f': i.family, 'b': i.bpm}),
      ]);
    } catch (_) {}
  }

  void add({required String artist, required String genre, required double bpm}) {
    final a = norm(artist);
    final f = (genreFamily(genre) ?? '').toString();
    if (a.isEmpty && f.isEmpty) return;
    _items.add((artist: a, family: f, bpm: bpm));
    if (_items.length > 60) _items.removeAt(0);
    _save();
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    _save();
    notifyListeners();
  }

  /// True when a track with this artist / genre / tempo is one to steer away from.
  bool rejects({String artist = '', String genre = '', double bpm = 0}) {
    if (_items.isEmpty) return false;
    final a = norm(artist);
    final f = (genreFamily(genre) ?? '').toString();
    for (final i in _items) {
      if (a.isNotEmpty && i.artist.isNotEmpty && a == i.artist) return true;
      if (f.isNotEmpty && f == i.family && bpm > 0 && i.bpm > 0 &&
          (bpm - i.bpm).abs() / i.bpm <= 0.06) {
        return true;
      }
    }
    return false;
  }
}
