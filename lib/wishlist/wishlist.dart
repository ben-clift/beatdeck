import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sidedeck/debug/debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One song on a wish list: names only, no audio.
class WishItem {
  WishItem(this.artist, this.title, {this.done = false});

  final String artist;
  final String title;
  bool done;

  String get query => '$artist $title'.trim();

  Map<String, dynamic> toJson() => {'a': artist, 't': title, 'd': done};

  static WishItem? fromJson(Object? raw) {
    if (raw is! Map || raw['t'] is! String) return null;
    return WishItem(
      raw['a'] is String ? raw['a'] as String : '',
      raw['t'] as String,
      done: raw['d'] == true,
    );
  }
}

class WishList {
  WishList(this.id, this.name, this.source, [List<WishItem>? items])
      : items = items ?? <WishItem>[];

  final String id;
  String name;
  final String source;
  final List<WishItem> items;

  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        's': source,
        'i': [for (final i in items) i.toJson()],
      };

  static WishList? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['n'] is! String) return null;
    final items = <WishItem>[];
    if (raw['i'] is List) {
      for (final j in raw['i'] as List) {
        final it = WishItem.fromJson(j);
        if (it != null) items.add(it);
      }
    }
    return WishList(
      raw['id'] as String,
      raw['n'] as String,
      raw['s'] is String ? raw['s'] as String : '',
      items,
    );
  }
}

/// Parsing of song lists from text, plain Dart so it can be tested.
class WishParser {
  /// Accepts "Artist - Title" lines, or a CSV export (for example from
  /// Exportify) with Track Name and Artist columns.
  static List<WishItem> parse(String text) {
    final lines = const LineSplitter().convert(text.trim());
    if (lines.isEmpty) return [];
    final header = _csvRow(lines.first).map((s) => s.toLowerCase()).toList();
    final ti = header.indexWhere((h) => h.contains('track name') || h == 'title' || h == 'name' || h == 'song');
    final ai = header.indexWhere((h) => h.contains('artist'));
    final out = <WishItem>[];
    if (ti >= 0 && ai >= 0 && header.length > 1) {
      for (final line in lines.skip(1)) {
        final row = _csvRow(line);
        if (row.length <= ti || row.length <= ai) continue;
        final artist = row[ai].split(RegExp(r'[;,]')).first.trim();
        final title = row[ti].trim();
        if (title.isNotEmpty) out.add(WishItem(artist, title));
      }
      return out;
    }
    // Text copied from a record shop page (Hardwax and similar): releases
    // read "Artist: Title" and the rest is catalogue numbers, prices and
    // descriptions, so only those lines are kept.
    final shop = text.contains('€') || text.contains('Label Catalog') || text.contains('MP3');
    if (shop) {
      final seen = <String>{};
      for (final raw in lines) {
        final m = RegExp(r'^([^:\n]{2,50}):\s+(.{1,80})$').firstMatch(raw.trim());
        if (m == null) continue;
        final artist = m.group(1)!.trim();
        final title = m.group(2)!.trim();
        if (title.split(' ').length > 9) continue; // a description, not a title
        if (seen.add('$artist $title'.toLowerCase())) out.add(WishItem(artist, title));
      }
      if (out.isNotEmpty) return out;
    }
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(line);
      if (m != null) {
        out.add(WishItem(m.group(1)!.trim(), m.group(2)!.trim()));
      } else {
        out.add(WishItem('', line));
      }
    }
    return out;
  }

  static List<String> _csvRow(String line) {
    final out = <String>[];
    final b = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (ch == ',' && !quoted) {
        out.add(b.toString());
        b.clear();
      } else {
        b.write(ch);
      }
    }
    out.add(b.toString());
    return out;
  }
}

class WishListController extends ChangeNotifier {
  WishListController() {
    _load();
  }

