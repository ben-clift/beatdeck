import 'package:flutter/material.dart';

class SideDeckTheme {
  static const bg = Color(0xFF1C1B19);
  static const panel = Color(0xFF262522);
  static const panelAlt = Color(0xFF34322E);
  static const accentA = Color(0xFFF2A33A);
  static const accentB = Color(0xFF3FB6A8);
  static const accentC = Color(0xFF8FA8E8);
  static const accentD = Color(0xFFE07A8C);
  static const text = Color(0xFFECE8E1);
  static const muted = Color(0xFF9A958B);

  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentA,
        brightness: Brightness.dark,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    );
  }
}
