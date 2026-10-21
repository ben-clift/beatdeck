import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/suggest_service.dart';

/// Reads the public Top 100 page of every Traxsource genre (names, genre and
/// tempo only: no audio, no previews, no downloads from the store). Traxsource
/// updates its charts weekly, so the whole library is read once a week and
/// kept on the phone; in between the saved copy is used. After a failed read
/// nothing is tried again for a day.
class Traxsource {
  static const _maxAge = Duration(days: 7);
  static const _tryKey = 'traxsource_try';
  static const _key = 'traxsource_all_v1';
  static const _base = 'https://www.traxsource.com';
  static const _headers = {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'};

  static List<Suggestion>? _memory;
  static Future<List<Suggestion>>? _running;

  static String _clean(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

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
          Suggestion((e as List)[0] as String, e[1] as String, (e[2] as num).toDouble(),
              e[3] as String)
            ..label = e.length > 4 ? e[4] as String : '',
      ];
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save(List<Suggestion> items) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key,
        jsonEncode({
          't': DateTime.now().millisecondsSinceEpoch,
          'items': [
            for (final s in items) [s.artist, s.title, s.bpm, s.reason, s.label],
          ],
        }),
      );
    } catch (_) {}
  }

  /// Track rows on one chart page.
  static List<Suggestion> parse(String html, String fallbackGenre) {
    final out = <Suggestion>[];
    final parts = html.split(RegExp(r'class="[^"]*\btrk-row\b'));
    for (final part in parts.skip(1)) {
      final t = RegExp(r'<a[^>]*href="/track/\d+[^"]*"[^>]*>([\s\S]*?)</a>').firstMatch(part);
      if (t == null) continue;
      var title = t.group(1)!;
      final ver = title.indexOf(RegExp(r'<span', caseSensitive: false));
      if (ver > 0) title = title.substring(0, ver);
      title = _clean(title);
      final cell = RegExp(r'trk-cell artists[^>]*>([\s\S]*?)</div>').firstMatch(part);
      final scope = cell?.group(1) ?? part;
      final a = RegExp(r'<a[^>]*href="/artist/\d+[^"]*"[^>]*>([\s\S]*?)</a>')
          .allMatches(scope)
          .map((m) => _clean(m.group(1)!))
          .where((x) => x.isNotEmpty)
          .toList();
      if (title.isEmpty || a.isEmpty) continue;
      var bpm = 0.0;
      final kb = RegExp(r'trk-cell key-bpm[^>]*>([\s\S]*?)</div>').firstMatch(part);
      if (kb != null) {
        final n = RegExp(r'(\d{2,3})\s*$').firstMatch(_clean(kb.group(1)!));
        if (n != null) bpm = double.parse(n.group(1)!);
      }
      var genre = fallbackGenre;
      final g = RegExp(r'href="/genre/\d+/([a-z0-9-]+)').firstMatch(part);
      if (g != null) genre = g.group(1)!.replaceAll('-', ' ');
      var label = '';
      final lm = RegExp(r'<a[^>]*href="/label/\d+[^"]*"[^>]*>([\s\S]*?)</a>').firstMatch(part);
      if (lm != null) label = _clean(lm.group(1)!);
      out.add(Suggestion(a.take(2).join(', '), title, bpm, genre)..label = label);
    }
    return out;
  }

  /// Every genre's Top 100, from the saved copy when it is under a day old.
  static Future<List<Suggestion>> all() {
    if (_memory != null && _running == null) {
      // The saved copy may have aged since it was loaded.
    }
    return _running ??= _load().whenComplete(() => _running = null);
  }

  static Future<List<Suggestion>> _load() async {
    final fresh = await _cached();
    if (fresh != null && fresh.isNotEmpty) {
      DebugLog.add('traxsource', 'using the saved library (read within the last week) (${fresh.length} tracks)');
      return _memory = fresh;
    }
    // A recent failed read: use the old copy and leave the site alone.
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getInt(_tryKey);
      if (t != null &&
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t)) <
              const Duration(hours: 24)) {
        final old = await _cached(stale: true);
        if (old != null) return _memory = old;
        throw Exception('read failed recently, waiting a day before trying again');
      }
      await p.setInt(_tryKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      if (e is Exception && '$e'.contains('waiting a day')) rethrow;
    }
    try {
      // Genre pages are found from the all-genres chart page.
      final top = await http
          .get(Uri.parse('$_base/top'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (top.statusCode != 200) throw Exception('Traxsource answered ${top.statusCode}');
      final genres = <String, String>{}; // id -> slug
      for (final m in RegExp(r'href="/genre/(\d+)/([a-z0-9-]+)').allMatches(top.body)) {
        genres[m.group(1)!] = m.group(2)!;
      }
      final all = <Suggestion>[];
      final seen = <String>{};
      void add(List<Suggestion> l) {
        for (final s in l) {
          if (seen.add('${s.artist} ${s.title}'.toLowerCase())) all.add(s);
        }
      }

      add(parse(top.body, ''));
      DebugLog.add('traxsource',
          'top page ${top.body.length} bytes, ${genres.length} genres found, ${all.length} tracks');
      for (final e in genres.entries) {
        try {
          final r = await http
              .get(Uri.parse('$_base/genre/${e.key}/${e.value}/top'), headers: _headers)
              .timeout(const Duration(seconds: 20));
          if (r.statusCode == 200) add(parse(r.body, e.value.replaceAll('-', ' ')));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      if (all.isEmpty) {
        final sample = _clean(top.body);
        DebugLog.add('traxsource',
            'no tracks parsed; text starts: ${sample.substring(0, sample.length < 300 ? sample.length : 300)}');
        throw Exception('no tracks found on the page');
      }
      await _save(all);
      DebugLog.add('traxsource', 'read the whole library: ${all.length} tracks, first: ${all.first.artist} - ${all.first.title}');
      return _memory = all;
    } catch (e) {
      final old = await _cached(stale: true);
      if (old != null) return _memory = old;
      DebugLog.add('traxsource', 'could not read Traxsource: $e');
      rethrow;
    }
  }

  /// Tracks of the same or a similar genre family and tempo. Tracks without
  /// a tempo are left out when a tempo range is given.
  static Future<List<Suggestion>> matching(String genre, {double? bpmMin, double? bpmMax}) async {
    final list = await all();
    return [
      for (final s in list)
        if ((genre.isEmpty || genresSimilar(genre, s.reason)) &&
            (bpmMin == null || bpmMax == null || (s.bpm >= bpmMin && s.bpm <= bpmMax)))
          s,
    ];
  }
}
