import 'dart:math' as math;
import 'package:sidedeck/debug/debug_log.dart';
import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/soulseek/playable.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/storage_guard.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/suggest/hardwax.dart';
import 'package:sidedeck/engine/audio_check.dart';
import 'package:sidedeck/suggest/ra.dart';
import 'package:sidedeck/suggest/taste.dart';
import 'package:sidedeck/suggest/traxsource.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/wishlist/wishlist.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/suggest/discover.dart';

/// Fetches tracks that suit a seed track, one after another: look up what
/// goes with it, search Soulseek, take the best result, and when it has
/// finished move on to the next. Stops after [limit] downloads.
class AutoFetch extends ChangeNotifier {
  AutoFetch._();

  static final AutoFetch instance = AutoFetch._();

  final SuggestService _service = SuggestService();

  // What the AUTO switch uses. Set on the Auto-fetch page and remembered.
  String genre = 'house';

  /// Every genre you ticked. When [pinned], each search uses one of them
  /// (not the genre of the playing track) and the result is mixed in at once.
  List<String> genres = [];
  bool pinned = false;
  final _rnd = math.Random();
  String pickGenre() => (pinned && genres.isNotEmpty) ? genres[_rnd.nextInt(genres.length)] : genre;
  double bpmMin = 120;
  double bpmMax = 128;
  int count = 5;
  bool endless = true;

  /// Hardwax is the default source for the AUTO switch. [hwTag] is a tag
  /// page slug, or empty for the whole shop (every tag in turn).
  bool hardwax = true;

