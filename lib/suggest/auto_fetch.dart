import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/soulseek/playable.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/storage_guard.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/wishlist/wishlist.dart';
import 'package:sidedeck/suggest/suggest_service.dart';

/// Fetches tracks that suit a seed track, one after another: look up what
/// goes with it, search Soulseek, take the best result, and when it has
/// finished move on to the next. Stops after [limit] downloads.
class AutoFetch extends ChangeNotifier {
  AutoFetch._();

  static final AutoFetch instance = AutoFetch._();

  final SuggestService _service = SuggestService();

  // What the AUTO switch uses. Set on the Auto-fetch page and remembered.
  String genre = 'house';
  double bpmMin = 120;
  double bpmMax = 128;
  int count = 5;
  bool endless = true;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      source = prefs.getString('af_source') ?? source;
      chartId = prefs.getInt('af_chart_id') ?? chartId;
      chartName = prefs.getString('af_chart_name') ?? chartName;
      chartTempo = prefs.getBool('af_chart_tempo') ?? chartTempo;
      pasted = prefs.getString('af_pasted') ?? pasted;
      genre = prefs.getString('af_genre') ?? genre;
      bpmMin = prefs.getDouble('af_bpm_min') ?? bpmMin;
      bpmMax = prefs.getDouble('af_bpm_max') ?? bpmMax;
      count = prefs.getInt('af_count') ?? count;
      similarYears = prefs.getBool('af_years') ?? similarYears;
      yearSpan = prefs.getInt('af_year_span') ?? yearSpan;
      buffer = prefs.getInt('af_buffer') ?? buffer;
      endless = prefs.getBool('af_endless') ?? endless;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('af_source', source);
      await prefs.setInt('af_chart_id', chartId);
      await prefs.setString('af_chart_name', chartName);
      await prefs.setBool('af_chart_tempo', chartTempo);
      await prefs.setString('af_pasted', pasted);
      await prefs.setString('af_genre', genre);
      await prefs.setDouble('af_bpm_min', bpmMin);
      await prefs.setDouble('af_bpm_max', bpmMax);
      await prefs.setInt('af_count', count);
      await prefs.setBool('af_years', similarYears);
      await prefs.setInt('af_year_span', yearSpan);
      await prefs.setInt('af_buffer', buffer);
      await prefs.setBool('af_endless', endless);
    } catch (_) {}
  }

  /// The AUTO switch: on starts fetching with the saved settings, off stops.
  void toggle(bool on, LibraryController library) {
    if (on && source == 'chart') {
      startChart(
        id: chartId,
        name: chartName,
        matchTempo: chartTempo,
        bpmMin: bpmMin,
        bpmMax: bpmMax,
        library: library,
        count: count,
        endless: endless,
      );
    } else if (on && source == 'list') {
      startList(text: pasted, library: library);
    } else if (on) {
      startByGenre(
        genre: genre,
        bpmMin: bpmMin,
        bpmMax: bpmMax,
        library: library,
        count: count,
        endless: endless,
      );
    } else {
      stop();
    }
  }

  bool running = false;
  String status = '';
  int fetched = 0;
  int limit = 5;
  final List<String> log = [];

  bool _stop = false;
  LibraryController? _lib;

  void _say(String s) {
    status = s;
    notifyListeners();
  }

  void stop() {
    _stop = true;
    _say('Stopping after the current step');
  }

  /// [seedBpm] and [seedKey] are used to keep only tracks that mix in.
  Future<void> start({
    required String artist,
    required String title,
    required double seedBpm,
    required CamelotKey? seedKey,
    required LibraryController library,
    required int count,
    double tempoRange = 8,
  }) async {
    if (running) return;
    if (!soulseek.online) {
      _say('Sign in to Soulseek first');
      return;
    }
    running = true;
    _lib = library;
    _stop = false;
    fetched = 0;
    limit = count;
    log.clear();
    var sArtist = artist;
    var sTitle = title;
    var bpm = seedBpm;
    final tried = <String>{};
    try {
      var empties = 0;
      while (!_stop && fetched < limit) {
        _say('Finding what goes with $sArtist - $sTitle');
        final info = await _service.lookupSeed(sArtist, sTitle);
        if (info.artistId == null) {
          _say('Could not look up $sArtist - $sTitle online');
          break;
        }
        if (bpm <= 0) bpm = info.deezerBpm;
        if (similarYears && info.year > 0) _refYear = info.year;
        final cands = await _service.candidates(info.artistId!, sArtist);
        final queue = cands
            .where((c) =>
                !tried.contains(c.query.toLowerCase()) &&
                !_inLibrary(library, c) &&
                _yearOk(c) &&
                (c.bpm == 0 || bpm <= 0 || bpmGapPercent(bpm, c.bpm).abs() <= tempoRange))
            .toList()
          ..sort((a, b) {
            double g(Suggestion s) =>
                s.bpm == 0 || bpm <= 0 ? 50 : bpmGapPercent(bpm, s.bpm).abs();
            return g(a).compareTo(g(b));
          });
        if (queue.isEmpty) {
          if (++empties >= 2) {
            _say('Nothing new that fits');
            break;
          }
          continue;
        }
        String? lastSaved;
        Suggestion? lastFor;
        for (final s in queue) {
          if (_stop || fetched >= limit) break;
          tried.add(s.query.toLowerCase());
          final saved = await _fetchOne(s, seedKey);
          if (saved != null) {
            fetched++;
            lastSaved = saved;
            lastFor = s;
            if (s.year > 0) _refYear = s.year;
            log.add('${s.artist} - ${s.title}');
            // Carry on from the track that just arrived.
            break;
          }
        }
        if (lastFor == null) {
          if (++empties >= 2) {
            _say('Could not find any of them on Soulseek');
            break;
          }
          continue;
        }
        empties = 0;
        final parsed = splitTitleArtist(lastSaved!.split(RegExp(r'[\\/]')).last
            .replaceFirst(RegExp(r'\.[^.]+$'), ''));
        sArtist = lastFor.artist;
        sTitle = lastFor.title;
        if (parsed.title.isEmpty) sTitle = lastFor.title;
        bpm = lastFor.bpm > 0 ? lastFor.bpm : bpm;
      }
      if (fetched >= limit) _say('Done: fetched $fetched');
      if (_stop) _say('Stopped after $fetched');
    } catch (e) {
      _say('Stopped: $e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Keep downloads to similar release years: within [yearSpan] years of the
  /// track before it (the first one is judged against what is on the decks).
  bool similarYears = false;
  int yearSpan = 5;
  int _refYear = 0;

  bool _yearOk(Suggestion s) {
    if (!similarYears) return true;
    if (s.year == 0) return false;
    if (_refYear == 0) return true;
    return (s.year - _refYear).abs() <= yearSpan;
  }

  /// Starting year: the year of the track playing (or loaded) on a deck.
  Future<void> _initRefYear() async {
    _refYear = 0;
    final dj = SlskSetup.dj;
    if (!similarYears || dj == null) return;
    for (var i = 0; i < 2; i++) {
      final d = dj.deck(i);
      if (d.loaded && (d.playing || i == 1 || !dj.deck(1).loaded)) {
        final info = await _service.lookupSeed(d.artist, d.title);
        if (info.year > 0) {
          _refYear = info.year;
          return;
        }
      }
    }
  }

  // Where the AUTO switch gets its tracks: 'genre', 'chart' or 'list'.
  String source = 'genre';
  int chartId = 113;
  String chartName = 'Dance';
  bool chartTempo = false;
  String pasted = '';

  /// Works through a ready-made list of tracks, or batches pulled from
  /// [more] until it returns nothing new.
  Future<void> _runSource({
    required String label,
    required Future<List<Suggestion>> Function(Set<String> tried) more,
    required LibraryController library,
    required int count,
    required bool endless,
    bool once = false,
    bool useYears = true,
  }) async {
    if (running) return;
    if (!soulseek.online) {
      _say('Sign in to Soulseek first');
      return;
    }
    running = true;
    _lib = library;
    _stop = false;
    fetched = 0;
    limit = endless ? 0 : count;
    log.clear();
    final tried = <String>{};
    var empties = 0;
    try {
      if (useYears) await _initRefYear();
      while (!_stop && (endless || fetched < limit)) {
        _say('Getting $label');
        final found = await more(tried);
        final queue = found
            .where((c) => !_inLibrary(library, c) && (!useYears || _yearOk(c)))
            .toList();
        for (final f in found) {
          tried.add(f.query.toLowerCase());
        }
        if (queue.isEmpty) {
          if (once || ++empties >= 3) {
            _say(once ? 'Reached the end of the list' : 'No more new tracks in $label');
            break;
          }
          continue;
        }
        var gotOne = false;
        for (final s in queue) {
          if (_stop || (!endless && fetched >= limit)) break;
          final saved = await _fetchOne(s, null);
          if (saved != null) {
            fetched++;
            gotOne = true;
            if (s.year > 0) _refYear = s.year;
            log.add('${s.artist} - ${s.title}');
          }
        }
        if (once) {
          _say('Finished the list: $fetched fetched');
          break;
        }
        empties = gotOne ? 0 : empties + 1;
        if (empties >= 3) {
          _say('Nothing more found on Soulseek');
          break;
        }
      }
      if (_stop) _say('Stopped after $fetched');
    } catch (e) {
      _say('Stopped: $e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> startChart({
    required int id,
    required String name,
    required bool matchTempo,
    required double bpmMin,
    required double bpmMax,
    required LibraryController library,
    required int count,
    required bool endless,
  }) {
    return _runSource(
      label: '$name chart',
      more: (tried) => _service.chart(
        id,
        name,
        bpmMin: matchTempo ? bpmMin : null,
        bpmMax: matchTempo ? bpmMax : null,
        skip: tried,
        needDetails: similarYears,
      ),
      library: library,
      count: count,
      endless: endless,
    );
  }

  Future<void> startList({
    required String text,
    required LibraryController library,
  }) {
    final cleaned = text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*\d+[.)]?\s+'), ''))
        .join('\n');
    final items = WishParser.parse(cleaned);
    final list = [
      for (final i in items) Suggestion(i.artist, i.title, 0, 'Your list'),
    ];
    var given = false;
    return _runSource(
      label: 'your list (${list.length} tracks)',
      more: (tried) async {
        if (given) return <Suggestion>[];
        given = true;
        return list;
      },
      library: library,
      count: list.length,
      endless: false,
      once: true,
      useYears: false,
    );
  }

  // Fetched this session, to know how many are waiting to be played.
  final List<String> _fetched = [];

  /// Stop fetching while this many tracks are already waiting to be played.
  int buffer = 3;

  int _waiting() {
    final dj = SlskSetup.dj;
    if (dj == null) return 0;
    if (dj.automixOn) return dj.automixWaiting;
    return _fetched
        .where((p) => !dj.loadedPaths.contains(p) && !dj.failedPaths.contains(p))
        .length;
  }

  /// Holds off while enough good tracks are queued up.
  Future<void> _waitForRoom() async {
    while (!_stop && _waiting() >= buffer) {
      _say('Paused: ${_waiting()} tracks waiting to be played');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  /// Picks by genre and tempo alone, no seed track. With [endless] it keeps
  /// going until stopped; otherwise it stops after [count] downloads.
  Future<void> startByGenre({
    required String genre,
    required double bpmMin,
    required double bpmMax,
    required LibraryController library,
    required int count,
    bool endless = false,
  }) async {
    if (running) return;
    if (!soulseek.online) {
      _say('Sign in to Soulseek first');
      return;
    }
    running = true;
    _lib = library;
    _stop = false;
    fetched = 0;
    limit = endless ? 0 : count;
    log.clear();
    final tried = <String>{};
    var empties = 0;
    try {
      await _initRefYear();
      while (!_stop && (endless || fetched < limit)) {
        _say('Looking for $genre at ${bpmMin.round()}-${bpmMax.round()} BPM');
        final found = await _service.byGenre(genre, bpmMin, bpmMax, skip: tried);
        final queue = found.where((c) => !_inLibrary(library, c) && _yearOk(c)).toList();
        if (queue.isEmpty) {
          if (++empties >= 3) {
            _say('Could not find more $genre in that tempo range');
            break;
          }
          continue;
        }
        var gotOne = false;
        for (final s in queue) {
          if (_stop || (!endless && fetched >= limit)) break;
          tried.add(s.query.toLowerCase());
          final saved = await _fetchOne(s, null);
          if (saved != null) {
            fetched++;
            gotOne = true;
            if (s.year > 0) _refYear = s.year;
            log.add('${s.artist} - ${s.title}  (${s.bpm.round()} BPM)');
          }
        }
        empties = gotOne ? 0 : empties + 1;
        if (empties >= 3) {
          _say('Nothing more found on Soulseek');
          break;
        }
      }
      if (_stop) {
        _say('Stopped after $fetched');
      } else if (!endless && fetched >= limit) {
        _say('Done: fetched $fetched');
      }
    } catch (e) {
      _say('Stopped: $e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  bool _inLibrary(LibraryController lib, Suggestion s) {
    final t = s.title.toLowerCase();
    return lib.tracks.any((x) => x.title.toLowerCase() == t);
  }

  /// Searches, picks the best match, waits until it has downloaded. Returns
  /// the saved path, or null when nothing usable turned up.
  Future<String?> _fetchOne(Suggestion s, CamelotKey? seedKey) async {
    final dir = SlskSetup.dj == null || _lib == null ? null : SlskSetup.dirFor(_lib!);
    if (dir != null) {
      final reason = await StorageGuard.blockReason(dir, 60 * 1024 * 1024);
      if (reason != null) {
        _stop = true;
        _say('Stopped. $reason');
        return null;
      }
    }
    await _waitForRoom();
    if (_stop) return null;
    _say('Searching for ${s.artist} - ${s.title}');
    soulseek.search(s.query);
    var waited = 0;
    await Future<void>.delayed(const Duration(seconds: 2));
    while (soulseek.searching && waited < 12 && !_stop) {
      await Future<void>.delayed(const Duration(seconds: 1));
      waited++;
    }
    final best = _pick(s, seedKey);
    if (best == null) {
      _say('No good match for ${s.title}, trying the next');
      return null;
    }
    soulseek.download(best);
    SlskDownload? dl;
    for (final d in soulseek.downloads) {
      if (d.user == best.user && d.remotePath == best.path) {
        dl = d;
        break;
      }
    }
    if (dl == null) return null;
    final started = DateTime.now();
    while (!_stop) {
      if (dl.state == DlState.done) {
        final sp = dl.savedPath;
        if (sp != null) _fetched.add(sp);
        return sp;
      }
      if (dl.state == DlState.failed) {
        _say('Download failed, trying the next');
        return null;
      }
      if (DateTime.now().difference(started).inMinutes >= 4) {
        soulseek.removeDownload(dl);
        _say('Too slow, trying the next');
        return null;
      }
      _say('Downloading ${best.fileName} ${(dl.progress * 100).round()}%');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    soulseek.removeDownload(dl);
    return null;
  }

  SlskResult? _pick(Suggestion s, CamelotKey? seedKey) {
    final words = RegExp(r'[a-z0-9]{3,}')
        .allMatches(s.title.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    final aWords = RegExp(r'[a-z0-9]{3,}')
        .allMatches(s.artist.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    SlskResult? best;
    var bestScore = -1;
    for (final r in soulseek.results) {
      if (!slskPlayable(r)) continue;
      final hay = '${r.folder} ${r.fileName}'.toLowerCase();
      if (words.isNotEmpty && !words.every(hay.contains)) continue;
      if (aWords.isNotEmpty && !aWords.any(hay.contains)) continue;
      var score = 0;
      if (r.freeSlot) score += 6;
      if (r.bitrate >= 320 || r.ext == 'flac') {
        score += 4;
      } else if (r.bitrate >= 192) {
        score += 2;
      }
      if (r.size > 2500000 && r.size < 60000000) score += 1;
      if (RegExp(r'\b(live|karaoke|cover|snippet|preview)\b').hasMatch(hay)) score -= 5;
      final hint = parseNameHints(hay);
      if (seedKey != null && hint.key != null && keyMatch(seedKey, hint.key!).score > 0) {
        score += 3;
      }
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    return best;
  }
}
