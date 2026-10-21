import 'package:sidedeck/debug/debug_log.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/tags.dart';
import 'package:sidedeck/engine/track_analyzer.dart';

class LibraryTrack {
  LibraryTrack({
    required this.path,
    required this.title,
    this.artist = '',
    this.durationMs = 0,
    this.bpm,
    this.key,
    this.modifiedMs = 0,
    this.genre = '',
    this.year = 0,
    this.tagsRead = false,
  });

  final String path;
  final String title;
  final String artist;
  final int durationMs;
  final double? bpm;
  final int? key;

  /// File date, for sorting by newest.
  final int modifiedMs;

  /// From the file's tags (empty / 0 when not known).
  final String genre;
  final int year;
  final bool tagsRead;

  bool get hasAnalysis => bpm != null && bpm! > 0;

  LibraryTrack copyWith({double? bpm, int? key}) {
    return LibraryTrack(
      path: path,
      title: title,
      artist: artist,
      durationMs: durationMs,
      bpm: bpm ?? this.bpm,
      key: key ?? this.key,
      modifiedMs: modifiedMs,
      genre: genre,
      year: year,
      tagsRead: tagsRead,
    );
  }

  LibraryTrack withTags(String genre, int year) => LibraryTrack(
        path: path,
        title: title,
        artist: artist,
        durationMs: durationMs,
        bpm: bpm,
        key: key,
        modifiedMs: modifiedMs,
        genre: genre,
        year: year,
        tagsRead: true,
      );
}

class LibraryController extends ChangeNotifier {
  LibraryController() {
    restore();
  }

  final AnalysisCache _cache = AnalysisCache.instance;
  final List<LibraryTrack> tracks = [];
  String query = '';
  TrackSort sort = TrackSort.name;
  bool loading = false;
  String? error;
  String? folderPath;
  bool _disposed = false;

  bool analyzing = false;
  bool _cancelAnalyze = false;
  int analyzeDone = 0;
  int analyzeTotal = 0;
  String? analyzingPath;

