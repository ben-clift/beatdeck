import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/suggest/suggest_service.dart';

/// Reads artist and track names from NME's public track-review pages and
/// feeds, for band genres (rock, indie, punk, goth and so on). Names only: no
/// audio or downloads from NME. Each page is read at most once a day and the
/// saved list is used in between.
class Nme {
  static const _pages = <String>[
    'https://www.nme.com/reviews/track-reviews/feed',
    'https://www.nme.com/reviews/track-reviews',
    'https://www.nme.com/feed',
  ];
  static const _maxAge = Duration(hours: 24);
  static const _key = 'nme_list_v1';
  static const _keyAt = 'nme_list_at_v1';

  static String _clean(String s) => s
      .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&#8216;', '‘')
      .replaceAll('&#8217;', '’')
      .replaceAll('&#8220;', '“')
      .replaceAll('&#8221;', '”')
      .replaceAll('&#8211;', '–')
      .replaceAll('&#8212;', '—')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // NME headlines look like:  Artist – ‘Title’   Artist: ‘Title’ review
  //                           Artist share new single ‘Title’
  static final _dash = RegExp(r'^(.{2,60}?)\s+[–—-]\s+[‘’\x27“"](.{2,80}?)[’‘\x27”"](?:\s|$|:|,|\.)');
  static final _colon = RegExp(r'^(.{2,60}?):\s+[‘’\x27“"](.{2,80}?)[’‘\x27”"](?:\s|$|:|,|\.)');
  static final _single = RegExp(
      r'^(.{2,50}?)\s+(?:share|shares|release|releases|unveil|unveils|return|returns|drop|drops|announce|announces|debut|debuts|cover|covers|tease|teases)\b.*?(?:single|track|song)\s+[‘’\x27“"](.{2,80}?)[’‘\x27”"]');

  static Suggestion? _parse(String t) {
    for (final re in [_dash, _colon, _single]) {
      final m = re.firstMatch(t);
      if (m == null) continue;
      final artist = m.group(1)!.trim();
      final title = m.group(2)!.trim();
      if (artist.isEmpty || title.isEmpty) continue;
      if (RegExp(r'\b(review|best|ranked|every|interview|gallery|live)\b', caseSensitive: false).hasMatch(artist)) continue;
      return Suggestion(artist, title, 0, 'NME');
    }
    return null;
  }

  static Future<List<Suggestion>> _saved({bool stale = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final at = p.getInt(_keyAt) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      if (!stale && age > _maxAge.inMilliseconds) return const [];
      return [
        for (final e in p.getStringList(_key) ?? const <String>[])
          if (e.contains('\u0001'))
            Suggestion(e.split('\u0001').first, e.split('\u0001').last, 0, 'NME'),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Suggestion>> fetch() async {
    final fresh = await _saved();
    if (fresh.isNotEmpty) {
      DebugLog.add('nme', 'using the saved list read today (${fresh.length})');
      return fresh;
    }
    final out = <Suggestion>[];
    final seen = <String>{};
    for (final url in _pages) {
      try {
        final r = await http
            .get(Uri.parse(url), headers: const {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'})
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          DebugLog.add('nme', '$url answered ${r.statusCode}');
          continue;
        }
        // Headlines: feed <title> tags, page headings and links.
        final texts = <String>[
          for (final m in RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).allMatches(r.body)) m.group(1)!,
          for (final m in RegExp(r'<(?:h[1-4]|a)\b[^>]*>([\s\S]{3,200}?)</(?:h[1-4]|a)>', caseSensitive: false).allMatches(r.body)) m.group(1)!,
          for (final m in RegExp(r'"(?:title|headline)"\s*:\s*"((?:[^"\\]|\\.){3,200})"').allMatches(r.body))
            m.group(1)!.replaceAll(r'\"', '"').replaceAll(r"‘", '‘').replaceAll(r"’", '’').replaceAll(r"–", '–'),
        ];
        var n = 0;
        for (final raw in texts) {
          final s = _parse(_clean(raw));
          if (s == null) continue;
          if (seen.add('${s.artist} ${s.title}'.toLowerCase())) {
            out.add(s);
            n++;
          }
        }
        DebugLog.add('nme', '$url: ${r.body.length} bytes, $n tracks found'
            '${n > 0 ? ', first: ${out.first.artist} - ${out.first.title}' : ''}');
      } catch (e) {
        DebugLog.add('nme', '$url not available: $e');
      }
      if (out.length >= 30) break;
    }
    if (out.isEmpty) return _saved(stale: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_key, [for (final s in out) '${s.artist}\u0001${s.title}']);
      await p.setInt(_keyAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    return out;
  }
}
