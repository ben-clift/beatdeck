import 'dart:io';
import 'dart:isolate';

import 'package:sidedeck/engine/track_analyzer.dart';

/// A quick look at a file before it goes on a deck: right extension, a
/// believable size and the right first bytes for the format. It cannot prove
/// the whole file decodes, but it catches the usual bad downloads (empty,
/// truncated stubs, web pages or archives saved as audio).
class AudioCheck {
  static const _exts = {'mp3', 'flac', 'wav', 'ogg', 'opus', 'm4a', 'aac', 'mp4'};

  /// Null when the file looks playable, otherwise the reason it does not.
  static Future<String?> problem(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return 'the file is gone';
      final dot = path.lastIndexOf('.');
      final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
      if (!_exts.contains(ext)) return 'not a supported audio type (.$ext)';
      final len = await f.length();
      if (len < 150 * 1024) return 'too small to be a full track (${(len / 1024).round()} KB)';
      final raf = await f.open();
      final head = await raf.read(12);
      await raf.close();
      if (head.length < 12) return 'file too short';
      bool tag(int at, String s) {
        for (var i = 0; i < s.length; i++) {
          if (head[at + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      switch (ext) {
        case 'mp3':
        case 'aac':
          if (tag(0, 'ID3') || (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)) return null;
          return 'does not start like an MP3';
        case 'flac':
          return tag(0, 'fLaC') || tag(0, 'ID3') ? null : 'does not start like a FLAC file';
        case 'wav':
          return tag(0, 'RIFF') && tag(8, 'WAVE') ? null : 'does not start like a WAV file';
        case 'ogg':
        case 'opus':
          return tag(0, 'OggS') ? null : 'does not start like an Ogg file';
        case 'm4a':
        case 'mp4':
          return tag(4, 'ftyp') ? null : 'does not start like an M4A file';
      }
      return null;
    } catch (e) {
      return 'could not read it ($e)';
    }
  }

  static final Map<String, bool> _complete = {};

  /// Null when the whole track decodes (about as long as its header says),
  /// otherwise the reason it is incomplete. Decodes the file once, off the
  /// UI thread, and remembers the answer for the file as it is now.
  static Future<String?> incomplete(String path) async {
    try {
      final f = File(path);
      final st = await f.stat();
      final key = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
      if (_complete[key] == true) return null;
      final (header, real) = await Isolate.run(() => (fileDurationSec(path), fileDecodedSec(path)));
      if (header <= 0) return null; // unknown length: the other checks decide
      if (real >= header * 0.985 - 1.0) {
        _complete[key] = true;
        return null;
      }
      return 'incomplete: only ${real.round()} s of ${header.round()} s plays';
    } catch (_) {
      return null; // could not check: do not throw a good track away
    }
  }
}
