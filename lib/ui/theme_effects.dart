import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';

/// Themed scenery drifting over the decks: ocean, jungle, neon, fire, sakura,
/// snow and UFOs. See-through, ignores touches, chosen in Customise look.
class ThemeEffects extends StatefulWidget {
  const ThemeEffects({super.key, required this.dj});

  final DjController dj;

  @override
  State<ThemeEffects> createState() => _ThemeEffectsState();
}

enum _K { fish, jelly, bubble, firefly, leaf, sun, laser, ember, petal, flake, ufo }

class _Item {
  _Item(this.kind, this.x, this.y, this.vx, this.vy, this.size, this.life, this.hue, this.seed)
      : maxLife = life;

  final _K kind;
  double x, y, vx, vy, life;
  final double size, maxLife, hue, seed;
  double age = 0;

  double get envelope {
    final t = (age / maxLife).clamp(0.0, 1.0);
    if (t < 0.15) return math.sin(t / 0.15 * math.pi / 2);
    if (t > 0.8) return math.cos((t - 0.8) / 0.2 * math.pi / 2);
    return 1.0;
  }
}

class _ThemeEffectsState extends State<ThemeEffects> with SingleTickerProviderStateMixin {
  final _look = LookController.instance;
  final _rnd = math.Random();
  final _items = <_Item>[];
  final _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _next = 1.0;
  double _clock = 0;
  double _frame = 0;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _look.addListener(_onLook);
    _ticker = createTicker(_onTick)..start();
  }

  void _onLook() {
    if (!_look.themeOn || _look.themeMask == 0) _items.clear();
  }

  @override
  void dispose() {
    _look.removeListener(_onLook);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  List<int> get _groups => [for (final b in const [1, 2, 4, 8, 16, 32, 64]) if (_look.themeMask & b != 0) b];

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;
    if (!_look.themeOn || _size.isEmpty) return;
    _clock += dt;
    for (final i in _items) {
      i.age += dt;
      i.life -= dt;
      i.x += i.vx * dt;
      i.y += i.vy * dt;
      if (i.kind == _K.firefly || i.kind == _K.petal || i.kind == _K.flake || i.kind == _K.leaf) {
        i.x += math.sin(_clock * 1.3 + i.seed * 9) * 14 * dt;
      }
    }
    _items.removeWhere((i) => i.life <= 0);
    final g = _groups;
    if (g.isEmpty) return;
    _next -= dt;
    if (_next <= 0 && _items.length < 24) {
      _spawn(g[_rnd.nextInt(g.length)]);
      _next = 3 + _rnd.nextDouble() * 6;
    } else if (_next <= 0) {
      _next = 2;
    }
    _frame += dt;
    if (_frame >= 1 / 30 && _items.isNotEmpty) {
      _frame = 0;
      _repaint.value++;
    }
  }

  double _r(double a, double b) => a + _rnd.nextDouble() * (b - a);

  void _spawn(int group) {
    final w = _size.width, h = _size.height;
    void add(_K k, double x, double y, double vx, double vy, double size, double life, double hue) {
      _items.add(_Item(k, x, y, vx, vy, size, life, hue, _rnd.nextDouble()));
    }

    switch (group) {
      case 1: // ocean
        final what = _rnd.nextInt(3);
        if (what == 0) {
          final dir = _rnd.nextBool() ? 1.0 : -1.0;
          final y0 = _r(h * 0.15, h * 0.85);
          final hue = _r(170, 220);
          for (var n = 0; n < 4; n++) {
            add(_K.fish, dir > 0 ? -40.0 - n * 38 : w + 40 + n * 38, y0 + _r(-30, 30),
                dir * _r(50, 70), _r(-4, 4), _r(16, 24), 16, hue);
          }
        } else if (what == 1) {
          add(_K.jelly, _r(w * 0.1, w * 0.9), h + 40, 0, -_r(14, 24), _r(34, 56), 18, _r(280, 330));
        } else {
          final x0 = _r(w * 0.1, w * 0.9);
          for (var n = 0; n < 7; n++) {
            add(_K.bubble, x0 + _r(-30, 30), h + _r(0, 60), 0, -_r(30, 60), _r(4, 11), 10, 190);
          }
        }
      case 2: // jungle
        if (_rnd.nextBool()) {
          final cx = _r(w * 0.1, w * 0.9), cy = _r(h * 0.2, h * 0.8);
          for (var n = 0; n < 9; n++) {
            add(_K.firefly, cx + _r(-70, 70), cy + _r(-50, 50), _r(-8, 8), _r(-8, 8), _r(2.5, 4.5), _r(9, 15), 70);
          }
        } else {
          for (var n = 0; n < 3; n++) {
            add(_K.leaf, _r(0, w), -30.0 - n * 40, _r(-10, 10), _r(26, 42), _r(14, 22), 14, _r(95, 140));
          }
        }
      case 4: // neon
        if (_rnd.nextBool()) {
          add(_K.sun, _r(w * 0.25, w * 0.75), _r(h * 0.35, h * 0.6), 0, -3, _r(110, 170), 16, 0);
        } else {
          add(_K.laser, _rnd.nextBool() ? 0 : w, 0, 0, 0, h * 1.3, 9, _r(0, 360));
        }
      case 8: // fire
        final x0 = _r(w * 0.1, w * 0.9);
        for (var n = 0; n < 12; n++) {
          add(_K.ember, x0 + _r(-60, 60), h + _r(0, 40), _r(-12, 12), -_r(40, 90), _r(2, 4.5), _r(5, 9), _r(10, 40));
        }
      case 16: // sakura
        for (var n = 0; n < 7; n++) {
          add(_K.petal, _r(0, w), -20.0 - n * 30, _r(-8, 12), _r(22, 38), _r(6, 10), 15, _r(335, 350));
        }
      case 32: // snow
        for (var n = 0; n < 14; n++) {
          add(_K.flake, _r(0, w), -10.0 - n * 20, _r(-6, 6), _r(18, 36), _r(2, 5.5), 15, 200);
        }
      case 64: // ufo
        final dir = _rnd.nextBool() ? 1.0 : -1.0;
        add(_K.ufo, dir > 0 ? -60 : w + 60, _r(h * 0.12, h * 0.4), dir * _r(70, 110), _r(-3, 3), _r(34, 50), 12, _r(90, 140));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _ThemePainter(_items, _repaint, () => _clock),
          ),
        );
      }),
    );
  }
}

