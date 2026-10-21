import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LogLevel { info, ok, fail }

class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.msg);
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String msg;

  String get text {
    String two(int n) => n.toString().padLeft(2, '0');
    final mark = level == LogLevel.ok ? 'OK  ' : (level == LogLevel.fail ? 'FAIL' : 'info');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)} $mark [$tag] $msg';
  }
}

/// Running tally of how often a kind of action worked or failed.
class FlowStat {
  FlowStat({this.ok = 0, this.fail = 0, this.lastFail = '', this.lastFailAt = ''});
  int ok;
  int fail;
  String lastFail;
  String lastFailAt;
  Map<String, dynamic> toJson() =>
      {'o': ok, 'f': fail, 'w': lastFail, 't': lastFailAt};
}

/// A trace of what the app is doing, for tracking down problems on the
/// phone: shown live on screen when switched on, listed in Settings, and
/// saved to a file so it survives restarts.
class DebugLog extends ChangeNotifier {
  DebugLog._();
  static final instance = DebugLog._();

  final List<LogEntry> entries = [];

  /// Success and failure counts per kind of action, kept across restarts.
  final Map<String, FlowStat> flows = {};

  /// Show the live trace panel over the app.
  bool live = false;

  /// Called whenever a failure is logged (used to send the log on).
  void Function()? onFail;

  File? _file;
  String? filePath;

  List<String> get lines => [for (final e in entries) e.text];

  static void add(String tag, String msg) {
    final bad = RegExp(r'FAIL|REJECT|cannot|could not|missing|gone|error',
            caseSensitive: false)
        .hasMatch(msg);
    _push(bad ? LogLevel.fail : LogLevel.info, tag, msg);
  }

  /// Records the outcome of one kind of action in the running tally.
  static void flow(String name, bool ok, [String why = '']) {
    final s = instance.flows.putIfAbsent(name, () => FlowStat());
    if (ok) {
      s.ok++;
    } else {
      s.fail++;
      s.lastFail = why;
      final t = DateTime.now();
      s.lastFailAt = '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    }
    instance._saveFlows();
    instance.notifyListeners();
  }

  Future<void> _saveFlows() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'flow_stats',
        jsonEncode({for (final e in flows.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {}
  }

  static void ok(String tag, String msg) => _push(LogLevel.ok, tag, msg);
  static void fail(String tag, String msg) => _push(LogLevel.fail, tag, msg);

  static void _push(LogLevel level, String tag, String msg) {
    final e = LogEntry(DateTime.now(), level, tag, msg);
    final l = instance.entries;
    l.add(e);
    if (l.length > 600) l.removeRange(0, l.length - 600);
    instance._write(e);
    if (level == LogLevel.fail) instance.onFail?.call();
    instance.notifyListeners();
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      live = prefs.getBool('live_trace') ?? false;
      final raw = prefs.getString('flow_stats');
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          final m = v as Map;
          flows[k as String] = FlowStat(
            ok: (m['o'] as num?)?.toInt() ?? 0,
            fail: (m['f'] as num?)?.toInt() ?? 0,
            lastFail: (m['w'] ?? '') as String,
            lastFailAt: (m['t'] ?? '') as String,
          );
        });
      }
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/beatdeck_test_log.txt');
      filePath = _file!.path;
      if (await _file!.exists() && await _file!.length() > 1500000) {
        await _file!.writeAsString('');
      }
      add('app', 'started');
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setLive(bool v) async {
    live = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_trace', v);
    } catch (_) {}
    notifyListeners();
  }

  void _write(LogEntry e) {
    final f = _file;
    if (f == null) return;
    f.writeAsString('${e.text}\n', mode: FileMode.append).catchError((_) => f);
  }

  void clear() {
    entries.clear();
    flows.clear();
    _saveFlows();
    try {
      _file?.writeAsStringSync('');
    } catch (_) {}
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
