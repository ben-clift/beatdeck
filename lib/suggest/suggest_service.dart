import 'dart:convert';

import 'package:http/http.dart' as http;

/// A track the network suggests. Names and tempo only, no audio.
class Suggestion {
  Suggestion(this.artist, this.title, this.bpm, this.reason);

  final String artist;
  final String title;

  /// 0 when Deezer has no tempo for it.
  final double bpm;
  final String reason;

  String get query => '$artist $title'.trim();
}

/// What is known about the seed track from the internet.
class SeedInfo {
  SeedInfo({
    this.genres = const [],
    this.deezerBpm = 0,
    this.artistId,
    this.error,
  });

  final List<String> genres;
  final double deezerBpm;
  final int? artistId;
  final String? error;
}

/// Looks things up on Deezer's public API and MusicBrainz. Neither needs a
/// key. Both are only used for names, genres and tempo.
class SuggestService {
  static const _ua = {'User-Agent': 'BeatDeck/1.0 (personal DJ app)'};

  Future<dynamic> _get(String url) async {
    final r = await http
        .get(Uri.parse(url), headers: _ua)
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<SeedInfo> lookupSeed(String artist, String title) async {
    final genres = <String>{};
    double bpm = 0;
    int? artistId;
    try {
      final q = Uri.encodeQueryComponent(
        artist.isEmpty ? title : 'artist:"$artist" track:"$title"',
      );
      final s = await _get('https://api.deezer.com/search?q=$q&limit=1');
      final data = (s['data'] as List?) ?? const [];
      if (data.isNotEmpty) {
        final t = data.first as Map;
        artistId = (t['artist'] as Map?)?['id'] as int?;
        final tr = await _get('https://api.deezer.com/track/${t['id']}');
        bpm = ((tr['bpm'] as num?) ?? 0).toDouble();
        final albumId = (tr['album'] as Map?)?['id'];
        if (albumId != null) {
          final al = await _get('https://api.deezer.com/album/$albumId');
          for (final g in ((al['genres']?['data'] as List?) ?? const [])) {
            final n = (g as Map)['name'];
            if (n is String) genres.add(n);
          }
        }
      }
    } catch (_) {}
    try {
      final q = Uri.encodeQueryComponent(
        artist.isEmpty ? 'recording:"$title"' : 'artist:"$artist" AND recording:"$title"',
      );
      final mb = await _get(
        'https://musicbrainz.org/ws/2/recording/?query=$q&fmt=json&limit=1',
      );
      final recs = (mb['recordings'] as List?) ?? const [];
      if (recs.isNotEmpty) {
        final tags = ((recs.first as Map)['tags'] as List?) ?? const [];
        final sorted = [...tags]
          ..sort((a, b) => ((b as Map)['count'] ?? 0).compareTo((a as Map)['count'] ?? 0));
        for (final t in sorted.take(4)) {
          final n = (t as Map)['name'];
          if (n is String) genres.add(n);
        }
      }
    } catch (_) {}
    return SeedInfo(
      genres: genres.toList(),
      deezerBpm: bpm,
      artistId: artistId,
      error: (artistId == null && genres.isEmpty)
          ? 'Could not find this track online'
          : null,
    );
  }

  /// Tracks for a genre inside a tempo range: Deezer playlists matching the
  /// genre name, then each track's tempo checked. [skip] hides names already
  /// tried. Returns at most [want] tracks.
  Future<List<Suggestion>> byGenre(
    String genre,
    double bpmMin,
    double bpmMax, {
    Set<String> skip = const {},
    int want = 12,
  }) async {
    final out = <Suggestion>[];
    final raw = <(int, String, String)>[];
    try {
      final q = Uri.encodeQueryComponent(genre);
      final pl = await _get('https://api.deezer.com/search/playlist?q=$q&limit=12');
      final lists = [...((pl['data'] as List?) ?? const [])]..shuffle();
      for (final l in lists.take(3)) {
        final id = (l as Map)['id'];
        try {
          final tr = await _get('https://api.deezer.com/playlist/$id/tracks?limit=60');
          for (final t in ((tr['data'] as List?) ?? const [])) {
            final m = t as Map;
            final artist = ((m['artist'] as Map?)?['name'] ?? '') as String;
            final title = (m['title'] ?? '') as String;
            if (skip.contains('$artist $title'.toLowerCase())) continue;
            raw.add((m['id'] as int, title, artist));
          }
        } catch (_) {}
      }
    } catch (_) {}
    raw.shuffle();
    final seen = <int>{};
    final todo = raw.where((r) => seen.add(r.$1)).take(90).toList();
    for (var i = 0; i < todo.length && out.length < want; i += 6) {
      final got = await Future.wait(todo.skip(i).take(6).map((r) async {
        double bpm = 0;
        try {
          final tr = await _get('https://api.deezer.com/track/${r.$1}');
          bpm = ((tr['bpm'] as num?) ?? 0).toDouble();
        } catch (_) {}
        return Suggestion(r.$3, r.$2, bpm, genre);
      }));
      for (final s in got) {
        if (s.bpm >= bpmMin && s.bpm <= bpmMax) out.add(s);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return out;
  }

  /// Deezer's genres, as (id, name), for the chart picker.
  Future<List<(int, String)>> genres() async {
    try {
      final g = await _get('https://api.deezer.com/genre');
      return [
        for (final e in ((g['data'] as List?) ?? const []))
          if ((e as Map)['id'] != 0) ((e['id'] as num).toInt(), (e['name'] ?? '') as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Most-played tracks of a Deezer genre, in chart order. With [bpmMin] and
  /// [bpmMax] set, only those in the tempo range are kept (each tempo is
  /// looked up, so it is slower).
  Future<List<Suggestion>> chart(
    int genreId,
    String genreName, {
    double? bpmMin,
    double? bpmMax,
    Set<String> skip = const {},
    int want = 12,
  }) async {
    final raw = <(int, String, String)>[];
    try {
      final c = await _get('https://api.deezer.com/chart/$genreId/tracks?limit=100');
      for (final t in ((c['data'] as List?) ?? const [])) {
        final m = t as Map;
        final artist = ((m['artist'] as Map?)?['name'] ?? '') as String;
        final title = (m['title'] ?? '') as String;
        if (skip.contains('$artist $title'.toLowerCase())) continue;
        raw.add((m['id'] as int, title, artist));
      }
    } catch (_) {}
    final out = <Suggestion>[];
    if (bpmMin == null || bpmMax == null) {
      for (final r in raw.take(want)) {
        out.add(Suggestion(r.$3, r.$2, 0, '$genreName chart'));
      }
      return out;
    }
    for (var i = 0; i < raw.length && out.length < want; i += 6) {
      final got = await Future.wait(raw.skip(i).take(6).map((r) async {
        double bpm = 0;
        try {
          final tr = await _get('https://api.deezer.com/track/${r.$1}');
          bpm = ((tr['bpm'] as num?) ?? 0).toDouble();
        } catch (_) {}
        return Suggestion(r.$3, r.$2, bpm, '$genreName chart');
      }));
      for (final s in got) {
        if (s.bpm >= bpmMin && s.bpm <= bpmMax) out.add(s);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return out;
  }

  /// Top tracks from the seed artist and from artists listeners pair with it,
  /// each with its tempo so the list can be filtered.
  Future<List<Suggestion>> candidates(int artistId, String seedArtist) async {
    final out = <Suggestion>[];
    final ids = <int, String>{artistId: seedArtist};
    try {
      final rel = await _get('https://api.deezer.com/artist/$artistId/related?limit=6');
      for (final a in ((rel['data'] as List?) ?? const [])) {
        final m = a as Map;
        ids[m['id'] as int] = (m['name'] ?? '') as String;
      }
    } catch (_) {}
    final raw = <(int, String, String, String)>[];
    for (final e in ids.entries) {
      try {
        final top = await _get('https://api.deezer.com/artist/${e.key}/top?limit=6');
        for (final t in ((top['data'] as List?) ?? const [])) {
          final m = t as Map;
          raw.add((
            m['id'] as int,
            (m['title'] ?? '') as String,
            e.value,
            e.key == artistId ? 'Same artist' : 'Related to $seedArtist',
          ));
        }
      } catch (_) {}
    }
    // Tempo needs one call per track; keep each batch small for the rate limit.
    for (var i = 0; i < raw.length; i += 6) {
      final batch = raw.skip(i).take(6);
      final got = await Future.wait(batch.map((r) async {
        double bpm = 0;
        try {
          final tr = await _get('https://api.deezer.com/track/${r.$1}');
          bpm = ((tr['bpm'] as num?) ?? 0).toDouble();
        } catch (_) {}
        return Suggestion(r.$3, r.$2, bpm, r.$4);
      }));
      out.addAll(got);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return out;
  }
}
