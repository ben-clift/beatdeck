import 'package:sidedeck/automix/genre_family.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'dart:math' as math;
import 'dart:io';
import 'package:sidedeck/state/backup_tracks.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/playlist_controller.dart';

import 'package:file_picker/file_picker.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/soulseek/slsk_keeper.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/soulseek/storage_guard.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';

/// Where Soulseek downloads go, and what happens when one finishes.
class SlskSetup {
  /// Set at start-up so finished downloads can join a running automix.
  static DjController? dj;

  /// Set when Soulseek is wired up, for the self-test.
  static LibraryController? library;

  /// Folder the user picked, if any.
  static String? chosen;

  /// Used when nothing else is set.
  static String fallback = '';

  /// Automix fetches a matching track from Soulseek when none in the queue fit.
  static bool autoFetchForAutomix = true;

  static Future<void> setAutoFetchForAutomix(bool v) async {
    autoFetchForAutomix = v;
    try {
      (await SharedPreferences.getInstance()).setBool('automix_autofetch', v);
    } catch (_) {}
  }

  static Future<void> load() async {
    try {
      await StorageGuard.load();
      final prefs = await SharedPreferences.getInstance();
      autoFetchForAutomix = prefs.getBool('automix_autofetch') ?? true;
      // Older versions shared a folder with other apps and lost files there.
      // Only a folder picked on this version (slsk_dir2) is used.
      chosen = prefs.getString('slsk_dir2');
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/soulseek');
      await d.create(recursive: true);
      fallback = d.path;
    } catch (_) {}
  }

  /// The picked folder, else the library folder, else the app's own folder.
  static String dirFor(LibraryController lib) {
    final c = chosen;
    if (c != null && c.isNotEmpty) return c;
    return fallback;
  }