class _ThemePainter extends CustomPainter {
  _ThemePainter(this.items, Listenable repaint, this.clock) : super(repaint: repaint);

  final List<_Item> items;
  final double Function() clock;

  Color _c(double hue, double a, {double s = 0.8, double l = 0.6}) =>
      HSLColor.fromAHSL(a.clamp(0.0, 1.0), hue % 360, s, l).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock();
    for (final i in items) {
      final e = i.envelope;
      switch (i.kind) {
        case _K.fish:
          _fish(canvas, i, e, t);
        case _K.jelly:
          _jelly(canvas, i, e, t);
        case _K.bubble:
          canvas.drawCircle(
              Offset(i.x, i.y),
              i.size,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..color = _c(i.hue, 0.5 * e, s: 0.6, l: 0.8));
        case _K.firefly:
          final pulse = 0.5 + 0.5 * math.sin(t * 3 + i.seed * 20);
          final p = Offset(i.x, i.y);
          canvas.drawCircle(p, i.size * 3.2,
              Paint()..color = _c(i.hue, 0.18 * e * pulse, l: 0.6)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
          canvas.drawCircle(p, i.size * 0.7, Paint()..color = _c(i.hue, 0.9 * e * pulse, l: 0.8));
        case _K.leaf:
          _leaf(canvas, i, e, t);
        case _K.sun:
          _sun(canvas, i, e);
        case _K.laser:
          _laser(canvas, i, e, t);
        case _K.ember:
          final p = Offset(i.x, i.y);
          final a = e * (0.4 + 0.6 * (i.life / i.maxLife));
          canvas.drawCircle(p, i.size * 2.6,
              Paint()..color = _c(i.hue, 0.22 * a, l: 0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
          canvas.drawCircle(p, i.size * 0.8, Paint()..color = _c(i.hue + 10, 0.95 * a, l: 0.62));
        case _K.petal:
          canvas.save();
          canvas.translate(i.x, i.y);
          canvas.rotate(t * 1.2 + i.seed * 6);
          canvas.scale(1, 0.55 + 0.45 * math.sin(t * 2 + i.seed * 9).abs());
          canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: i.size * 1.8, height: i.size),
              Paint()..color = _c(i.hue, 0.75 * e, s: 0.75, l: 0.82));
          canvas.restore();
        case _K.flake:
          canvas.drawCircle(Offset(i.x, i.y), i.size, Paint()..color = Colors.white.withValues(alpha: 0.7 * e));
        case _K.ufo:
          _ufo(canvas, i, e, t);
      }
    }
  }

