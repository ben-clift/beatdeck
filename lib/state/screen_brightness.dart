import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's own screen brightness: System (the phone's setting), Low, Medium
/// or High. A lower screen saves a lot of battery.
class ScreenBrightness {
  static const _ch = MethodChannel('sidedeck/audio');
  static const _key = 'screen_brightness_v1';

  /// 0 = System, 1 = Low, 2 = Medium, 3 = High.
  static int level = 0;

  /// True on Low: the spectrum and all animated scenes switch off too, to save
  /// battery. Screens listen to this to hide their animations.
  static final ValueNotifier<bool> lowPower = ValueNotifier<bool>(false);
  static const _values = [-1.0, 0.15, 0.45, 0.85];

  static Future<void> load() async {
    try {
      level = (await SharedPreferences.getInstance()).getInt(_key) ?? 0;
    } catch (_) {}
    await apply();
  }

  static Future<void> set(int l) async {
    level = l.clamp(0, 3);
    try {
      await (await SharedPreferences.getInstance()).setInt(_key, level);
    } catch (_) {}
    await apply();
  }

  static Future<void> apply() async {
    lowPower.value = level == 1;
    try {
      await _ch.invokeMethod('setBrightness', {'value': _values[level]});
    } catch (_) {}
  }
}