  static const _key = 'wish_lists_v1';
  final List<WishList> lists = [];
  String? message;
  bool busy = false;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final l = WishList.fromJson(j);
          if (l != null) lists.add(l);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode([for (final l in lists) l.toJson()]),
      );
    } catch (_) {}
    notifyListeners();
  }

  WishList add(String name, String source, List<WishItem> items) {
    final l = WishList(
      DateTime.now().microsecondsSinceEpoch.toString(),
      name,
      source,
      items,
    );
    lists.insert(0, l);
    save();
    return l;
  }

  void remove(WishList l) {
    lists.remove(l);
    save();
  }

  void toggleDone(WishItem i) {
    i.done = !i.done;
    save();
  }

  Future<bool> importText(String name, String text, {String source = 'Pasted'}) async {
    final items = WishParser.parse(text);
    if (items.isEmpty) {
      message = 'No songs found. Use one "Artist - Title" per line.';
      notifyListeners();
      return false;
    }
    add(name.isEmpty ? 'Imported list' : name, source, items);
    message = null;
    return true;
  }

  /// Any public Spotify or Beatport playlist / chart / album link, no keys:
  /// the page's own embedded data is read for the song names.
  Future<bool> importLink(String link) async {
    final l = link.trim();
    final isSp = l.contains('spotify.com') || l.startsWith('spotify:');
    final isBp = l.contains('beatport.com');
    if (!isSp && !isBp) {
      message = 'Paste a Spotify or Beatport link (playlist, album or chart).';
      notifyListeners();
      return false;
    }
    busy = true;
    message = null;
    notifyListeners();
    try {
      var url = l;
      String source = 'Beatport';
      if (isSp) {
        source = 'Spotify';
        final m = RegExp(r'(playlist|album|track)[/:]([A-Za-z0-9]+)').firstMatch(l);
        if (m == null) {
          message = 'That Spotify link has no playlist or album in it.';
          return false;
        }
        url = 'https://open.spotify.com/embed/${m.group(1)}/${m.group(2)}';
      }
      final res = await http.get(Uri.parse(url), headers: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
        'Accept-Language': 'en-GB,en;q=0.9',
      }).timeout(const Duration(seconds: 25));
      final items = parseEmbedded(res.body);
      final title = RegExp(r'<title>([^<]+)</title>').firstMatch(res.body)?.group(1);
      if (items.isEmpty) {
        message = 'Could not read songs from that page (it may be private, or the site changed).';
        DebugLog.add('wishlist', 'link import found nothing: HTTP ${res.statusCode}, ${res.body.length} bytes');
        return false;
      }
      var name = (title ?? '$source list')
          .replaceAll(RegExp(r'\s*[|\-–]\s*(Spotify|Beatport).*$'), '')
          .replaceAll('&amp;', '&')
          .trim();
      if (name.isEmpty) name = '$source list';
      add(name, source, items);
      DebugLog.add('wishlist', 'imported ${items.length} songs from $source: $name');
      return true;
    } catch (e) {
      message = 'Could not reach that link.';
      DebugLog.add('wishlist', 'link import failed: $e');
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Finds track-like objects anywhere in the JSON blobs of a web page.
  static List<WishItem> parseEmbedded(String html) {
    final out = <WishItem>[];
    final seen = <String>{};
    void add(String artist, String title) {
      title = title.trim();
      artist = artist.trim();
      if (title.isEmpty) return;
      if (seen.add('${artist.toLowerCase()}|${title.toLowerCase()}')) out.add(WishItem(artist, title));
    }

    void walk(dynamic n) {
      if (n is List) {
        for (final e in n) {
          walk(e);
        }
      } else if (n is Map) {
        final uri = n['uri']?.toString() ?? '';
        final sub = n['subtitle'];
        final ttl = n['title'];
        final name = n['name'];
        final artists = n['artists'];
        if (ttl is String && sub is String && (uri.startsWith('spotify:track') || n.containsKey('isPlayable'))) {
          add(sub.replaceAll('\u00a0', ' '), ttl);
        } else if (name is String && artists is List && artists.isNotEmpty && artists.first is Map &&
            (artists.first as Map)['name'] is String &&
            (n.containsKey('mix_name') || n.containsKey('bpm') || n.containsKey('duration_ms') ||
                n.containsKey('track_number') || uri.startsWith('spotify:track') || n.containsKey('length_ms'))) {
          final a = [for (final x in artists) if (x is Map && x['name'] is String) x['name']].join(', ');
          final mix = n['mix_name']?.toString() ?? '';
          add(a, mix.isEmpty || mix.toLowerCase() == 'original mix' ? name : '$name ($mix)');
        }
        for (final v in n.values) {
          walk(v);
        }
      }
    }

    for (final m in RegExp(r'<script[^>]*type="application/(?:ld\+)?json"[^>]*>(.*?)</script>', dotAll: true).allMatches(html)) {
      try {
        walk(jsonDecode(m.group(1)!));
      } catch (_) {}
    }
    for (final m in RegExp(r'<script[^>]*id="(?:__NEXT_DATA__|resource)"[^>]*>(.*?)</script>', dotAll: true).allMatches(html)) {
      try {
        var raw = m.group(1)!;
        if (!raw.trimLeft().startsWith('{')) raw = utf8.decode(base64.decode(raw.trim()), allowMalformed: true);
        walk(jsonDecode(raw));
      } catch (_) {}
    }
    return out;
  }

  /// Public Deezer playlist link. Deezer shares playlist details without a key.
  Future<bool> importDeezer(String link) async {
    final m = RegExp(r'playlist/(\d+)').firstMatch(link);
    if (m == null) {
      message = 'Paste the full Deezer playlist link (it contains /playlist/ and a number).';
      notifyListeners();
      return false;
    }
    busy = true;
    message = null;
    notifyListeners();
    try {
      final id = m.group(1)!;
      final head = await http
          .get(Uri.parse('https://api.deezer.com/playlist/$id'))
          .timeout(const Duration(seconds: 20));
      final info = jsonDecode(head.body) as Map<String, dynamic>;
      if (info['error'] != null) {
        message = 'Deezer would not share that playlist (it may be private).';
        return false;
      }
      final items = <WishItem>[];
      String? next = 'https://api.deezer.com/playlist/$id/tracks?limit=100';
      var guard = 0;
      while (next != null && guard++ < 30) {
        final res = await http.get(Uri.parse(next)).timeout(const Duration(seconds: 20));
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        for (final t in (data['data'] as List? ?? [])) {
          final tm = t as Map<String, dynamic>;
          final artist = (tm['artist'] as Map?)?['name'] as String? ?? '';
          final title = tm['title'] as String? ?? '';
          if (title.isNotEmpty) items.add(WishItem(artist, title));
        }
        next = data['next'] as String?;
      }
      if (items.isEmpty) {
        message = 'That playlist had no songs.';
        return false;
      }
      add(info['title'] as String? ?? 'Deezer playlist', 'Deezer', items);
      return true;
    } catch (_) {
      message = 'Could not reach Deezer.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Spotify playlist using your own free developer app (client id and
  /// secret). Reads names only.
  Future<bool> importSpotify(String link, String clientId, String secret) async {
    final m = RegExp(r'playlist/([A-Za-z0-9]+)').firstMatch(link);
    if (m == null || clientId.isEmpty || secret.isEmpty) {
      message = 'Needs a Spotify playlist link, plus your app\'s client id and secret.';
      notifyListeners();
      return false;
    }
    busy = true;
    message = null;
    notifyListeners();
    try {
      final basic = base64.encode(utf8.encode('$clientId:$secret'));
      final tok = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Authorization': 'Basic $basic'},
        body: {'grant_type': 'client_credentials'},
      ).timeout(const Duration(seconds: 20));
      final token = (jsonDecode(tok.body) as Map)['access_token'] as String?;
      if (token == null) {
        message = 'Spotify refused the client id or secret.';
        return false;
      }
      final id = m.group(1)!;
      final items = <WishItem>[];
      String? next = 'https://api.spotify.com/v1/playlists/$id/tracks?limit=100';
      var guard = 0;
      while (next != null && guard++ < 30) {
        final res = await http.get(
          Uri.parse(next),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          message = 'Spotify would not share that playlist (${res.statusCode}). '
              'Try exporting it to a file and importing that instead.';
          return false;
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        for (final it in (data['items'] as List? ?? [])) {
          final tr = (it as Map)['track'] as Map?;
          if (tr == null) continue;
          final artists = tr['artists'] as List? ?? [];
          final artist = artists.isEmpty ? '' : (artists.first as Map)['name'] as String? ?? '';
          final title = tr['name'] as String? ?? '';
          if (title.isNotEmpty) items.add(WishItem(artist, title));
        }
        next = data['next'] as String?;
      }
      if (items.isEmpty) {
        message = 'That playlist had no songs.';
        return false;
      }
      add('Spotify playlist', 'Spotify', items);
      return true;
    } catch (_) {
      message = 'Could not reach Spotify.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
