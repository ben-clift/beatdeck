import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';

/// Keeps Soulseek signed in: connects when the app starts, reconnects when the
/// connection drops (waiting a little longer after each failed try), and tries
/// again at once when the app comes back to the front. Signing out by hand
/// turns it off until you sign in again.
class SlskKeeper extends ChangeNotifier with WidgetsBindingObserver {
  SlskKeeper._();
  static final SlskKeeper instance = SlskKeeper._();

  bool enabled = true;
  bool _started = false;
  Timer? _timer;
  int _fails = 0;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  bool _trying = false;

  /// What it is doing, for the panel.
  String note = '';

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool('slsk_auto') ?? true;
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this);
    soulseek.addListener(_onChange);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
    _tick();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      (await SharedPreferences.getInstance()).setBool('slsk_auto', v);
    } catch (_) {}
    if (v) {
      soulseek.manualDisconnect = false;
      _fails = 0;
      _next = DateTime.fromMillisecondsSinceEpoch(0);
      _tick();
    } else {
      note = '';
    }
    notifyListeners();
  }

  /// True when a user name and password are saved.
  Future<bool> hasLogin() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getString('slsk_user') ?? '').isNotEmpty &&
          (p.getString('slsk_pass') ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _onChange() {
    if (soulseek.online) {
      _fails = 0;
      note = 'Connected';
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fails = 0;
      _next = DateTime.fromMillisecondsSinceEpoch(0);
      _tick();
    }
  }

  Future<void> _tick() async {
    if (!enabled || _trying) return;
    if (soulseek.manualDisconnect || soulseek.status != SlskStatus.offline) return;
    // Wrong name or password: do not keep trying, the server may block it.
    if ((soulseek.error ?? '').startsWith('Sign in failed')) {
      note = 'Sign in failed, check your name and password';
      notifyListeners();
      return;
    }
    // Signed in somewhere else: reconnecting only kicks the other one off and
    // they take turns forever. Wait a few minutes between tries.
    final k = soulseek.kickedAt;
    if (k != null && DateTime.now().difference(k).inMinutes < 5) {
      note = 'This account is signed in on another device or app. Close it there.';
      notifyListeners();
      return;
    }
    if (DateTime.now().isBefore(_next)) return;
    _trying = true;
    try {
      final p = await SharedPreferences.getInstance();
      final u = p.getString('slsk_user') ?? '';
      final pw = p.getString('slsk_pass') ?? '';
      if (u.isEmpty || pw.isEmpty) {
        note = 'Sign in once to use auto-connect';
        notifyListeners();
        return;
      }
      final waits = [5, 10, 20, 40, 60];
      _next = DateTime.now().add(Duration(seconds: waits[_fails.clamp(0, waits.length - 1)]));
      _fails++;
      note = _fails <= 1 ? 'Connecting…' : 'Reconnecting (try $_fails)…';
      notifyListeners();
      DebugLog.add('soulseek', 'auto-connect: $note');
      await soulseek.connect(u, pw);
    } catch (_) {
    } finally {
      _trying = false;
    }
  }
}
