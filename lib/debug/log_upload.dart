import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';

/// Sends the test log to a private GitHub issue so Claude can read it and work
/// out why something failed without anyone copying and pasting. Needs a
/// fine-grained GitHub token limited to this one repository with Issues
/// read and write access, entered once in Settings.
class LogUpload {
  static const repo = 'ben-clift/beatdeck';
  static const _title = 'BeatDeck phone logs';

  static String token = '';
  static bool auto = true;
  static String status = '';
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _timer;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      token = p.getString('gh_token') ?? '';
      auto = p.getBool('gh_auto') ?? true;
    } catch (_) {}
    // Failures are sent a little later, together, so one problem is one post.
    DebugLog.instance.onFail = _scheduleSend;
  }

  static Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('gh_token', token.trim());
      await p.setBool('gh_auto', auto);
    } catch (_) {}
  }

  static void _scheduleSend() {
    if (!auto || token.trim().isEmpty) return;
    if (DateTime.now().difference(_last).inSeconds < 90) return;
    _timer ??= Timer(const Duration(seconds: 20), () {
      _timer = null;
      send(reason: 'failure');
    });
  }

  static Map<String, String> get _h => {
        'Authorization': 'Bearer ${token.trim()}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  static Future<int?> _issue() async {
    final p = await SharedPreferences.getInstance();
    final known = p.getInt('gh_issue');
    if (known != null) return known;
    final r = await http.post(
      Uri.parse('https://api.github.com/repos/$repo/issues'),
      headers: _h,
      body: jsonEncode({
        'title': _title,
        'body': 'Logs sent from the phone by BeatDeck. Read by Claude.',
      }),
    );
    if (r.statusCode != 201) {
      status = 'GitHub said ${r.statusCode} creating the log issue';
      return null;
    }
    final n = (jsonDecode(r.body) as Map)['number'] as int;
    await p.setInt('gh_issue', n);
    return n;
  }

  static String _body(String reason) {
    final log = DebugLog.instance;
    final b = StringBuffer();
    final now = DateTime.now().toIso8601String();
    b.writeln('**$reason** at $now');
    b.writeln();
    b.writeln('Tally (ok / fail, last failure):');
    for (final e in log.flows.entries) {
      b.writeln('- ${e.key}: ${e.value.ok} / ${e.value.fail}'
          '${e.value.lastFail.isEmpty ? '' : '  last: ${e.value.lastFail}'}');
    }
    b.writeln();
    final lines = log.lines;
    final tail = lines.length > 120 ? lines.sublist(lines.length - 120) : lines;
    b.writeln('```');
    b.writeln(tail.join('\n'));
    b.writeln('```');
    final s = b.toString();
    return s.length > 60000 ? s.substring(s.length - 60000) : s;
  }

  /// Posts the current log. Returns a short result for the screen.
  static Future<String> send({String reason = 'manual'}) async {
    if (token.trim().isEmpty) return 'Add a GitHub token first';
    try {
      final n = await _issue();
      if (n == null) return status;
      final r = await http
          .post(
            Uri.parse('https://api.github.com/repos/$repo/issues/$n/comments'),
            headers: _h,
            body: jsonEncode({'body': _body(reason)}),
          )
          .timeout(const Duration(seconds: 20));
      _last = DateTime.now();
      status = r.statusCode == 201
          ? 'Sent at ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}'
          : 'GitHub said ${r.statusCode}';
    } catch (e) {
      status = 'Could not send: $e';
    }
    DebugLog.instance.notifyListeners();
    return status;
  }
}
