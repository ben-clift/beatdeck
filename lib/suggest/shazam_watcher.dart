import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';

/// Listens for Shazam results (via Android notification access) and starts
/// downloading the track and more like it.
class ShazamWatcher {
  ShazamWatcher._();
  static final ShazamWatcher instance = ShazamWatcher._();

  static const _events = EventChannel('beatdeck/shazam');
  static const _ch = MethodChannel('beatdeck/shazam_m');

  bool on = true;
  LibraryController? _lib;
  StreamSubscription<dynamic>? _sub;
  final List<String> recent = [];

  Future<void> start(LibraryController lib) async {
    _lib = lib;
    try {
      on = (await SharedPreferences.getInstance()).getBool('shazam_on') ?? true;
    } catch (_) {}
    _sub ??= _events.receiveBroadcastStream().listen(
      (e) => _handle(e),
      onError: (_) {},
    );
    await drain();
  }

  Future<void> setOn(bool v) async {
    on = v;
    try {
      (await SharedPreferences.getInstance()).setBool('shazam_on', v);
    } catch (_) {}
  }

  Future<bool> accessGranted() async {
    try {
      return (await _ch.invokeMethod<bool>('enabled')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAccessSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// Shazams made while the app was closed.
  Future<void> drain() async {
    try {
      final l = await _ch.invokeMethod<List<dynamic>>('drain');
      for (final e in l ?? const []) {
        _handle(e);
      }
    } catch (_) {}
  }

  void _handle(dynamic e) {
    if (!on || e is! Map) return;
    final title = (e['title'] ?? '').toString().trim();
    final artist = (e['artist'] ?? '').toString().trim();
    final lib = _lib;
    if (title.isEmpty || lib == null) return;
    final label = '$artist - $title';
    if (recent.contains(label)) return;
    recent.insert(0, label);
    if (recent.length > 20) recent.removeLast();
    DebugLog.add('shazam', 'Shazam found $label: fetching it and tracks like it');
    AutoFetch.instance.shazamFetch(artist, title, lib);
  }
}
