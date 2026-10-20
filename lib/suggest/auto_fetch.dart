import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/suggest/suggest_service.dart';

/// Fetches tracks that suit a seed track, one after another: look up what
/// goes with it, search Soulseek, take the best result, and when it has
/// finished move on to the next. Stops after [limit] downloads.
class AutoFetch extends ChangeNotifier {
  AutoFetch._();

  static final AutoFetch instance = AutoFetch._();

  final SuggestService _service = SuggestService();

  bool running = false;
  String status = '';
  int fetched = 0;
  int limit = 5;
  final List<String> log = [];

  bool _stop = false;

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
        final cands = await _service.candidates(info.artistId!, sArtist);
        final queue = cands
            .where((c) =>
                !tried.contains(c.query.toLowerCase()) &&
                !_inLibrary(library, c) &&
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

  bool _inLibrary(LibraryController lib, Suggestion s) {
    final t = s.title.toLowerCase();
    return lib.tracks.any((x) => x.title.toLowerCase() == t);
  }

  /// Searches, picks the best match, waits until it has downloaded. Returns
  /// the saved path, or null when nothing usable turned up.
  Future<String?> _fetchOne(Suggestion s, CamelotKey? seedKey) async {
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
      if (dl.state == DlState.done) return dl.savedPath;
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
      if (!isNativeAudioExtension(r.ext)) continue;
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
