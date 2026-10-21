import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/engine/tags.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';

/// What the DJ likes, read from the playlists saved on the phone: the artists
/// whose tracks are in them. Used to put those artists first when automix
/// looks for a new track, and to try other tracks by the same artists.
class Taste {
  static Set<String> artists = {};
  static Set<String> labels = {};
  static final Map<String, String> _display = {};
  static final Map<String, String> _genre = {};

  static String _norm(String a) => a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static bool likes(String artist) {
    final n = _norm(artist);
    if (n.isEmpty) return false;
    // "Artist, Other" or "Artist & Other" counts when any name is liked.
    for (final part in n.split(RegExp(r'\s(?:and|feat|ft|vs|x)\s|,'))) {
      if (artists.contains(part.trim())) return true;
    }
    return artists.contains(n);
  }

  /// A record label that appears in your playlists.
  static bool likesLabel(String label) {
    final n = _norm(label);
    return n.length >= 2 && labels.contains(n);
  }

  /// Artist or label from your playlists.
  static bool likesTrack(String artist, String label) => likes(artist) || likesLabel(label);

  /// A label from a file name such as "name-[perl 015]-1999" gives "perl".
  static String _labelFromName(String name) {
    final m = RegExp(r'[\[\(]([a-z][a-z0-9 &.\x27]*?)[\s_-]*\d{1,4}[a-z]?[\]\)]', caseSensitive: false)
        .firstMatch(name);
    return m == null ? '' : m.group(1)!.trim();
  }

  /// The genre of a liked artist's tracks in your library, '' when unknown.
  static String genreOf(String artist) {
    final n = _norm(artist);
    for (final part in n.split(RegExp(r'\s(?:and|feat|ft|vs|x)\s|,'))) {
      final g = _genre[part.trim()];
      if (g != null && g.isNotEmpty) return g;
    }
    return _genre[n] ?? '';
  }

  /// Up to [n] random liked artists, as they were written. With [genre],
  /// artists known to make a different kind of music are left out (a dub
  /// artist is not offered after minimal house).
  static List<String> pick(int n, {Set<String> except = const {}, String genre = ''}) {
    final all = [
      for (final a in artists)
        if (!except.contains(a) && (genre.isEmpty || genresSimilar(genre, _genre[a] ?? '')))
          _display[a] ?? a,
    ]..shuffle();
    return all.take(math.max(0, n)).toList();
  }

  static Future<void> refresh(LibraryController lib) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = PlaylistStore.decode(prefs.getString('local_playlists'));
      final byPath = {for (final t in lib.tracks) t.path: t};
      final found = <String>{};
      final foundLabels = <String>{};
      // Labels read from tags are kept (path to label) so files are read once.
      Map<String, dynamic> cache = {};
      try {
        cache = jsonDecode(prefs.getString('taste_labels_v1') ?? '{}') as Map<String, dynamic>;
      } catch (_) {}
      var reads = 0;
      for (final pl in store.playlists) {
        for (final path in pl.paths) {
          var artist = byPath[path]?.artist ?? '';
          if (artist.trim().isEmpty) {
            final name = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
            final dash = name.indexOf(' - ');
            if (dash > 0) artist = name.substring(0, dash);
          }
          final n = _norm(artist);
          if (n.length < 2) continue;
          found.add(n);
          _display[n] = artist.trim();
          final tg = byPath[path]?.genre ?? '';
          if (tg.isNotEmpty) _genre[n] = tg;
          // The record label: from the tags, else from the file name.
          var label = cache[path] as String?;
          if (label == null && reads < 150) {
            reads++;
            try {
              label = (await readTrackTags(path)).label;
            } catch (_) {
              label = '';
            }
            if (label.isEmpty) label = _labelFromName(path.split(RegExp(r'[\\/]')).last);
            cache[path] = label;
          }
          final ln = _norm(label ?? '');
          if (ln.length >= 2) foundLabels.add(ln);
        }
      }
      artists = found;
      labels = foundLabels;
      try {
        await prefs.setString('taste_labels_v1', jsonEncode(cache));
      } catch (_) {}
    } catch (_) {}
  }
}
