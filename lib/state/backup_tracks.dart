import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';

/// "Backup tracks": a playlist for tracks you are bored of right now. They
/// come off the deck and out of automix but are kept (never deleted as played
/// downloads) so you can play the list another day.
class BackupTracks {
  static const name = 'Backup tracks';
  static const _prefsKey = 'local_playlists';

  /// Paths currently in Backup tracks. The library and automix leave these
  /// out until they are taken out of the playlist.
  static final ValueNotifier<Set<String>> hidden = ValueNotifier(<String>{});

  static void setHidden(Iterable<String> paths) {
    final s = paths.toSet();
    if (s.length == hidden.value.length && s.containsAll(hidden.value)) return;
    hidden.value = s;
  }

  /// Puts [path] in the Backup tracks playlist, creating it if needed.
  static Future<void> add(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaylistStore.decode(prefs.getString(_prefsKey));
    var pl = store.playlists.where((p) => p.name == name).firstOrNull;
    pl ??= store.create(name);
    store.add(pl.id, path);
    await prefs.setString(_prefsKey, store.encode());
    await PlaylistController.reloadAll();
  }

  /// Every path in the Backup tracks playlist.
  static Future<Set<String>> paths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = PlaylistStore.decode(prefs.getString(_prefsKey));
      return {
        for (final p in store.playlists)
          if (p.name == name) ...p.paths,
      };
    } catch (_) {
      return {};
    }
  }
}