  List<LibraryTrack> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List.unmodifiable(tracks);
    return tracks
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q),
        )
        .toList();
  }

  int get unanalyzedCount => tracks.where((t) => !t.hasAnalysis).length;

  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAnalyze = true;
    super.dispose();
  }

  Future<void> restore() async {
    loading = true;
    _emit();
    try {
      final prefs = await SharedPreferences.getInstance();
      folderPath = prefs.getString('library_folder');
      final extra = prefs.getStringList('library_paths') ?? [];
      if (folderPath != null && folderPath!.isNotEmpty) {
        await scanDirectory(folderPath!, persist: false);
      }
      for (final path in extra) {
        await _addPath(path);
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _emit();
    unawaited(readTags());
  }

  /// Number of tracks the last [refresh] found.
  int lastRefreshAdded = 0;

  /// Looks again in the saved folder (for example after Seeker downloaded
  /// something) and adds new files. Quiet: no loading spinner unless it
  /// finds something.
  Future<int> refresh() async {
    final dir = folderPath;
    if (dir == null || dir.isEmpty || loading) return 0;
    final before = tracks.length;
    try {
      await scanDirectory(dir, persist: false);
    } catch (e) {
      error = e.toString();
    }
    lastRefreshAdded = tracks.length - before;
    if (lastRefreshAdded > 0) {
      await _persist();
      _emit();
      unawaited(readTags());
    }
    return lastRefreshAdded;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (folderPath != null) {
      await prefs.setString('library_folder', folderPath!);
    }
    await prefs.setStringList(
      'library_paths',
      [
        for (final t in tracks)
          if (folderPath == null || !p.isWithin(folderPath!, t.path)) t.path,
      ],
    );
  }

  Future<void> pickFiles() async {
    loading = true;
    error = null;
    _emit();
    try {
      await ensurePermission();
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: nativeAudioPickerExtensions(),
        allowMultiple: true,
        withData: false,
      );
      if (result == null) {
        loading = false;
        _emit();
        return;
      }
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue;
        await _addPath(await _keepPermanently(path));
      }
      await _persist();
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _emit();
  }

  /// Files picked from cloud storage (Drive, Dropbox, OneDrive...) arrive as
  /// temporary copies that Android may delete. Keep our own copy so the track
  /// stays in the library. Files from normal storage are used where they are.
  Future<String> _keepPermanently(String path) async {
    try {
      final temp = (await getTemporaryDirectory()).path;
      if (!p.isWithin(temp, path)) return path;
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'cloud'));
      await dir.create(recursive: true);
      var target = p.join(dir.path, p.basename(path));
      var n = 1;
      while (await File(target).exists()) {
        final stem = p.basenameWithoutExtension(path);
        target = p.join(dir.path, '$stem ($n)${p.extension(path)}');
        n++;
      }
      await File(path).copy(target);
      return target;
    } catch (_) {
      return path;
    }
  }

  Future<void> pickFolder() async {
    loading = true;
    error = null;
    _emit();
    try {
      await ensurePermission();
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) {
        loading = false;
        _emit();
        return;
      }
      folderPath = dir;
      await scanDirectory(dir);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _emit();
  }

  /// Same song under different file names: ignores case, the extension and a
  /// trailing "(1)" style copy marker.
  static String dupKey(String path) {
    var name = p.basenameWithoutExtension(path);
    name = name.replaceFirst(RegExp(r'\s*\(\d+\)$'), '');
    return name.toLowerCase().trim();
  }

  bool _sameLength(int a, int b) => a <= 0 || b <= 0 || (a - b).abs() < 3000;

  /// The extra copies: for each song found more than once, every file except
  /// the best one (analysed first, then the largest).
  List<LibraryTrack> duplicateTracks() {
    final groups = <String, List<LibraryTrack>>{};
    for (final t in tracks) {
      groups.putIfAbsent(dupKey(t.path), () => []).add(t);
    }
    final extras = <LibraryTrack>[];
    for (final g in groups.values) {
      if (g.length < 2) continue;
      // Split into runs of the same length so different mixes with one name stay.
      final remaining = List<LibraryTrack>.of(g);
      while (remaining.isNotEmpty) {
        final first = remaining.removeAt(0);
        final same = [first, ...remaining.where((t) => _sameLength(first.durationMs, t.durationMs))];
        remaining.removeWhere((t) => same.contains(t));
        if (same.length < 2) continue;
        int size(LibraryTrack t) {
          try {
            return File(t.path).lengthSync();
          } catch (_) {
            return 0;
          }
        }
        same.sort((a, b) {
          if (a.hasAnalysis != b.hasAnalysis) return a.hasAnalysis ? -1 : 1;
          return size(b).compareTo(size(a));
        });
        extras.addAll(same.skip(1));
      }
    }
    return extras;
  }

  /// Deletes the given files from the phone and the library. Returns how many
  /// could be deleted.
  /// Drops library entries whose file no longer exists. Returns how many.
  Future<int> removeMissing() async {
    final gone = <LibraryTrack>[];
    for (final t in tracks) {
      if (!await File(t.path).exists()) gone.add(t);
    }
    if (gone.isEmpty) return 0;
    for (final t in gone) {
      DebugLog.add('library', 'file missing, removed from library: ${t.path}');
    }
    tracks.removeWhere(gone.contains);
    await _persist();
    _emit();
    return gone.length;
  }

  Future<int> deleteTracks(List<LibraryTrack> list) async {
    var done = 0;
    for (final t in list) {
      try {
        await File(t.path).delete();
        tracks.removeWhere((x) => x.path == t.path);
        done++;
      } catch (_) {}
    }
    await _persist();
    _emit();
    return done;
  }

  /// Adds one finished download (or any file) to the library at once, keeps
  /// it across restarts and works out its tempo and key.
  /// Returns true when the file joined the library (false: not audio, or a
  /// copy of a track already there, which is deleted).
  Future<bool> addFile(String path) async {
    if (!isNativeAudioExtension(p.extension(path))) return false;
    // A copy of a track already in the library is not kept.
    final key = dupKey(path);
    final ms = (fileDurationSec(path) * 1000).round();
    final have = tracks.any((t) =>
        t.path != path && dupKey(t.path) == key && _sameLength(t.durationMs, ms));
    if (have) {
      DebugLog.add('library', 'duplicate, deleting $path (key $key, ${ms} ms)');
      try {
        await File(path).delete();
      } catch (_) {}
      return false;
    }
    await _addPath(path);
    DebugLog.add('library', 'added ${await DebugLog.describeFile(path)}');
    await _persist();
    _emit();
    unawaited(readTags());
    unawaited(analyzePath(path));
    return true;
  }

  Future<void> scanDirectory(String dirPath, {bool persist = true}) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (isNativeAudioExtension(ext)) {
        await _addPath(entity.path);
      }
    }
    if (persist) await _persist();
    _emit();
  }

  Future<void> _addPath(String path) async {
    if (tracks.any((t) => t.path == path)) return;
    final name = p.basenameWithoutExtension(path);
    final parsed = splitTitleArtist(name);
    double? bpm;
    int? key;
    var modified = 0;
    try {
      final stat = await File(path).stat();
      modified = stat.modified.millisecondsSinceEpoch;
      final cached = await _cache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
      if (cached != null && cached.bpm > 0) {
        bpm = cached.bpm;
        key = cached.key;
      }
    } catch (_) {}
    tracks.add(LibraryTrack(
      path: path,
      title: parsed.title,
      artist: parsed.artist,
      durationMs: (fileDurationSec(path) * 1000).round(),
      bpm: bpm,
      key: key,
      modifiedMs: modified,
    ));
  }

  bool _readingTags = false;
  final Map<String, String> _genreByPath = {};

  /// The tagged genre of a library file, empty when unknown.
  String genreOf(String path) => _genreByPath[path] ?? '';

  /// Reads genre and year for tracks that have not been read yet, a few at a
  /// time in the background. Results are saved so the next start is instant.
  Future<void> readTags() async {
    if (_readingTags) return;
    _readingTags = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> saved = {};
      try {
        saved = jsonDecode(prefs.getString('lib_tags_v1') ?? '{}') as Map<String, dynamic>;
      } catch (_) {}
      var changed = 0;
      for (var i = 0; i < tracks.length && !_disposed; i++) {
        final t = tracks[i];
        if (t.tagsRead) continue;
        var genre = '';
        var year = 0;
        final c = saved[t.path];
        if (c is List && c.length == 2) {
          genre = c[0] as String;
          year = c[1] as int;
        } else {
          final tags = await readTrackTags(t.path);
          genre = tags.genre;
          year = tags.year;
          if (year == 0) {
            final m = RegExp(r'(?<!\d)(19[2-9]\d|20[0-2]\d)(?!\d)').firstMatch(p.basename(t.path));
            if (m != null) year = int.parse(m.group(1)!);
          }
          saved[t.path] = [genre, year];
        }
        final at = tracks.indexWhere((x) => x.path == t.path);
        if (at >= 0) tracks[at] = tracks[at].withTags(genre, year);
        if (genre.isNotEmpty) _genreByPath[t.path] = genre;
        if (++changed % 25 == 0) {
          _emit();
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (changed > 0) {
        await prefs.setString('lib_tags_v1', jsonEncode(saved));
        _emit();
      }
    } catch (_) {
    } finally {
      _readingTags = false;
    }
  }

  void setQuery(String q) {
    query = q;
    _emit();
  }

  void setSort(TrackSort value) {
    if (sort == value) return;
    sort = value;
    sortDesc = value == TrackSort.added; // newest first by default
    _emit();
  }

  // ---- Sorting and filters -------------------------------------------------
  bool sortDesc = false;
  double? bpmMin;
  double? bpmMax;

  /// Only tracks whose key fits the track on this deck (-1 = off).
  int keyDeck = -1;
  bool onlyUnanalyzed = false;
  bool hidePlayed = false;

  /// Decades to show (1990 = the 1990s, 0 = year not known). Empty = all.
  final Set<int> decades = {};
  String genreFilter = '';

  /// Set by the screen: whether automix played a track in the last 24 hours,
  /// and the key now on a deck (-1 when nothing is loaded).
  bool Function(String path)? playedCheck;
  int Function(int deck)? deckKey;

  bool get hasFilters =>
      bpmMin != null ||
      bpmMax != null ||
      keyDeck >= 0 ||
      onlyUnanalyzed ||
      hidePlayed ||
      decades.isNotEmpty ||
      genreFilter.isNotEmpty;

  void setSortDesc(bool v) {
    sortDesc = v;
    _emit();
  }

  void setFilters({
    double? bpmMin,
    double? bpmMax,
    int? keyDeck,
    bool? onlyUnanalyzed,
    bool? hidePlayed,
    bool clearBpm = false,
  }) {
    if (clearBpm) {
      this.bpmMin = null;
      this.bpmMax = null;
    } else {
      this.bpmMin = bpmMin ?? this.bpmMin;
      this.bpmMax = bpmMax ?? this.bpmMax;
    }
    this.keyDeck = keyDeck ?? this.keyDeck;
    this.onlyUnanalyzed = onlyUnanalyzed ?? this.onlyUnanalyzed;
    this.hidePlayed = hidePlayed ?? this.hidePlayed;
    _emit();
  }

  void clearFilters() {
    bpmMin = null;
    bpmMax = null;
    keyDeck = -1;
    onlyUnanalyzed = false;
    hidePlayed = false;
    decades.clear();
    genreFilter = '';
    _emit();
  }

  void toggleDecade(int d) {
    if (!decades.remove(d)) decades.add(d);
    _emit();
  }

  void setGenre(String g) {
    genreFilter = genreFilter == g ? '' : g;
    _emit();
  }

  /// Genres found in the library with how many tracks have each.
  List<(String, int)> get genres {
    final m = <String, int>{};
    for (final t in tracks) {
      if (t.genre.isEmpty) continue;
      m[t.genre] = (m[t.genre] ?? 0) + 1;
    }
    final l = m.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return l;
  }

  static int decadeOf(int year) => year <= 0 ? 0 : (year ~/ 10) * 10;

  /// The tracks shown: search text and filters applied, then sorted.
  List<LibraryTrack> get organised {
    final deckKeyNow = keyDeck >= 0 ? (deckKey?.call(keyDeck) ?? -1) : -1;
    final list = filtered.where((t) {
      if (onlyUnanalyzed && t.hasAnalysis) return false;
      if (bpmMin != null && (t.bpm == null || t.bpm! < bpmMin!)) return false;
      if (bpmMax != null && (t.bpm == null || t.bpm! > bpmMax!)) return false;
      if (keyDeck >= 0 && deckKeyNow >= 0) {
        if (t.key == null || t.key! < 0 || !keysCompatible(deckKeyNow, t.key!)) return false;
      }
      if (hidePlayed && (playedCheck?.call(t.path) ?? false)) return false;
      if (decades.isNotEmpty && !decades.contains(decadeOf(t.year))) return false;
      if (genreFilter.isNotEmpty && t.genre.toLowerCase() != genreFilter.toLowerCase()) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      int c;
      switch (sort) {
        case TrackSort.length:
          c = a.durationMs.compareTo(b.durationMs);
          break;
        case TrackSort.added:
          c = a.modifiedMs.compareTo(b.modifiedMs);
          break;
        case TrackSort.genre:
          // Tracks with no genre go last; same genre by name.
          if (a.genre.isEmpty != b.genre.isEmpty) {
            c = a.genre.isEmpty ? 1 : -1;
            return sortDesc ? -c : c;
          }
          c = a.genre.toLowerCase().compareTo(b.genre.toLowerCase());
          if (c == 0) c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case TrackSort.year:
          if ((a.year == 0) != (b.year == 0)) {
            c = a.year == 0 ? 1 : -1;
            return sortDesc ? -c : c;
          }
          c = a.year.compareTo(b.year);
          if (c == 0) c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        default:
          c = compareTrackSort(sort, a.title, a.artist, a.bpm, a.key, b.title,
              b.artist, b.bpm, b.key);
      }
      return sortDesc ? -c : c;
    });
    return list;
  }

  void upsertAnalysis(String path, {double? bpm, int? key}) {
    final i = tracks.indexWhere((t) => t.path == path);
    if (i < 0) return;
    tracks[i] = tracks[i].copyWith(bpm: bpm, key: key);
    _emit();
  }

  void cancelAnalyze() {
    _cancelAnalyze = true;
  }

  /// Returns the paths that were successfully analyzed, so callers can refresh
  /// anything holding the old values (e.g. a deck with the track loaded).
  Future<List<String>> analyzePath(String path) async {
    if (analyzing) return const [];
    return _analyzeList([path]);
  }

  Future<List<String>> analyzeMissing() async {
    final pending = tracks.where((t) => !t.hasAnalysis).map((t) => t.path).toList();
    return _analyzeList(pending);
  }

  Future<List<String>> analyzeAll() async {
    return _analyzeList(tracks.map((t) => t.path).toList());
  }

  Future<List<String>> _analyzeList(List<String> paths) async {
    final analyzed = <String>[];
    if (paths.isEmpty || analyzing) return analyzed;
    analyzing = true;
    _cancelAnalyze = false;
    analyzeDone = 0;
    analyzeTotal = paths.length;
    error = null;
    _emit();
    try {
      for (final path in paths) {
        if (_cancelAnalyze) break;
        analyzingPath = path;
        _emit();
        final result = await analyzeTrackFileOffUi(path);
        analyzeDone++;
        if (result == null) continue;
        try {
          final stat = await File(path).stat();
          await _cache.put(
            path: path,
            size: stat.size,
            mtime: stat.modified.millisecondsSinceEpoch,
            bpm: result.bpm,
            key: result.key,
            beatOffset: result.beatOffset,
          );
        } catch (_) {}
        upsertAnalysis(path, bpm: result.bpm, key: result.key);
        analyzed.add(path);
      }
    } catch (e) {
      error = e.toString();
    }
    analyzing = false;
    analyzingPath = null;
    analyzeTotal = 0;
    analyzeDone = 0;
    _emit();
    return analyzed;
  }
}

