import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _StatvfsC = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatvfsD = int Function(Pointer<Utf8>, Pointer<Uint8>);

/// Keeps downloads from filling the phone: a cap on how much space the
/// download folder may use, and an amount of free space that is always left.
class StorageGuard {
  static const _gb = 1024 * 1024 * 1024;

  /// Most the download folder may hold, in GB.
  static double maxGb = 5;

  /// Free space on the phone that downloads must never eat into, in GB.
  static double reserveGb = 3;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      maxGb = prefs.getDouble('dl_max_gb') ?? maxGb;
      reserveGb = prefs.getDouble('dl_reserve_gb') ?? reserveGb;
      // A big reserve stops every download on a phone with space to spare.
      if (reserveGb > 5) {
        reserveGb = 5;
        await prefs.setDouble('dl_reserve_gb', reserveGb);
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('dl_max_gb', maxGb);
      await prefs.setDouble('dl_reserve_gb', reserveGb);
    } catch (_) {}
  }

  static int _cachedUsed = 0;
  static String _cachedDir = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bytes in the download folder (cached for a few seconds).
  static Future<int> usedBytes(String dir) async {
    if (dir == _cachedDir &&
        DateTime.now().difference(_cachedAt).inSeconds < 10) {
      return _cachedUsed;
    }
    var total = 0;
    try {
      final d = Directory(dir);
      if (await d.exists()) {
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    _cachedUsed = total;
    _cachedDir = dir;
    _cachedAt = DateTime.now();
    return total;
  }

  /// Free bytes on the volume holding [path], or null when unknown.
  static int? freeBytes(String path) {
    try {
      if (Abi.current() != Abi.androidArm64) return null;
      final f = DynamicLibrary.process()
          .lookupFunction<_StatvfsC, _StatvfsD>('statvfs');
      final p = path.toNativeUtf8();
      final buf = malloc<Uint8>(256);
      try {
        if (f(p, buf) != 0) return null;
        final v = buf.cast<Uint64>();
        return v[1] * v[4]; // fragment size x blocks available to apps
      } finally {
        malloc.free(p);
        malloc.free(buf);
      }
    } catch (_) {
      return null;
    }
  }

  /// A reason not to download [incoming] more bytes, or null when it is fine.
  static Future<String?> blockReason(String dir, int incoming) async {
    final used = await usedBytes(dir);
    if (used + incoming > maxGb * _gb) {
      return 'Storage limit reached: ${(used / _gb).toStringAsFixed(1)} GB used '
          'of ${maxGb.toStringAsFixed(0)} GB allowed';
    }
    final free = freeBytes(dir);
    if (free != null && free - incoming < reserveGb * _gb) {
      return 'Phone space is low: ${(free / _gb).toStringAsFixed(1)} GB free, '
          'keeping ${reserveGb.toStringAsFixed(0)} GB spare';
    }
    return null;
  }

  static String usageLine(String dir) {
    final free = freeBytes(dir);
    return '${(_cachedUsed / _gb).toStringAsFixed(1)} GB used by downloads'
        '${free == null ? '' : '  ·  ${(free / _gb).toStringAsFixed(1)} GB free on the phone'}';
  }
}
