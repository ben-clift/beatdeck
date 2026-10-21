import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/wishlist/wishlist.dart';

/// Reads release names from public Hardwax tag pages. Their robots.txt allows
/// ordinary page reads (it only blocks basket, checkout, audio and download),
/// so this fetches one page at a time, only when asked, and takes names only:
/// no audio, no previews, no downloads from the shop.
class Hardwax {
  static const tags = <(String, String)>[
    ('This week', 'this-week'),
    ('Ambient', 'ambient'),
    ('Basic Channel', 'basic-channel'),
    ('Bass', 'bass'),
    ('Chicago Oldschool', 'chicago-oldschool'),
    ('Detroit', 'detroit'),
    ('Detroit House', 'detroit-house'),
    ('Drum & Bass', 'drum-and-bass'),
    ('Drexciya', 'drexciya'),
    ('Electro', 'electro'),
    ('Electronica', 'electronica'),
    ('Grime', 'grime'),
    ('House', 'house'),
    ('New Global Styles', 'new-global-styles'),
    ('Techno', 'techno'),
    ('Reggae - Dub', 'reggae-dub'),
  ];

  static String _text(String html) {
    var s = html
        .replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(div|p|li|h[1-6]|tr|section|article|a)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ');
    return s;
  }

  /// Hardwax updates its lists weekly, so each tag page is read from the shop
  /// at most once a week; in between, the saved list is used. After a failed
  /// read nothing is tried again for a day.
  static const _maxAge = Duration(days: 7);
  static const _retryAfter = Duration(hours: 24);

  static Future<bool> _triedRecently(String slug) async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getInt('hardwax_try_$slug');
      return t != null &&
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t)) < _retryAfter;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _markTry(String slug) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('hardwax_try_$slug', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<List<Suggestion>?> _cached(String slug, {bool stale = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('hardwax_$slug');
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(m['t'] as int);
      if (!stale && DateTime.now().difference(at) > _maxAge) return null;
      return [
        for (final e in (m['items'] as List))
          Suggestion((e as List)[0] as String, e[1] as String, 0, 'Hardwax'),
      ];
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save(String slug, List<Suggestion> items) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        'hardwax_$slug',
        jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'items': [for (final s in items) [s.artist, s.title]],
        }),
      );
    } catch (_) {}
  }

  static List<Suggestion> _skip(List<Suggestion> l, Set<String> skip) => [
        for (final s in l)
          if (!skip.contains('${s.artist} ${s.title}'.toLowerCase())) s,
      ];

  /// Releases on a tag page, as artist and title, newest first as listed.
  static Future<List<Suggestion>> fetch(String slug, {Set<String> skip = const {}}) async {
    final fresh = await _cached(slug);
    if (fresh != null) {
      DebugLog.add('hardwax', '$slug: using the saved list (read within the last week) (${fresh.length})');
      return _skip(fresh, skip);
    }
    // A recent failed read: use the old list and leave the shop alone.
    if (await _triedRecently(slug)) {
      final old = await _cached(slug, stale: true);
      return _skip(old ?? const [], skip);
    }
    await _markTry(slug);
    http.Response r;
    try {
      r = await http.get(
        Uri.parse('https://hardwax.com/$slug/'),
        headers: const {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'},
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      final old = await _cached(slug, stale: true);
      if (old != null) return _skip(old, skip);
      rethrow;
    }
    if (r.statusCode != 200) {
      final old = await _cached(slug, stale: true);
      if (old != null) return _skip(old, skip);
      throw Exception('Hardwax answered ${r.statusCode}');
    }
    final text = _text(r.body);
    final items = WishParser.parse('€ Label Catalog MP3\n$text');
    final all = <Suggestion>[];
    for (final i in items) {
      if (i.artist.isEmpty) continue;
      all.add(Suggestion(i.artist, i.title, 0, 'Hardwax'));
    }
    final out = _skip(all, skip);
    if (all.isNotEmpty) await _save(slug, all);
    DebugLog.add('hardwax',
        '$slug: read the shop page (${r.body.length} bytes), ${items.length} parsed, ${all.length} usable'
        '${all.isEmpty ? ', text starts: ${text.replaceAll(RegExp(r'\\s+'), ' ').trim().substring(0, text.trim().length < 300 ? text.trim().length : 300)}' : ', first: ${all.first.artist} - ${all.first.title}'}');
    return out;
  }
}
