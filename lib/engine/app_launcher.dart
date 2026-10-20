import 'package:flutter/services.dart';

/// Opens another installed app by its name on the launcher (used for Seeker).
class AppLauncher {
  static const _ch = MethodChannel('sidedeck/audio');

  /// True when an app with a matching name was found and opened.
  static Future<bool> openByName(String name) async {
    try {
      final ok = await _ch.invokeMethod<bool>('openAppByName', {'name': name});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
