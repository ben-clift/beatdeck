import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/suggest_service.dart';

/// Artists that fit a genre, from Bandcamp's tag pages and Discogs' style
/// search. Names only (no audio is taken from either site). Each genre is read
/// at most once a week and kept on the phone; a failed read waits a day.
abstract class Discover {
  static const _maxAge = Duration(days: 7);
  static const _retry = Duration(hours: 24);
  static const _ua = 'BeatDeck/1.0 (personal DJ app)';

  static String slug(String g) =>
      g.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  static Future<List<Suggestion>> _cached(String key, String reason, {bool stale = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null) return [];
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(m['t'] as int);
      if (!stale && DateTime.now().difference(at) > _maxAge) return [];
      return [for (final a in (m['a'] as List)) Suggestion(a as String, '', 0, reason)];
    } catch (_) {
      return [];
    }
  }

  static Future<List<Suggestion>> _through(
    String name,
    String genre,
    Future<List<String>> Function(String slug) read,
  ) async {
    final s = slug(genre);
    if (s.isEmpty) return [];
    final key = 'disc_${name}_$s';
    final reason = name == 'bandcamp' ? 'Bandcamp' : 'Discogs';
    final fresh = await _cached(key, reason);
    if (fresh.isNotEmpty) return fresh;
    final p = await SharedPreferences.getInstance();
    final t = p.getInt('${key}_try');
    if (t != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t)) < _retry) {
      return _cached(key, reason, stale: true);
    }
    await p.setInt('${key}_try', DateTime.now().millisecondsSinceEpoch);
    try {
      final names = await read(s);
      final seen = <String>{};
      final artists = [
        for (final n in names)
          if (n.trim().isNotEmpty && seen.add(n.toLowerCase())) n.trim(),
      ];
      DebugLog.add(name, '$genre: ${artists.length} artists, first: ${artists.isEmpty ? '-' : artists.first}');
      if (artists.isEmpty) return _cached(key, reason, stale: true);
      await p.setString(key, jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'a': artists}));
      return [for (final a in artists) Suggestion(a, '', 0, reason)];
    } catch (e) {
      DebugLog.add(name, 'could not read $genre: $e');
      return _cached(key, reason, stale: true);
    }
  }

  /// Bandcamp: the artists with the newest and best-selling releases under a tag.
  static Future<List<Suggestion>> bandcamp(String genre) => _through('bandcamp', genre, (s) async {
        final out = <String>[];
        for (final slice in const ['new', 'top']) {
          final r = await http
              .post(
                Uri.parse('https://bandcamp.com/api/discover/1/discover_web'),
                headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
                body: jsonEncode({
                  'category_id': 0,
                  'tag_norm_names': [s],
                  'geoname_id': 0,
                  'slice': slice,
                  'time_facet_id': null,
                  'cursor': '*',
                  'size': 60,
                  'include_result_types': ['a', 's'],
                }),
              )
              .timeout(const Duration(seconds: 20));
          if (r.statusCode != 200) throw Exception('Bandcamp answered ${r.statusCode}');
          final m = jsonDecode(r.body) as Map<String, dynamic>;
          for (final e in (m['results'] as List? ?? const [])) {
            final n = (e as Map)['band_name'];
            if (n is String && !RegExp(r'records|recordings|label|music|audio|collective', caseSensitive: false).hasMatch(n)) out.add(n);
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        return out;
      });

  /// Discogs: artists of the most wanted releases in a style. Needs a free
  /// personal token (Discogs asks for one on searches).
  static String token = '';

  static Future<void> loadToken() async {
    try {
      token = (await SharedPreferences.getInstance()).getString('discogs_token') ?? '';
    } catch (_) {}
  }

  static Future<void> saveToken(String t) async {
    token = t.trim();
    try {
      await (await SharedPreferences.getInstance()).setString('discogs_token', token);
    } catch (_) {}
  }

  static Future<List<Suggestion>> discogs(String genre) async {
    if (token.isEmpty) await loadToken();
    if (token.isEmpty) {
      DebugLog.add('discogs', 'no Discogs token set (free at discogs.com/settings/developers), skipped');
      return [];
    }
    return _through('discogs', genre, (s) async {
      final style = s.split('-').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
      final r = await http.get(
        Uri.https('api.discogs.com', '/database/search', {
          'type': 'release',
          'style': style,
          'sort': 'want',
          'sort_order': 'desc',
          'per_page': '60',
        }),
        headers: {'User-Agent': _ua, 'Authorization': 'Discogs token=$token'},
      ).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw Exception('Discogs answered ${r.statusCode}');
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final out = <String>[];
      for (final e in (m['results'] as List? ?? const [])) {
        final t = (e as Map)['title'];
        if (t is! String) continue;
        final i = t.indexOf(' - ');
        if (i <= 0) continue;
        final a = t.substring(0, i).replaceFirst(RegExp(r'\s*\(\d+\)$'), '');
        if (a.toLowerCase() != 'various') out.add(a);
      }
      return out;
    });
  }
}
