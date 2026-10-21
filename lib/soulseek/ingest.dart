import 'dart:io';

import 'package:sidedeck/engine/track_analyzer.dart';

/// Checks a finished download before it is allowed to count: the file is
/// there, is the size promised, and the audio decoder can open it. Returns
/// null when it is good, otherwise the reason it is not.
Future<String?> verifyDownload(String path, int expectedSize) async {
  final f = File(path);
  try {
    if (!await f.exists()) return 'The saved file is missing';
    final len = await f.length();
    if (len == 0) return 'The saved file is empty';
    if (expectedSize > 0 && len != expectedSize) {
      return 'Incomplete: $len of $expectedSize bytes saved';
    }
    if (fileDurationSec(path) <= 0) return 'The decoder cannot open this file';
  } catch (e) {
    return 'Could not check the file: $e';
  }
  return null;
}
