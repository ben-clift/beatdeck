import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the controller is finished, on top of the colours.
enum LookStyle {
  matte('Matte', 'Flat and calm'),
  neon('Neon glow', 'Glowing outlines and a lit jog wheel'),
  sparkle('Sparkle', 'Twinkling stars drifting behind the decks'),
  aurora('Aurora', 'Slow moving glows of your deck colours'),
  chrome('Chrome', 'Brushed metal panels with a shine');

  const LookStyle(this.label, this.blurb);

  final String label;
  final String blurb;

  bool get animated => this == sparkle || this == aurora || this == neon;
}

/// Shape of the drifting particles in the Sparkle style.
enum LookShape {
  star('Stars'),
  heart('Hearts'),
  diamond('Diamonds'),
  bubble('Bubbles'),
  twinkle('Twinkles'),
  mixed('Mixed');

  const LookShape(this.label);

  final String label;
}

class LookOption {
  const LookOption(this.name, this.color);

  final String name;
  final Color color;
}

/// The look of the controller screen: background, controller body and one
/// colour per deck. Saved on the phone. Defaults are the matte look.
class LookController extends ChangeNotifier {
  LookController._();

  static final LookController instance = LookController._();

  /// Gentle colours behind the controller.
  static const backgrounds = [
    LookOption('Graphite', Color(0xFF1C1B19)),
    LookOption('Soft black', Color(0xFF111112)),
    LookOption('Warm charcoal', Color(0xFF22201D)),
    LookOption('Slate', Color(0xFF1B2028)),
    LookOption('Midnight', Color(0xFF151B2B)),
    LookOption('Forest', Color(0xFF17201B)),
    LookOption('Plum dusk', Color(0xFF211B26)),
    LookOption('Mocha', Color(0xFF241E1A)),
    LookOption('Stone', Color(0xFF2D2C2A)),
    LookOption('Fog', Color(0xFF33383F)),
    LookOption('Sage', Color(0xFF2A332C)),
    LookOption('Dusk rose', Color(0xFF2E2327)),
  ];

  /// Colours for the controller itself (deck and mixer panels).
  static const bodies = [
    LookOption('Matte graphite', Color(0xFF262522)),
    LookOption('Steel', Color(0xFF2A2F37)),
    LookOption('Espresso', Color(0xFF2E2622)),
    LookOption('Forest', Color(0xFF232B26)),
    LookOption('Plum', Color(0xFF2A2430)),
    LookOption('Ink', Color(0xFF17181B)),
    LookOption('Slate blue', Color(0xFF252C3A)),
    LookOption('Clay', Color(0xFF33292A)),
    LookOption('Olive', Color(0xFF2B2D22)),
    LookOption('Charcoal blue', Color(0xFF20262D)),
    LookOption('Warm grey', Color(0xFF353330)),
    LookOption('Black', Color(0xFF0D0D0E)),
  ];

  /// Deck accent colours.
  static const accents = [
    LookOption('Amber', Color(0xFFF2A33A)),
    LookOption('Teal', Color(0xFF3FB6A8)),
    LookOption('Sky', Color(0xFF8FA8E8)),
    LookOption('Rose', Color(0xFFE07A8C)),
    LookOption('Lime', Color(0xFFA8D86E)),
    LookOption('Violet', Color(0xFFA58BE8)),
    LookOption('Coral', Color(0xFFF07F5E)),
    LookOption('Cyan', Color(0xFF4CC9F0)),
    LookOption('Magenta', Color(0xFFF72585)),
    LookOption('Mint', Color(0xFF7FE3B0)),
    LookOption('Gold', Color(0xFFE9C46A)),
    LookOption('Ice', Color(0xFFD6E4F0)),
  ];

  static const _defaultAccents = [0, 1, 2, 3];

  LookStyle style = LookStyle.matte;
  LookShape particleShape = LookShape.mixed;

  /// Smoke when the sound hits the red, and streamers on the hardest peaks.
  bool smokeOn = true;
  bool streamersOn = true;

  /// Bumped to fire the effects once, for trying them out.
  final ValueNotifier<int> testTrigger = ValueNotifier<int>(0);
  int backgroundIndex = 0;
  int bodyIndex = 0;
  final List<int> deckAccent = List<int>.of(_defaultAccents);

