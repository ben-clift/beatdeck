import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/playlist_store.dart';

/// Local playlists, saved on the phone in app preferences.
class PlaylistController extends ChangeNotifier {
  PlaylistController() {
    restore();
  }

  static const _prefsKey = 'local_playlists';

  PlaylistStore _store = PlaylistStore();
  bool _disposed = false;

  List<Playlist> get playlists => List.unmodifiable(_store.playlists);
  Playlist? byId(String id) => _store.byId(id);

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _store = PlaylistStore.decode(prefs.getString(_prefsKey));
      if (_store.pruneMissing((p) => File(p).existsSync()) > 0) {
        await _save();
      }
    } catch (_) {
      _store = PlaylistStore();
    }
    _emit();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _store.encode());
    } catch (_) {
      // Saving is best effort; the playlists still work until the app closes.
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<Playlist> create(String name) async {
    final p = _store.create(name);
    _emit();
    await _save();
    return p;
  }

  Future<void> rename(String id, String name) async {
    if (_store.rename(id, name)) {
      _emit();
      await _save();
    }
  }

  Future<void> delete(String id) async {
    if (_store.delete(id)) {
      _emit();
      await _save();
    }
  }

  /// Returns false if the track was already in the playlist.
  Future<bool> add(String id, String path) async {
    final ok = _store.add(id, path);
    if (ok) {
      _emit();
      await _save();
    }
    return ok;
  }

  Future<void> removeAt(String id, int index) async {
    if (_store.removeAt(id, index)) {
      _emit();
      await _save();
    }
  }

  Future<void> move(String id, int from, int to) async {
    if (_store.move(id, from, to)) {
      _emit();
      await _save();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
