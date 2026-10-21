import 'dart:io';

import 'package:flutter/foundation.dart';

/// A short in-app log for tracking down problems on the phone itself.
class DebugLog extends ChangeNotifier {
  DebugLog._();
  static final instance = DebugLog._();

  final List<String> lines = [];

  static void add(String tag, String msg) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final line = '${two(t.hour)}:${two(t.minute)}:${two(t.second)} [$tag] $msg';
    final l = instance.lines;
    l.add(line);
    if (l.length > 400) l.removeRange(0, l.length - 400);
    instance.notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  /// What can be said about a file: exists, size, first bytes, folder rights.
  static Future<String> describeFile(String path) async {
    final f = File(path);
    final b = StringBuffer();
    try {
      final ex = await f.exists();
      b.write(ex ? 'exists' : 'MISSING');
      if (ex) {
        final st = await f.stat();
        b.write(', ${st.size} bytes, modified ${st.modified.toIso8601String()}');
        try {
          final raf = await f.open();
          final head = await raf.read(8);
          await raf.close();
          b.write(', Dart read ${head.length} bytes: '
              '${head.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ')}');
        } catch (e) {
          b.write(', Dart could NOT read it: $e');
        }
      }
    } catch (e) {
      b.write('check failed: $e');
    }
    return b.toString();
  }
}