  /// Shops the AUTO switch and automix may take tracks from.
  bool useHardwax = true;
  bool useTrax = true;
  bool useRa = true;
  bool useBandcamp = true;
  bool useDiscogs = true;
  String hwTag = '';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('af_hw_v1') ?? false)) {
        // One-time switch of the default from the Dance chart to Hardwax.
        await prefs.setBool('af_hw_v1', true);
        await prefs.setString('af_source', 'chart');
        await prefs.setBool('af_hardwax', true);
        await prefs.setString('af_hw_tag', '');
      }
      hardwax = prefs.getBool('af_hardwax') ?? hardwax;
      useHardwax = prefs.getBool('af_use_hw') ?? useHardwax;
      useTrax = prefs.getBool('af_use_trax') ?? useTrax;
      useRa = prefs.getBool('af_use_ra') ?? useRa;
      genres = prefs.getStringList('af_genres') ?? genres;
      pinned = prefs.getBool('af_pinned') ?? pinned;
      useBandcamp = prefs.getBool('af_use_bc') ?? useBandcamp;
      useDiscogs = prefs.getBool('af_use_dg') ?? useDiscogs;
      hwTag = prefs.getString('af_hw_tag') ?? hwTag;
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
      useYearRange = prefs.getBool('af_range') ?? useYearRange;
      yearFrom = prefs.getInt('af_year_from') ?? yearFrom;
      yearTo = prefs.getInt('af_year_to') ?? yearTo;
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
      await prefs.setBool('af_hardwax', hardwax);
      await prefs.setBool('af_use_hw', useHardwax);
      await prefs.setBool('af_use_trax', useTrax);
      await prefs.setBool('af_use_ra', useRa);
      await prefs.setStringList('af_genres', genres);
      await prefs.setBool('af_pinned', pinned);
      await prefs.setBool('af_use_bc', useBandcamp);
      await prefs.setBool('af_use_dg', useDiscogs);
      await prefs.setString('af_hw_tag', hwTag);
      await prefs.setInt('af_chart_id', chartId);
      await prefs.setString('af_chart_name', chartName);
      await prefs.setBool('af_chart_tempo', chartTempo);
      await prefs.setString('af_pasted', pasted);
      await prefs.setString('af_genre', genre);
      await prefs.setDouble('af_bpm_min', bpmMin);
      await prefs.setDouble('af_bpm_max', bpmMax);
      await prefs.setInt('af_count', count);
      await prefs.setBool('af_years', similarYears);
      await prefs.setBool('af_range', useYearRange);
      await prefs.setInt('af_year_from', yearFrom);
      await prefs.setInt('af_year_to', yearTo);
      await prefs.setInt('af_year_span', yearSpan);
      await prefs.setInt('af_buffer', buffer);
      await prefs.setBool('af_endless', endless);
    } catch (_) {}
  }

  /// The AUTO switch: on starts fetching with the saved settings, off stops.
  void toggle(bool on, LibraryController library) {
    DebugLog.add('fetch', 'AUTO ${on ? 'ON' : 'OFF'} (source $source)');
    if (on && (source == 'chart' || source == 'trax')) {
      startShops(library: library, count: count, endless: endless);
    } else if (on && source == 'list') {
      startList(text: pasted, library: library);
    } else if (on) {
      startGenreMode(library);
    } else {
      genreMode = false;
      followAutomix = false;
      if (running) stop();
      notifyListeners();
    }
  }

  bool running = false;

  /// AUTO is switched on by automix: nothing runs all the time, but a
  /// matching track is fetched whenever automix asks for one.
  bool followAutomix = false;

  void refresh() => notifyListeners();
  String status = '';
  int fetched = 0;
  int limit = 5;
  final List<String> log = [];

  bool _stop = false;
  LibraryController? _lib;

  void _say(String s) {
    if (!s.contains('%')) DebugLog.add('fetch', s);
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

  /// A fixed range of years for genre and chart fetching.
  bool useYearRange = false;
  int yearFrom = 1995;
  int yearTo = 2026;

  bool _yearOk(Suggestion s) {
    if (useYearRange) {
      if (s.year == 0 || s.year < yearFrom || s.year > yearTo) return false;
    }
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
      // Signing in is automatic: wait for it instead of switching off.
      running = true;
      _stop = false;
      _say('Waiting for Soulseek to sign in…');
      for (var i = 0; i < 60 && !_stop && !soulseek.online; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final ready = soulseek.online && !_stop;
      running = false;
      if (!ready) {
        _say(_stop ? 'Stopped' : 'Could not sign in to Soulseek (check name and password)');
        return;
      }
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

  /// Hardwax releases: one tag page, or with an empty [tag] every tag page
  /// in turn (the whole shop), in random order.
  Future<void> startHardwax({
    required String tag,
    required LibraryController library,
    required int count,
    required bool endless,
  }) {
    final slugs = tag.isEmpty
        ? ([for (final t in Hardwax.tags) t.$2]..shuffle())
        : [tag];
    var next = 0;
    return _runSource(
      label: tag.isEmpty ? 'Hardwax (whole shop)' : 'Hardwax ($tag)',
      more: (tried) async {
        while (next < slugs.length) {
          final slug = slugs[next++];
          try {
            final l = (await Hardwax.fetch(slug, skip: tried))
                .where((s) => !Dislikes.instance.hasTrack(s.artist, s.title))
                .toList()
              ..shuffle();
            if (l.isNotEmpty) return l;
          } catch (_) {}
        }
        return <Suggestion>[];
      },
      library: library,
      count: count,
      endless: endless,
      useYears: false,
    );
  }

  /// Hardwax and/or Traxsource (the toggles under the AUTO switch), mixed
  /// together in random order.
  Future<void> startShops({
    required LibraryController library,
    required int count,
    required bool endless,
  }) {
    var given = false;
    final names = [if (useHardwax) 'Hardwax', if (useTrax) 'Traxsource'].join(' + ');
    return _runSource(
      label: names.isEmpty ? 'nothing (both shops are off)' : names,
      more: (tried) async {
        if (given) return <Suggestion>[];
        given = true;
        final lists = <List<Suggestion>>[];
        if (useHardwax) {
          final slugs = hwTag.isEmpty ? [for (final t in Hardwax.tags) t.$2] : [hwTag];
          final hw = <Suggestion>[];
          for (final slug in slugs) {
            try {
              hw.addAll(await Hardwax.fetch(slug, skip: tried));
            } catch (_) {}
          }
          lists.add(hw);
        }
        if (useTrax) {
          try {
            lists.add(await Traxsource.all());
          } catch (_) {}
        }
        final seen = <String>{};
        final all = <Suggestion>[];
        for (final l in lists) {
          l.shuffle();
        }
        for (var i = 0; lists.any((l) => i < l.length); i++) {
          for (final l in lists) {
            if (i >= l.length) continue;
            final x = l[i];
            if (tried.contains(x.query.toLowerCase())) continue;
            if (Dislikes.instance.hasTrack(x.artist, x.title)) continue;
            if (seen.add(x.query.toLowerCase())) all.add(x);
          }
        }
        return all;
      },
      library: library,
      count: count,
      endless: endless,
      useYears: false,
    );
  }

  /// Traxsource: the whole library (every genre's Top 100, read once a week),
  /// in random order.
  Future<void> startTraxsource({
    required LibraryController library,
    required int count,
    required bool endless,
  }) {
    var given = false;
    return _runSource(
      label: 'Traxsource (whole library)',
      more: (tried) async {
        if (given) return <Suggestion>[];
        given = true;
        final all = await Traxsource.all();
        return all
            .where((s) => !tried.contains(s.query.toLowerCase()) && !Dislikes.instance.hasTrack(s.artist, s.title))
            .toList()
          ..shuffle();
      },
      library: library,
      count: count,
      endless: endless,
      useYears: false,
    );
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
        needDetails: similarYears || useYearRange,
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

  // Tracks picked by hand (DJ Charts): fetched right away, one after another,
  // without the "enough waiting" pause.
  final List<Suggestion> _manual = [];
  bool _kicking = false;
  bool _manualRun = false;

  int get manualPending => _manual.length;

  void enqueueTracks(List<Suggestion> tracks, LibraryController library) {
    _manual.addAll(tracks.where((t) => !Dislikes.instance.hasTrack(t.artist, t.title)));
    _lib = library;
    notifyListeners();
    _kick(library);
  }

  Future<void> _kick(LibraryController library) async {
    if (_kicking) return;
    _kicking = true;
    try {
      while (_manual.isNotEmpty) {
        while (running) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        final batch = [..._manual];
        _manual.clear();
        var given = false;
        _manualRun = true;
        try {
          await _runSource(
            label: 'your picks (${batch.length} tracks)',
            more: (tried) async {
              if (given) return <Suggestion>[];
              given = true;
              return batch;
            },
            library: library,
            count: batch.length,
            endless: false,
            once: true,
            useYears: false,
          );
        } finally {
          _manualRun = false;
        }
      }
    } finally {
      _kicking = false;
    }
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
        .where((p) =>
            !dj.loadedPaths.contains(p) &&
            !dj.failedPaths.contains(p) &&
            File(p).existsSync())
        .length;
  }

  /// Holds off while enough good tracks are queued up.
  Future<void> _waitForRoom() async {
    while (!_stop && !_manualRun && _waiting() >= buffer) {
      _say('Paused: ${_waiting()} tracks waiting to be played');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  /// Picks by genre and tempo alone, no seed track. With [endless] it keeps
  /// going until stopped; otherwise it stops after [count] downloads.
  /// Underground tracks that match the one playing: its genre and tempo (a
  /// few percent either way). The key is checked later, once downloaded and
  /// analysed. Used by automix when nothing in its queue fits.
  Future<void> startMatching({
    required String genre,
    required String artist,
    required String title,
    required double bpm,
    required LibraryController library,
    int count = 2,
  }) async {
    if (running) return;
    var g = genre.trim();
    if (g.isEmpty && artist.isNotEmpty) {
      try {
        final info = await _service.lookupSeed(artist, title);
        if (info.genres.isNotEmpty) g = info.genres.first;
      } catch (_) {}
    }
    if (g.isEmpty) g = genreForBpm(bpm);
    final double? lo = bpm > 1 ? bpm * 0.93 : null;
    final double? hi = bpm > 1 ? bpm * 1.07 : null;
    DebugLog.add('fetch',
        'matching the playing track: genre "$g", ${lo == null ? 'any tempo' : '${lo.round()}-${hi!.round()} BPM'}, underground only');
    // Hardwax first (never chart music); the Deezer low-rank list only when
    // the shop's list for this style has nothing left.
    final slug = _hardwaxSlug(g);
    var hwDone = false;
    await _runSource(
      label: '$g${bpm > 1 ? ', ${bpm.round()} BPM' : ''}, Hardwax then Traxsource',
      more: (tried) async {
        if (!hwDone && useHardwax) {
          hwDone = true;
          try {
            final hw = await Hardwax.fetch(slug, skip: tried);
            final fresh = hw.where((s) => !Dislikes.instance.hasTrack(s.artist, s.title)).toList()
              ..shuffle();
            if (fresh.isNotEmpty) return fresh.take(12).toList();
          } catch (_) {}
        }
        // Traxsource (read once a week) instead of Deezer, by genre family and tempo.
        if (!useTrax) return <Suggestion>[];
        try {
          final tx = (await Traxsource.matching(g, bpmMin: lo, bpmMax: hi))
              .where((s) =>
                  !tried.contains(s.query.toLowerCase()) &&
                  !Dislikes.instance.hasTrack(s.artist, s.title))
              .toList()
            ..shuffle();
          if (tx.isNotEmpty) return tx.take(12).toList();
        } catch (e) {
          DebugLog.add('fetch', 'Traxsource list not available: $e');
        }
        // Last resort when the shop lists gave nothing: low-play-count tracks
        // of the same genre and tempo (never chart music).
        DebugLog.add('fetch', 'the shop lists had nothing left, trying the underground list');
        return _service.underground(g, bpmMin: lo, bpmMax: hi, skip: tried, want: 12);
      },
      library: library,
      count: count,
      endless: false,
      useYears: false,
    );
  }


  // ---- Next track pipeline ---------------------------------------------------
  // One owner for "automix needs a track": build a shortlist from the shop
  // lists (genre and tempo of the playing track), search Soulseek one
  // candidate after another, keep up to three downloads going at once, and
  // take the first complete file. The file joins the library and automix
  // through the normal download hook; the stage is shown on the empty deck.
  bool _pipeline = false;
  bool get pipelineBusy => _pipeline;

  /// True when the last findNext brought a track in.
  bool lastFound = false;

  /// The Genre tab: keep fetching the chosen genre and tempo. The first track
  /// plays next when automix is running.
  bool genreMode = false;
  bool get active => running || followAutomix || genreMode;

  static final Set<String> _triedThisSession = {};

  // Genre the shop gave for a downloaded file (Traxsource lists one), used
  // when the file itself carries no genre tag.
  final Map<String, String> _genreHint = {};
  String hintFor(String path) => _genreHint[path] ?? '';


  Future<List<Suggestion>> _shortlist(String g, double? lo, double? hi, {bool exact = false}) async {
    final lib = _lib;
    final out = <Suggestion>[];
    final seen = <String>{};
    void add(Iterable<Suggestion> l) {
      for (final x in l) {
        final k = x.query.toLowerCase();
        if (Dislikes.instance.hasTrack(x.artist, x.title)) continue;
        if (lib != null && x.title.isNotEmpty && _inLibrary(lib, x)) continue;
        if (_triedThisSession.contains(k)) continue;
        if (seen.add(k)) out.add(x);
      }
    }

    var tx = <Suggestion>[];
    var hw = <Suggestion>[];
    if (useTrax) {
      try {
        tx = [...await Traxsource.matching(g, bpmMin: lo, bpmMax: hi)];
      } catch (e) {
        DebugLog.add('fetch', 'Traxsource list not available: $e');
      }
    }
    if (useHardwax) {
      try {
        hw = [...await Hardwax.fetch(_hardwaxSlug(g))];
      } catch (e) {
        DebugLog.add('fetch', 'Hardwax list not available: $e');
      }
    }
    var ra = <Suggestion>[];
    if (useRa) {
      try {
        ra = [...await RaSource.all()];
      } catch (e) {
        DebugLog.add('fetch', 'RA list not available: $e');
      }
    }
    var bc = <Suggestion>[];
    var dg = <Suggestion>[];
    if (useBandcamp) {
      try {
        bc = [...await Discover.bandcamp(g)];
      } catch (e) {
        DebugLog.add('fetch', 'Bandcamp list not available: $e');
      }
    }
    if (useDiscogs) {
      try {
        dg = [...await Discover.discogs(g)];
      } catch (e) {
        DebugLog.add('fetch', 'Discogs list not available: $e');
      }
    }
    bc.shuffle();
    dg.shuffle();
    bc = bc.take(15).toList();
    dg = dg.take(15).toList();
    ra.shuffle();
    tx.shuffle();
    hw.shuffle();
    if (exact) {
      // The genre you chose: Traxsource genres sharing the most words with it
      // come first ("funky tech house" prefers "Tech House" and "Funky House").
      final words = RegExp(r'[a-z]{3,}').allMatches(g.toLowerCase()).map((m) => m.group(0)!).toSet();
      int score(Suggestion x) => RegExp(r'[a-z]{3,}')
          .allMatches(x.reason.toLowerCase())
          .where((m) => words.contains(m.group(0)))
          .length;
      tx.sort((a, b) => score(b).compareTo(score(a)));
    }
    // Traxsource first (it has the tempo), then Hardwax, alternating.
    final mixed = <Suggestion>[];
    for (var i = 0; i < tx.length || i < hw.length || i < ra.length || i < bc.length || i < dg.length; i++) {
      if (i < tx.length) mixed.add(tx[i]);
      if (i < ra.length) mixed.add(ra[i]);
      if (i < hw.length) mixed.add(hw[i]);
      if (i < bc.length) mixed.add(bc[i]);
      if (i < dg.length) mixed.add(dg[i]);
    }
    // Your playlists decide the order: tracks by artists or on labels you
    // have in them first, then a couple of other tracks by artists you like,
    // then the rest.
    // Liked only counts when the artist's music is the same kind as what is
    // playing (a dub artist does not jump the queue after minimal house).
    bool likedHere(Suggestion x) =>
        Taste.likesTrack(x.artist, x.label) && genresSimilar(g, Taste.genreOf(x.artist));
    final liked = [for (final x in mixed) if (likedHere(x)) x];
    final rest = [for (final x in mixed) if (!likedHere(x)) x];
    add(liked.take(4));
    final fav = Taste.pick(2, genre: g);
    add([for (final a in fav) Suggestion(a, '', 0, 'You like')]);
    add(rest);
    add(liked.skip(4));
    DebugLog.add('fetch',
        'taste: ${Taste.artists.length} artists and ${Taste.labels.length} labels from your playlists, ${liked.length} liked on the shop lists');
    DebugLog.add('fetch', 'shortlist for "$g": ${tx.length} Traxsource + ${hw.length} Hardwax + ${ra.length} RA + ${bc.length} Bandcamp + ${dg.length} Discogs, ${out.length} usable');
    if (out.length < 5) {
      // Shops unreachable or empty: more artists from your own playlists.
      final more = Taste.pick(6, genre: g);
      final extra = more.isEmpty ? Taste.pick(6) : more;
      DebugLog.add('fetch', 'shop lists are short, adding ${extra.length} artists from your playlists');
      add([for (final a in extra) Suggestion(a, '', 0, 'You like')]);
    }
    if (out.length < 5) {
      DebugLog.add('fetch', 'still short, adding the underground list');
      try {
        add(await _service.underground(g, bpmMin: lo, bpmMax: hi, skip: seen, want: 10));
      } catch (e) {
        DebugLog.add('fetch', 'underground list not available: $e');
      }
    }
    return out.take(20).toList();
  }

  /// Searches for [s], picks the best file and starts its download. Null when
  /// nothing usable was found.
  Future<_Flight?> _startFlight(Suggestion s) async {
    // Not signed in right now: wait for the connection instead of using up
    // the shortlist on searches that cannot run.
    for (var w = 0; w < 90 && !_stop && !soulseek.online; w++) {
      if (w == 0) _say('Next track: Soulseek is reconnecting, waiting…');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!soulseek.online) return null;
    _triedThisSession.add(s.query.toLowerCase());
    final dir = _lib == null ? null : SlskSetup.dirFor(_lib!);
    if (dir != null) {
      final reason = await StorageGuard.blockReason(dir, 60 * 1024 * 1024);
      if (reason != null) {
        _stop = true;
        _say('Next track: stopped. $reason');
        return null;
      }
    }
    _say('Next track: searching for ${s.artist} - ${s.title}');
    soulseek.search(s.query);
    var waited = 0;
    await Future<void>.delayed(const Duration(seconds: 2));
    while (soulseek.searching && waited < 10 && !_stop) {
      await Future<void>.delayed(const Duration(seconds: 1));
      waited++;
    }
    final best = _pick(s, null);
    if (best == null) {
      DebugLog.add('fetch', 'no good match for ${s.artist} - ${s.title}');
      return null;
    }
    soulseek.download(best);
    for (final d in soulseek.downloads) {
      if (d.user == best.user && d.remotePath == best.path) {
        DebugLog.add('fetch', 'downloading ${best.fileName}');
        return _Flight(s, d, best.fileName);
      }
    }
    return null;
  }

  /// Finds a track for automix and puts it in the library. Returns when one
  /// has downloaded, or when it gave up.
  Future<void> findNext({
    required String genre,
    required String artist,
    required String title,
    required double bpm,
    required LibraryController library,
    double? bpmLo,
    double? bpmHi,
    bool steer = false,
  }) async {
    if (running || _pipeline) return;
    lastFound = false;
    _pipeline = true;
    running = true;
    _lib = library;
    _stop = false;
    fetched = 0;
    limit = 1;
    log.clear();
    notifyListeners();
    final flights = <_Flight>[];
    try {
      var g = genre.trim().replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z])'), (_) => ' ').toLowerCase();
      if (g.isEmpty) g = genreForBpm(bpm);
      final double? lo = bpmLo ?? (bpm > 1 ? bpm * 0.93 : null);
      final double? hi = bpmHi ?? (bpm > 1 ? bpm * 1.07 : null);
      // A genre you chose yourself: the download plays next.
      if (steer) SlskSetup.dj?.armPlayNext();
      DebugLog.add('fetch',
          'next track${steer ? ' (your choice, plays next)' : ''}: genre "$g", ${lo == null ? 'any tempo' : '${lo.round()}-${hi!.round()} BPM'}');
      if (!soulseek.online) {
        _say('Next track: waiting for Soulseek to sign in…');
        for (var i = 0; i < 60 && !_stop && !soulseek.online; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (!soulseek.online) {
          _say('Next track: could not sign in to Soulseek (check name and password)');
          return;
        }
      }
      await Taste.refresh(library);
      _say('Next track: building a shortlist for $g');
      var list = await _shortlist(g, lo, hi, exact: steer);
      if (list.isEmpty && _triedThisSession.isNotEmpty) {
        // Everything on the lists was tried: start over once.
        _triedThisSession.clear();
        list = await _shortlist(g, lo, hi, exact: steer);
      }
      if (list.isEmpty) {
        _say('Next track: the shop lists have nothing for $g');
        return;
      }
      String? winner;
      var i = 0;
      final started = DateTime.now();
      while (!_stop && winner == null) {
        for (final f in [...flights]) {
          if (f.dl.state == DlState.done && f.dl.savedPath != null) {
            const generic = {'Hardwax', 'RA', 'You like', 'Bandcamp', 'Discogs'};
            if (f.s.reason.isNotEmpty &&
                !generic.contains(f.s.reason) &&
                !f.s.reason.contains('underground')) {
              _genreHint[f.dl.savedPath!] = f.s.reason;
            }
            // Look at the file before it goes anywhere near a deck.
            final bad = await AudioCheck.problem(f.dl.savedPath!);
            if (bad == null) {
              winner = f.dl.savedPath;
              break;
            }
            DebugLog.add('fetch', 'rejected ${f.name}: $bad. Deleting it and trying another');
            _say('Next track: ${f.name} is not usable ($bad), trying another');
            flights.remove(f);
            try {
              await File(f.dl.savedPath!).delete();
            } catch (_) {}
            soulseek.removeDownload(f.dl);
            continue;
          }
          if (f.dl.state == DlState.failed) {
            flights.remove(f);
            DebugLog.add('fetch', 'download failed: ${f.name}');
          }
        }
        if (winner != null) break;
        if (DateTime.now().difference(started).inMinutes >= 6) {
          DebugLog.add('fetch', 'next track: gave up after 6 minutes');
          break;
        }
        if (i >= list.length && flights.isEmpty) break;
        if (i < list.length && flights.length < 3) {
          try {
            final f = await _startFlight(list[i++]);
            if (f != null) flights.add(f);
          } catch (e, st) {
            // One bad candidate must not stop the rest.
            DebugLog.add('fetch', 'candidate skipped: $e ${st.toString().split('\n').take(3).join(' | ')}');
          }
        } else {
          if (flights.isNotEmpty) {
            final f = flights.first;
            _say('Next track: downloading ${f.name} ${(f.dl.progress * 100).round()}%');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      for (final f in flights) {
        if (f.dl.state != DlState.done) soulseek.removeDownload(f.dl);
      }
      if (winner != null) {
        _fetched.add(winner);
        fetched = 1;
        lastFound = true;
        DebugLog.ok('fetch', 'next track downloaded: $winner');
        _say('Next track: downloaded, checking it');
      } else if (!_stop) {
        _say('Next track: nothing usable found on Soulseek yet');
      }
    } catch (e) {
      DebugLog.add('fetch', 'next track pipeline error: $e');
      _say('Next track: stopped ($e)');
    } finally {
      _pipeline = false;
      running = false;
      notifyListeners();
    }
  }

  /// The Hardwax tag page that fits a genre name.
  static String _hardwaxSlug(String genre) {
    switch (genreFamily(genre)) {
      case 'house':
        return genre.toLowerCase().contains('detroit') ? 'detroit-house' : 'house';
      case 'techno':
      case 'trance':
        return 'techno';
      case 'breaks':
        return genre.toLowerCase().contains('electro') ? 'electro' : 'bass';
      case 'dnb':
        return 'drum-and-bass';
      case 'dub':
        return 'reggae-dub';
      case 'ambient':
        return 'ambient';
      case 'hiphop':
        return 'new-global-styles';
      default:
        return 'this-week';
    }
  }

  /// The Genre tab: fetch tracks of the chosen genre and tempo through the
  /// same pipeline. With automix running, the first one plays next.
  Future<void> startGenreMode(LibraryController library) async {
    if (genreMode) return;
    genreMode = true;
    notifyListeners();
    var got = 0;
    try {
      while (genreMode && (endless || got < count)) {
        final dj = SlskSetup.dj;
        // Enough already waiting: pause until automix needs more (not for the
        // first one, which is wanted at once).
        while (genreMode && got > 0 && dj != null && dj.automixOn && dj.automixWaiting >= buffer) {
          _say('Genre: ${dj.automixWaiting} tracks waiting, holding on');
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        if (!genreMode) break;
        await findNext(
          genre: pickGenre(),
          artist: '',
          title: '',
          bpm: (bpmMin + bpmMax) / 2,
          bpmLo: bpmMin,
          bpmHi: bpmMax,
          library: library,
          steer: got == 0 && (dj?.automixOn ?? false),
        );
        if (lastFound) {
          got++;
        } else {
          // Nothing this time: wait a little, then try the next candidates.
          for (var i = 0; i < 10 && genreMode; i++) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
      }
    } finally {
      genreMode = false;
      notifyListeners();
    }
  }

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
    await Dislikes.instance.load();
    if (Dislikes.instance.hasTrack(s.artist, s.title)) {
      DebugLog.add('fetch', 'skipped (you deleted it before): ${s.artist} - ${s.title}');
      return null;
    }
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
        DebugLog.ok('fetch', 'downloaded and verified: ${sp ?? '?'}');
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
      // Skip anything under 3 minutes (clips, edits, snippets), unless the
      // track is from 1990 or earlier, when records were often shorter.
      final secs = r.durationSec > 0
          ? r.durationSec
          : (r.bitrate > 0 ? (r.size * 8 / (r.bitrate * 1000)).round() : 0);
      final oldRecord = s.year > 0 && s.year <= 1990;
      if (secs > 0 && secs < 180 && !oldRecord) continue;
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

class _Flight {
  _Flight(this.s, this.dl, this.name);
  final Suggestion s;
  final SlskDownload dl;
  final String name;
}