  void _fish(Canvas c, _Item i, double e, double t) {
    final dir = i.vx >= 0 ? 1.0 : -1.0;
    c.save();
    c.translate(i.x, i.y);
    c.scale(dir, 1);
    final s = i.size;
    final body = Paint()..color = _c(i.hue, 0.7 * e, l: 0.55);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: s * 2, height: s), body);
    final wag = math.sin(t * 9 + i.seed * 10) * s * 0.25;
    final tail = Path()
      ..moveTo(-s * 0.9, 0)
      ..lineTo(-s * 1.6, -s * 0.5 + wag)
      ..lineTo(-s * 1.6, s * 0.5 + wag)
      ..close();
    c.drawPath(tail, body);
    c.drawCircle(Offset(s * 0.55, -s * 0.1), s * 0.09, Paint()..color = Colors.white.withValues(alpha: 0.9 * e));
    c.restore();
  }

  void _jelly(Canvas c, _Item i, double e, double t) {
    final pulse = 1 + 0.12 * math.sin(t * 2.6 + i.seed * 8);
    final s = i.size;
    final col = _c(i.hue, 0.5 * e, s: 0.7, l: 0.7);
    c.save();
    c.translate(i.x, i.y);
    c.drawArc(Rect.fromCenter(center: Offset.zero, width: s * pulse, height: s * 0.8 * pulse), math.pi, math.pi, true,
        Paint()..color = col);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = _c(i.hue, 0.4 * e, l: 0.75);
    for (var k = -2; k <= 2; k++) {
      final p = Path()..moveTo(k * s * 0.17, 0);
      for (var j = 1; j <= 5; j++) {
        p.lineTo(k * s * 0.17 + math.sin(t * 3 + j + k + i.seed * 5) * 4, j * s * 0.2);
      }
      c.drawPath(p, line);
    }
    c.restore();
  }

  void _leaf(Canvas c, _Item i, double e, double t) {
    c.save();
    c.translate(i.x, i.y);
    c.rotate(math.sin(t + i.seed * 7) * 0.9 + i.seed * 3);
    final s = i.size;
    final p = Path()
      ..moveTo(0, -s)
      ..quadraticBezierTo(s * 0.8, -s * 0.2, 0, s)
      ..quadraticBezierTo(-s * 0.8, -s * 0.2, 0, -s);
    c.drawPath(p, Paint()..color = _c(i.hue, 0.6 * e, s: 0.6, l: 0.4));
    c.drawLine(Offset(0, -s), Offset(0, s),
        Paint()..strokeWidth = 1..color = _c(i.hue, 0.5 * e, l: 0.7));
    c.restore();
  }

  void _sun(Canvas c, _Item i, double e) {
    final r = i.size;
    final rect = Rect.fromCircle(center: Offset(i.x, i.y), radius: r);
    final shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFE066), Color(0xFFFF4FA3), Color(0xFF7A3CFF)],
    ).createShader(rect);
    c.saveLayer(rect.inflate(4), Paint()..color = Colors.white.withValues(alpha: 0.45 * e));
    c.drawCircle(Offset(i.x, i.y), r, Paint()..shader = shader);
    // Slits cut into the lower half: the classic retro sun.
    final cut = Paint()..blendMode = BlendMode.clear;
    for (var k = 0; k < 6; k++) {
      final y = i.y + r * (0.05 + k * 0.17);
      c.drawRect(Rect.fromLTWH(i.x - r, y, r * 2, 2.0 + k * 1.3), cut);
    }
    c.restore();
  }

  void _laser(Canvas c, _Item i, double e, double t) {
    final fromLeft = i.x <= 1;
    for (var k = 0; k < 5; k++) {
      final base = fromLeft ? 0.25 : math.pi - 0.25;
      final ang = base + (fromLeft ? 1 : -1) * (0.15 + 0.5 * (0.5 + 0.5 * math.sin(t * 0.9 + k * 0.8 + i.seed * 5)));
      final end = Offset(i.x + math.cos(ang) * i.size, math.sin(ang) * i.size);
      c.drawLine(Offset(i.x, 0), end,
          Paint()
            ..strokeWidth = 2
            ..color = _c(i.hue + k * 40, 0.5 * e, l: 0.6)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    }
  }

  void _ufo(Canvas c, _Item i, double e, double t) {
    final s = i.size;
    c.save();
    c.translate(i.x, i.y + math.sin(t * 2 + i.seed * 6) * 6);
    final beam = Path()
      ..moveTo(-s * 0.25, s * 0.2)
      ..lineTo(-s * 0.7, s * 2.2)
      ..lineTo(s * 0.7, s * 2.2)
      ..lineTo(s * 0.25, s * 0.2)
      ..close();
    c.drawPath(beam, Paint()..color = _c(i.hue, 0.12 * e, l: 0.7));
    c.drawOval(Rect.fromCenter(center: Offset(0, 0), width: s * 2, height: s * 0.55),
        Paint()..color = const Color(0xFFB8C4D6).withValues(alpha: 0.75 * e));
    c.drawArc(Rect.fromCenter(center: Offset(0, -s * 0.1), width: s * 0.9, height: s * 0.8), math.pi, math.pi, true,
        Paint()..color = _c(i.hue, 0.6 * e, l: 0.6));
    for (var k = -2; k <= 2; k++) {
      final on = ((t * 4).floor() + k) % 2 == 0;
      c.drawCircle(Offset(k * s * 0.32, s * 0.02), s * 0.05,
          Paint()..color = (on ? Colors.yellowAccent : Colors.redAccent).withValues(alpha: 0.9 * e));
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _ThemePainter old) => true;
}
