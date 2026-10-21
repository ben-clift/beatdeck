import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/suggest/taste.dart';

/// Resident Advisor: the latest single reviews and "RA Recommends", plus the
/// artist pages of artists in your playlists. Read at most once a week and
/// kept on the phone (a failed read waits a day). Names only: artist and
/// title, nothing else is taken. RA builds its pages with JavaScript, so the
/// reader looks for the data embedded in the page and falls back to link
/// text; whatever it finds, or fails to find, is written to the debug log.
class RaSource {
  static const _maxAge = Duration(days: 7);
  static const _retryAfter = Duration(hours: 24);
  static const _key = 'ra_v1';
  static const _tryKey = 'ra_try';
  static const _headers = {
    'User-Agent': 'BeatDeck/1.0 (personal DJ app)',
    'Accept': 'text/html',
  };
  static const _pages = [
    'https://ra.co/reviews/singles',
    'https://ra.co/reviews/recommends',
  ];

  static Future<List<Suggestion>>? _running;

  static Future<List<Suggestion>?> _cached({bool stale = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(m['t'] as int);
      if (!stale && DateTime.now().difference(at) > _maxAge) return null;
      return [
        for (final e in (m['items'] as List))
          Suggestion((e as List)[0] as String, e[1] as String, 0, 'RA'),
      ];
    } catch (_) {
      return null;
    }
  }

  static String _clean(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _slug(String artist) =>
      artist.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  /// Walks JSON found in the page and collects objects that look like a
  /// release or track: a title and artists, and not an event.
  static void _walk(dynamic n, List<Suggestion> out, int depth) {
    if (depth > 30) return;
    if (n is Map) {
      if (n.containsKey('venue') || n.containsKey('startTime') || n.containsKey('attending')) {
        return; // an event, not music
      }
      final title = n['title'];
      final a = n['artists'] ?? n['artist'];
      String? name;
      if (a is List) {
        name = a
            .map((x) => x is Map ? x['name'] : x)
            .whereType<String>()
            .take(2)
            .join(', ');
      } else if (a is Map && a['name'] is String) {
        name = a['name'] as String;
      } else if (a is String) {
        name = a;
      }
      if (title is String && name != null && name.isNotEmpty && title.length < 120) {
        out.add(Suggestion(name.trim(), title.trim(), 0, 'RA'));
      }
      for (final v in n.values) {
        _walk(v, out, depth + 1);
      }
    } else if (n is List) {
      for (final e in n) {
        _walk(e, out, depth + 1);
      }
    }
  }

  static List<Suggestion> parse(String html) {
    final out = <Suggestion>[];
    for (final m in RegExp(
            r'<script[^>]*type="application/(?:json|ld\+json)"[^>]*>([\s\S]*?)</script>',
            caseSensitive: false)
        .allMatches(html)) {
      try {
        _walk(jsonDecode(m.group(1)!), out, 0);
      } catch (_) {}
    }
    if (out.isEmpty) {
      // Plain links to reviews whose text reads "Artist - Title".
      for (final m
          in RegExp(r'href="/reviews/\d+[^"]*"[^>]*>([\s\S]*?)</a>').allMatches(html)) {
        final t = _clean(m.group(1)!);
        final d = RegExp(r'^(.{2,60}?)\s[–—-]\s(.{2,90})$').firstMatch(t);
        if (d != null) out.add(Suggestion(d.group(1)!, d.group(2)!, 0, 'RA'));
      }
    }
    return out;
  }

  /// Everything read in the last week (reviews and liked artists' pages).
  static Future<List<Suggestion>> all() {
    return _running ??= _load().whenComplete(() => _running = null);
  }

  static Future<List<Suggestion>> _load() async {
    final fresh = await _cached();
    if (fresh != null && fresh.isNotEmpty) {
      DebugLog.add('ra', 'using the saved RA list (read within the last week, ${fresh.length} tracks)');
      return fresh;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('ra_gate_v2') ?? false)) {
      await prefs.setBool('ra_gate_v2', true);
      await prefs.remove(_tryKey);
    }
    final t = prefs.getInt(_tryKey);
    if (t != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t)) < _retryAfter) {
      DebugLog.add('ra', 'last read failed, waiting before trying RA again');
      return await _cached(stale: true) ?? <Suggestion>[];
    }
    await prefs.setInt(_tryKey, DateTime.now().millisecondsSinceEpoch);
    final urls = [..._pages];
    for (final a in Taste.pick(8)) {
      final s = _slug(a);
      if (s.length >= 2) urls.add('https://ra.co/dj/$s');
    }
    final all = <Suggestion>[];
    final seen = <String>{};
    for (final u in urls) {
      try {
        final r = await http.get(Uri.parse(u), headers: _headers).timeout(const Duration(seconds: 20));
        final got = r.statusCode == 200 ? parse(r.body) : <Suggestion>[];
        DebugLog.add('ra',
            '$u: ${r.statusCode}, ${r.body.length} bytes, ${got.length} tracks${got.isEmpty ? '' : ', first: ${got.first.artist} - ${got.first.title}'}');
        for (final x in got) {
          if (seen.add(x.query.toLowerCase())) all.add(x);
        }
      } catch (e) {
        DebugLog.add('ra', '$u: could not read ($e)');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (all.isEmpty) {
      DebugLog.add('ra', 'nothing found on the RA pages (they may need JavaScript or block automated reads)');
      return await _cached(stale: true) ?? <Suggestion>[];
    }
    try {
      await prefs.setString(
        _key,
        jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'items': [for (final s in all.take(math.min(all.length, 400))) [s.artist, s.title]],
        }),
      );
    } catch (_) {}
    DebugLog.add('ra', 'read RA: ${all.length} tracks');
    return all;
  }
}