  /// Every finished download goes straight into the library, wherever it was
  /// saved, and is analysed for tempo and key.
  /// Removes a track automix has finished with, but only a file this app
  /// downloaded (never one from your own music folder).
  static Future<void> discardPlayed(LibraryController lib, String path) async {
    final own = fallback.isNotEmpty && path.startsWith(fallback);
    if (!own && !AutoFetch.instance.wasFetched(path)) return;
    if ((await BackupTracks.paths()).contains(path)) return; // kept for another day
    await Ratings.instance.load();
    if (Ratings.instance.starsOf(path) > 0) return; // starred: never deleted
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        DebugLog.add('automix', 'played, removed from the downloads: ${path.split(RegExp(r'[\\/]')).last}');
      }
      await lib.removeMissing();
    } catch (e) {
      DebugLog.add('automix', 'could not remove a played file: $e');
    }
  }

  static bool _recycling = false;

  /// Frees room by deleting downloaded tracks, never your own music, never
  /// starred or loaded ones. Order: Backup tracks first, then disliked ones,
  /// then the least played (older than a day, so fresh downloads survive).
  static Future<void> recycle(LibraryController lib, int incoming) async {
    if (_recycling) return;
    _recycling = true;
    try {
      final dir = dirFor(lib);
      await Ratings.instance.load();
      final backup = await BackupTracks.paths();
      final onDeck = <String>{
        for (var i = 0; i < 2; i++) if ((dj?.deck(i).path ?? '').isNotEmpty) dj!.deck(i).path!,
      };
      bool mine(String path) =>
          (dir.isNotEmpty && path.startsWith(dir)) || AutoFetch.instance.wasFetched(path);
      final cand = [
        for (final t in lib.tracks)
          if (mine(t.path) && !onDeck.contains(t.path) && Ratings.instance.starsOf(t.path) == 0) t
      ];
      int tier(LibraryTrack t) {
        if (backup.contains(t.path)) return 0;
        if (Dislikes.instance.hasPath(t.path)) return 1;
        return 2;
      }
      DateTime mod(LibraryTrack t) {
        try {
          return File(t.path).lastModifiedSync();
        } catch (_) {
          return DateTime.now();
        }
      }
      final dayAgo = DateTime.now().subtract(const Duration(days: 1));
      final order = cand.where((t) => tier(t) < 2 || mod(t).isBefore(dayAgo)).toList()
        ..sort((a, b) {
          final ta = tier(a), tb = tier(b);
          if (ta != tb) return ta.compareTo(tb);
          final pa = dj?.playCountOf(a.path) ?? 0, pb = dj?.playCountOf(b.path) ?? 0;
          if (pa != pb) return pa.compareTo(pb);
          return mod(a).compareTo(mod(b));
        });
      var freed = 0;
      var n = 0;
      for (final t in order) {
        if (await StorageGuard.blockReason(dir, incoming, recycle: false) == null) break;
        try {
          final f = File(t.path);
          if (!await f.exists()) continue;
          final size = await f.length();
          await f.delete();
          freed += size;
          n++;
          StorageGuard.forget();
          DebugLog.add('storage',
              'recycled (${const ['backup', 'disliked', 'least played'][tier(t)]}): ${t.path.split(RegExp(r'[\\/]')).last}');
        } catch (_) {}
      }
      if (n > 0) {
        await lib.removeMissing();
        await PlaylistController.reloadAll();
        DebugLog.add('storage', 'recycling freed ${(freed / 1048576).round()} MB from $n tracks');
      }
    } finally {
      _recycling = false;
    }
  }

  static void wire(LibraryController lib) {
    StorageGuard.recycle = (need) => recycle(lib, need);
    dj?.onTrackDone = (path) => discardPlayed(lib, path);
    library = lib;
    soulseek.downloadDir = () => dirFor(lib);
    soulseek.storageCheck = (size) => StorageGuard.blockReason(dirFor(lib), size);
    dj?.onFileMissing = (_) => lib.removeMissing();
    dj?.fetchBusy = () => AutoFetch.instance.running || AutoFetch.instance.manualPending > 0;
    dj?.fetchWanted = () => autoFetchForAutomix && AutoFetch.instance.followAutomix;
    dj?.intensityWanted = () => AutoFetch.instance.intensity;
    dj?.genrePinned = () => AutoFetch.instance.pinned && AutoFetch.instance.genres.isNotEmpty;
    dj?.tempoWindow = () {
      final af = AutoFetch.instance;
      if (!(af.pinned && af.genres.isNotEmpty)) return null;
      return (af.bpmMin, af.bpmMax);
    };
    dj?.genreOf = (path) {
      final g = lib.genreOf(path);
      return g.isNotEmpty ? g : AutoFetch.instance.hintFor(path);
    };
    dj?.fetchStatus = () => AutoFetch.instance.status;
    AutoFetch.instance.addListener(() => dj?.refresh());
    // Starting automix switches AUTO on and makes sure Soulseek is signed in.
    dj?.onAutomixStart = () {
      // Clear out downloads that have already been played.
      () async {
        for (final t in List.of(lib.tracks)) {
          if ((dj?.playedRecently(t.path) ?? false) && !(dj?.inAutomixQueue(t.path) ?? false)) await discardPlayed(lib, t.path);
        }
      }();
      if (!autoFetchForAutomix) return;
      soulseek.manualDisconnect = false;
      SlskKeeper.instance.setEnabled(true);
      AutoFetch.instance.followAutomix = true;
      AutoFetch.instance.refresh();
    };
    dj?.onAutomixStop = () {
      AutoFetch.instance.followAutomix = false;
      AutoFetch.instance.refresh();
    };
    dj?.onNeedTrack = (artist, bpm, key, title, genre) {
      final af = AutoFetch.instance;
      if (!autoFetchForAutomix) return;
      if (af.running) {
        return;
      }
      // One pipeline: shortlist, search, download, library, automix.
      () async {
        // Keep searching until a track is found (or automix is stopped). After
        // a search that finds nothing, the tempo range widens and a related
        // genre joins the pool.
        final pin = af.pinned && af.genres.isNotEmpty;
        final pool = <String>[if (pin) ...af.genres else genre];
        final fixedTempo = pin || af.tempoPinned;
        var lo = fixedTempo ? af.bpmMin : (bpm > 1 ? bpm * 0.93 : af.bpmMin);
        var hi = fixedTempo ? af.bpmMax : (bpm > 1 ? bpm * 1.07 : af.bpmMax);
        var attempt = 0;
        final rnd = math.Random();
        while (true) {
          await af.findNext(
            genre: pool[rnd.nextInt(pool.length)],
            artist: artist,
            title: title,
            bpm: bpm,
            library: lib,
            bpmLo: lo,
            bpmHi: hi,
            steer: pin,
          );
          if (af.lastFound || !(dj?.automixOn ?? false) || !autoFetchForAutomix) return;
          attempt++;
          lo = math.max(70, lo - 4);
          hi = math.min(180, hi + 4);
          String? add;
          for (final grp in genreGroups) {
            for (final g in grp.$2) {
              if (add != null || pool.contains(g.name)) continue;
              if (g.max < lo || g.min > hi) continue;
              if (pool.any((p) => genresSimilar(p, g.name))) add = g.name;
            }
          }
          if (add != null) pool.add(add);
          DebugLog.add('automix',
              'nothing found (try $attempt), widening to ${lo.round()}-${hi.round()} BPM${add == null ? '' : ' and adding $add'}');
          await Future<void>.delayed(const Duration(seconds: 3));
          if (!(dj?.automixOn ?? false) || af.running) return;
        }
      }();
    };
    soulseek.onFileSaved = (path) async {
      // One way in: library first, then automix, and only if it was kept.
      DebugLog.add('pipeline', 'verified, adding to library: $path');
      final added = await lib.addFile(path);
      if (!added) {
        DebugLog.add('pipeline', 'not added (duplicate or not audio): $path');
        return;
      }
      DebugLog.add('pipeline', 'in library, offering to automix: $path');
      dj?.automixAppend(path);
    };
  }

  static Future<bool> choose(LibraryController lib) async {
    await lib.ensurePermission();
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return false;
    chosen = dir;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('slsk_dir2', dir);
    } catch (_) {}
    return true;
  }
}
