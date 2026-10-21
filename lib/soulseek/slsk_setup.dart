import 'dart:io';

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
  static void wire(LibraryController lib) {
    library = lib;
    soulseek.downloadDir = () => dirFor(lib);
    soulseek.storageCheck = (size) => StorageGuard.blockReason(dirFor(lib), size);
    dj?.onFileMissing = (_) => lib.removeMissing();
    dj?.fetchBusy = () => AutoFetch.instance.running || AutoFetch.instance.manualPending > 0;
    dj?.genrePinned = () => AutoFetch.instance.pinned && AutoFetch.instance.genres.isNotEmpty;
    dj?.genreOf = (path) {
      final g = lib.genreOf(path);
      return g.isNotEmpty ? g : AutoFetch.instance.hintFor(path);
    };
    dj?.fetchStatus = () => AutoFetch.instance.status;
    AutoFetch.instance.addListener(() => dj?.refresh());
    // Starting automix switches AUTO on and makes sure Soulseek is signed in.
    dj?.onAutomixStart = () {
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
        DebugLog.add('automix', 'cannot fetch a match: auto-fetch is busy');
        return;
      }
      // One pipeline: shortlist, search, download, library, automix.
      () async {
        // Keep searching until a track is found (or automix is stopped).
        while (true) {
          final pin = af.pinned && af.genres.isNotEmpty;
          await af.findNext(
            genre: pin ? af.pickGenre() : genre,
            artist: artist,
            title: title,
            bpm: bpm,
            library: lib,
            bpmLo: pin ? af.bpmMin : null,
            bpmHi: pin ? af.bpmMax : null,
            steer: pin,
          );
          if (af.lastFound || !(dj?.automixOn ?? false) || !autoFetchForAutomix) return;
          DebugLog.add('automix', 'nothing found yet, searching again');
          await Future<void>.delayed(const Duration(seconds: 4));
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
