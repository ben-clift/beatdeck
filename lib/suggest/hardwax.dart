import 'package:http/http.dart' as http;
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

  /// Releases on a tag page, as artist and title, newest first as listed.
  static Future<List<Suggestion>> fetch(String slug, {Set<String> skip = const {}}) async {
    final r = await http.get(
      Uri.parse('https://hardwax.com/$slug/'),
      headers: const {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'},
    ).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('Hardwax answered ${r.statusCode}');
    final items = WishParser.parse('€ Label Catalog MP3\n${_text(r.body)}');
    final out = <Suggestion>[];
    for (final i in items) {
      if (i.artist.isEmpty) continue;
      if (skip.contains('${i.artist} ${i.title}'.toLowerCase())) continue;
      out.add(Suggestion(i.artist, i.title, 0, 'Hardwax'));
    }
    return out;
  }
}