  Color get bg => backgrounds[backgroundIndex].color;
  Color get body => bodies[bodyIndex].color;
  Color accent(int deck) => accents[deckAccent[deck]].color;

  // Shades worked out from the body colour so every choice stays readable.
  Color get well => Color.lerp(body, Colors.black, 0.55)!;
  Color get control => Color.lerp(body, Colors.white, 0.08)!;
  Color get controlHigh => Color.lerp(body, Colors.white, 0.18)!;
  Color get knobBase => Color.lerp(body, Colors.white, 0.10)!;
  Color get knobFace => Color.lerp(body, Colors.white, 0.20)!;

  /// Panel look for the current style. [accent] tints glows and edges.
  BoxDecoration panelDecoration(Color accent) {
    switch (style) {
      case LookStyle.matte:
        return BoxDecoration(
          color: body,
          borderRadius: BorderRadius.circular(4),
        );
      case LookStyle.neon:
        return BoxDecoration(
          color: Color.lerp(body, Colors.black, 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.9), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.45),
              blurRadius: 16,
              spreadRadius: 0.5,
            ),
          ],
        );
      case LookStyle.sparkle:
        return BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(body, accent, 0.16)!,
              body,
              Color.lerp(body, accent, 0.08)!,
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        );
      case LookStyle.aurora:
        return BoxDecoration(
          color: body.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        );
      case LookStyle.chrome:
        return BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(body, Colors.white, 0.28)!,
              Color.lerp(body, Colors.white, 0.06)!,
              Color.lerp(body, Colors.black, 0.25)!,
              Color.lerp(body, Colors.white, 0.10)!,
            ],
            stops: const [0, 0.45, 0.55, 1],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
        );
    }
  }

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      backgroundIndex =
          _clamp(prefs.getInt('look_bg') ?? 0, backgrounds.length);
      bodyIndex = _clamp(prefs.getInt('look_body') ?? 0, bodies.length);
      particleShape = LookShape.values[_clamp(prefs.getInt('look_shape') ?? 5, LookShape.values.length)];
      smokeOn = prefs.getBool('look_smoke') ?? true;
      streamersOn = prefs.getBool('look_streamers') ?? true;
      style = LookStyle.values[_clamp(prefs.getInt('look_style') ?? 0, LookStyle.values.length)];
      final saved = prefs.getStringList('look_decks');
      if (saved != null && saved.length == deckAccent.length) {
        for (var i = 0; i < saved.length; i++) {
          deckAccent[i] =
              _clamp(int.tryParse(saved[i]) ?? _defaultAccents[i], accents.length);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  int _clamp(int v, int length) => v < 0 || v >= length ? 0 : v;

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('look_bg', backgroundIndex);
      await prefs.setInt('look_body', bodyIndex);
      await prefs.setInt('look_style', style.index);
      await prefs.setInt('look_shape', particleShape.index);
      await prefs.setBool('look_smoke', smokeOn);
      await prefs.setBool('look_streamers', streamersOn);
      await prefs.setStringList('look_decks', [for (final a in deckAccent) '$a']);
    } catch (_) {}
  }

  void setParticleShape(LookShape value) {
    particleShape = value;
    notifyListeners();
    _save();
  }

  void setSmoke(bool on) {
    smokeOn = on;
    notifyListeners();
    _save();
  }

  void setStreamers(bool on) {
    streamersOn = on;
    notifyListeners();
    _save();
  }

  void testEffects() => testTrigger.value++;

  void setStyle(LookStyle value) {
    style = value;
    notifyListeners();
    _save();
  }

  void setBackground(int i) {
    backgroundIndex = i;
    notifyListeners();
    _save();
  }

  void setBody(int i) {
    bodyIndex = i;
    notifyListeners();
    _save();
  }

  void setDeckAccent(int deck, int i) {
    deckAccent[deck] = i;
    notifyListeners();
    _save();
  }

  void reset() {
    style = LookStyle.matte;
    particleShape = LookShape.mixed;
    smokeOn = true;
    streamersOn = true;
    backgroundIndex = 0;
    bodyIndex = 0;
    for (var i = 0; i < deckAccent.length; i++) {
      deckAccent[i] = _defaultAccents[i];
    }
    notifyListeners();
    _save();
  }
}
