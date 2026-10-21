import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/music_utils.dart';

/// Tracks the DJ deleted from a playlist: they are not liked, so automix never
/// picks them again and auto-fetch never searches for them. Kept on the phone.
class Dislikes extends ChangeNotifier {
  Dislikes._();
  static final Dislikes instance = Dislikes._();

  // Each entry: full normalised file name, artist, title (normalised).
  final List<({String full, String artist, String title, String name, int at})> _items = [];

  /// Newest first, for the log page.
  List<({String name, int at})> get log =>
      [for (final i in _items.reversed) (name: i.name, at: i.at)];
  bool _loaded = false;

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String _nameOf(String path) {
    var name = path.split(RegExp(r'[\\/]')).last;
    name = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return name.replaceFirst(RegExp(r'\s*\(\d+\)$'), '');
  }

  int get count => _items.length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      for (final raw in p.getStringList('disliked_v1') ?? const <String>[]) {
        final m = jsonDecode(raw) as List;
        _items.add((
          full: m[0] as String,
          artist: m[1] as String,
          title: m[2] as String,
          name: m.length > 3 ? m[3] as String : (m[1] as String).isEmpty ? m[2] as String : '${m[1]} - ${m[2]}',
          at: m.length > 4 ? m[4] as int : 0,
        ));
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('disliked_v1', [
        for (final i in _items) jsonEncode([i.full, i.artist, i.title, i.name, i.at]),
      ]);
    } catch (_) {}
  }

  ({String full, String artist, String title, String name, int at}) _entryFor(String path) {
    final name = _nameOf(path);
    final parsed = splitTitleArtist(name);
    return (
      full: _norm(name),
      artist: _norm(parsed.artist),
      title: _norm(parsed.title),
      name: name,
      at: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// A file the DJ disliked (the same file, or a copy of it).
  bool hasPath(String path) {
    if (_items.isEmpty) return false;
    final e = _entryFor(path);
    for (final i in _items) {
      if (i.full == e.full && i.full.isNotEmpty) return true;
    }
    return false;
  }

  /// A suggestion (artist and title from a chart or list) matching a disliked track.
  bool hasTrack(String artist, String title) {
    if (_items.isEmpty) return false;
    final a = _norm(artist);
    final t = _norm(title);
    if (t.length < 3) return false;
    for (final i in _items) {
      final sameTitle = i.title == t || (i.title.length >= 4 && i.title.contains(t) && t.length >= 4) ||
          (t.length >= 4 && t.contains(i.title) && i.title.length >= 4);
      if (sameTitle &&
          (i.artist.isEmpty || a.isEmpty || i.artist.contains(a) || a.contains(i.artist))) {
        return true;
      }
      if (a.isNotEmpty && i.full.contains(t) && i.full.contains(a)) return true;
    }
    return false;
  }

  Future<void> add(String path) async {
    final e = _entryFor(path);
    if (e.full.isEmpty || _items.any((i) => i.full == e.full)) return;
    _items.add(e);
    notifyListeners();
    await _save();
  }

  Future<void> remove(String path) async {
    final e = _entryFor(path);
    _items.removeWhere((i) => i.full == e.full);
    notifyListeners();
    await _save();
  }

  /// Allow one logged track again (by its position in [log]).
  Future<void> allowAgain(int logIndex) async {
    final idx = _items.length - 1 - logIndex;
    if (idx < 0 || idx >= _items.length) return;
    _items.removeAt(idx);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _items.clear();
    notifyListeners();
    await _save();
  }
}
