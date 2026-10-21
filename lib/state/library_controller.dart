import 'package:sidedeck/debug/debug_log.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/track_analyzer.dart';

class LibraryTrack {
  LibraryTrack({
    required this.path,
    required this.title,
    this.artist = '',
    this.durationMs = 0,
    this.bpm,
    this.key,
  });

  final String path;
  final String title;
  final String artist;
  final int durationMs;
  final double? bpm;
  final int? key;

  bool get hasAnalysis => bpm != null && bpm! > 0;

  LibraryTrack copyWith({double? bpm, int? key}) {
    return LibraryTrack(
      path: path,
      title: title,
      artist: artist,
      durationMs: durationMs,
      bpm: bpm ?? this.bpm,
      key: key ?? this.key,
    );
  }
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
    try {
      final stat = await File(path).stat();
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
    ));
  }

  void setQuery(String q) {
    query = q;
    _emit();
  }

  void setSort(TrackSort value) {
    if (sort == value) return;
    sort = value;
    _emit();
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

