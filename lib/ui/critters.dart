import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sidedeck/state/look_controller.dart';

/// Now and then an animal walks across the screen over the decks: big cats,
/// farm animals, pets, and snakes, frogs and insects. Not many at once, at
/// random moments, see-through to touches.
class CritterEffects extends StatefulWidget {
  const CritterEffects({super.key});

  @override
  State<CritterEffects> createState() => _CritterEffectsState();
}

enum _A { lion, tiger, sheep, goat, cat, dog, snake, frog, beetle, ant, spider }

class _Critter {
  _Critter({
    required this.kind,
    required this.x,
    required this.y,
    required this.dir,
    required this.speed,
    required this.size,
    required this.hue,
  });

  final _A kind;
  double x, y;
  final double dir; // 1 walks right, -1 walks left
  final double speed;
  final double size;
  final double hue;
  double age = 0;
  double dist = 0; // distance walked, drives the legs
}

class _CritterEffectsState extends State<CritterEffects>
    with SingleTickerProviderStateMixin {
  final _look = LookController.instance;
  final _rnd = math.Random();
  final _things = <_Critter>[];
  final _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _next = 4;
  double _frame = 0;
  double _clock = 0;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _look.addListener(_onLook);
    _ticker = createTicker(_onTick)..start();
  }

  void _onLook() {
    if (!_look.critterOn) _things.clear();
  }

  @override
  void dispose() {
    _look.removeListener(_onLook);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  List<_A> get _allowed {
    final m = _look.critterMask;
    return [
      if (m & 1 != 0) ...[_A.lion, _A.tiger],
      if (m & 2 != 0) ...[_A.sheep, _A.goat],
      if (m & 4 != 0) ...[_A.cat, _A.dog],
      if (m & 8 != 0) ...[_A.snake, _A.frog, _A.beetle, _A.ant, _A.spider],
    ];
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;
    if (!_look.critterOn || _size.isEmpty) return;
    _clock += dt;
    final w = _size.width;

    for (final t in _things) {
      t.age += dt;
      var v = t.speed;
      if (t.kind == _A.frog) {
        // sit, then hop
        final c = (t.age % 1.5) / 1.5;
        v = c > 0.55 ? t.speed * 2.2 : 0;
      }
      t.x += t.dir * v * dt;
      t.dist += v * dt;
    }
    _things.removeWhere((t) => t.dir > 0 ? t.x > w + t.size * 2 : t.x < -t.size * 2);

    _next -= dt;
    if (_next <= 0) {
      final allowed = _allowed;
      if (allowed.isNotEmpty && _things.length < 2) _spawn(allowed);
      _next = 9 + _rnd.nextDouble() * 24;
    }

    _frame += dt;
    if (_frame >= 1 / 30 && _things.isNotEmpty) {
      _frame = 0;
      _repaint.value++;
    }
  }

  void _spawn(List<_A> allowed) {
    final w = _size.width;
    final h = _size.height;
    final k = allowed[_rnd.nextInt(allowed.length)];
    final dir = _rnd.nextBool() ? 1.0 : -1.0;
    final (size, speed) = switch (k) {
      _A.lion => (80.0, 70.0),
      _A.tiger => (84.0, 80.0),
      _A.sheep => (66.0, 38.0),
      _A.goat => (64.0, 52.0),
      _A.cat => (52.0, 70.0),
      _A.dog => (62.0, 85.0),
      _A.snake => (110.0, 60.0),
      _A.frog => (34.0, 40.0),
      _A.beetle => (24.0, 22.0),
      _A.ant => (20.0, 32.0),
      _A.spider => (28.0, 46.0),
    };
    final sc = 0.85 + _rnd.nextDouble() * 0.4;
    _things.add(_Critter(
      kind: k,
      x: dir > 0 ? -size * 1.6 : w + size * 1.6,
      y: h * (0.25 + _rnd.nextDouble() * 0.68),
      dir: dir,
      speed: speed * (0.8 + _rnd.nextDouble() * 0.4),
      size: size * sc,
      hue: _rnd.nextDouble() * 360,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, c) {
            _size = Size(c.maxWidth, c.maxHeight);
            return CustomPaint(painter: _CritterPainter(this, _repaint), size: Size.infinite);
          },
        ),
      ),
    );
  }
}

class _CritterPainter extends CustomPainter {
  _CritterPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _CritterEffectsState s;

  static const double _alpha = 0.88;

  Paint _fill(Color c) => Paint()..color = c.withValues(alpha: _alpha);
  Paint _line(Color c, double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = w
    ..color = c.withValues(alpha: _alpha);
  static Color _dark(Color c, double f) => Color.lerp(c, Colors.black, f)!;

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in s._things) {
      canvas.save();
      canvas.translate(t.x, t.y);
      canvas.scale(t.dir, 1);
      final u = t.size;
      // soft ground shadow
      canvas.drawOval(
        Rect.fromCenter(center: Offset(0, 2), width: u * 0.9, height: u * 0.12),
        Paint()..color = Colors.black.withValues(alpha: 0.25),
      );
      switch (t.kind) {
        case _A.lion:
        case _A.tiger:
        case _A.sheep:
        case _A.goat:
        case _A.cat:
        case _A.dog:
          _quad(canvas, t, u);
        case _A.snake:
          _snake(canvas, t, u);
        case _A.frog:
          _frog(canvas, t, u);
        case _A.beetle:
          _beetle(canvas, t, u);
        case _A.ant:
          _ant(canvas, t, u);
        case _A.spider:
          _spider(canvas, t, u);
      }
      canvas.restore();
    }
  }

  void _quad(Canvas c, _Critter t, double u) {
    final k = t.kind;
    final ph = t.dist / (u * 0.28);
    final body = switch (k) {
      _A.lion => const Color(0xFFD9A441),
      _A.tiger => const Color(0xFFF08A24),
      _A.sheep => const Color(0xFFF4F1E8),
      _A.goat => const Color(0xFFCDBBA0),
      _A.cat => const Color(0xFF9A9AA8),
      _ => const Color(0xFFB07A4A),
    };
    final dark = _dark(body, 0.5);
    final legLen = (k == _A.sheep ? 0.34 : k == _A.cat ? 0.36 : 0.42) * u;
    final bodyW = (k == _A.cat || k == _A.sheep ? 0.85 : 1.0) * u;
    final bodyH = (k == _A.cat ? 0.28 : (k == _A.lion || k == _A.tiger) ? 0.4 : 0.36) * u;
    final bob = math.sin(ph * 2) * 0.012 * u;
    final cy = -legLen - bodyH / 2 + bob;
    final legCol = k == _A.sheep ? const Color(0xFF3B3532) : _dark(body, 0.25);

    // legs
    for (var i = 0; i < 4; i++) {
      final hipX = i < 2 ? bodyW * 0.32 : -bodyW * 0.32;
      final off = (i == 0 || i == 3) ? 0.0 : math.pi;
      final sw = math.sin(ph + off) * 0.16 * u;
      final lift = math.max(0.0, math.cos(ph + off)) * 0.07 * u;
      final hip = Offset(hipX, cy + bodyH * 0.2);
      final foot = Offset(hipX + sw, -lift);
      final knee = Offset((hip.dx + foot.dx) / 2 + (i < 2 ? 0.03 : -0.05) * u, (hip.dy + foot.dy) / 2);
      final p = Path()
        ..moveTo(hip.dx, hip.dy)
        ..lineTo(knee.dx, knee.dy)
        ..lineTo(foot.dx, foot.dy);
      c.drawPath(p, _line(legCol, u * (k == _A.sheep ? 0.07 : 0.09)));
    }

    // tail
    final tailBase = Offset(-bodyW * 0.48, cy - bodyH * 0.1);
    final wag = math.sin(s._clock * 7) * 0.08 * u;
    switch (k) {
      case _A.lion:
      case _A.tiger:
        final tp = Path()
          ..moveTo(tailBase.dx, tailBase.dy)
          ..quadraticBezierTo(-bodyW * 0.8, cy + bodyH * 0.2 + wag, -bodyW * 0.7, cy + bodyH * 0.9);
        c.drawPath(tp, _line(body, u * 0.06));
        c.drawCircle(Offset(-bodyW * 0.7, cy + bodyH * 0.9), u * 0.05, _fill(dark));
      case _A.cat:
        final tp = Path()
          ..moveTo(tailBase.dx, tailBase.dy)
          ..quadraticBezierTo(-bodyW * 0.85, cy - bodyH * 0.1, -bodyW * 0.7 + wag, cy - bodyH * 1.8);
        c.drawPath(tp, _line(body, u * 0.06));
      case _A.dog:
        c.drawLine(tailBase, tailBase + Offset(-0.14 * u + wag, -0.2 * u), _line(body, u * 0.06));
      case _A.sheep:
        c.drawCircle(tailBase + Offset(-0.03 * u, 0.03 * u), u * 0.06, _fill(body));
      default:
        c.drawLine(tailBase, tailBase + Offset(-0.06 * u, -0.1 * u), _line(body, u * 0.05));
    }

    // body
    final bodyRect = Rect.fromCenter(center: Offset(0, cy), width: bodyW, height: bodyH);
    if (k == _A.sheep) {
      for (var i = 0; i < 9; i++) {
        final a = i / 9 * 2 * math.pi;
        c.drawCircle(
          Offset(math.cos(a) * bodyW * 0.36, cy + math.sin(a) * bodyH * 0.3),
          bodyH * 0.38,
          _fill(body),
        );
      }
      c.drawOval(bodyRect.deflate(bodyH * 0.1), _fill(body));
    } else {
      c.drawOval(bodyRect, _fill(body));
      if (k == _A.tiger) {
        c.save();
        c.clipPath(Path()..addOval(bodyRect));
        for (var i = -3; i <= 3; i++) {
          c.drawLine(
            Offset(i * bodyW * 0.14, cy - bodyH * 0.55),
            Offset(i * bodyW * 0.14 - bodyW * 0.05, cy + bodyH * 0.55),
            _line(const Color(0xFF1A1208), u * 0.05),
          );
        }
        c.restore();
      }
    }

    // neck, mane, head
    final hr = u * (k == _A.lion ? 0.17 : k == _A.cat ? 0.13 : k == _A.sheep ? 0.14 : k == _A.dog ? 0.15 : k == _A.goat ? 0.13 : 0.16);
    final headC = Offset(bodyW / 2 + hr * 0.5, cy - bodyH * 0.35);
    c.drawLine(Offset(bodyW * 0.3, cy), headC, _line(body, bodyH * 0.6));
    if (k == _A.lion) {
      c.drawCircle(headC, hr * 1.9, _fill(const Color(0xFF7A4A1A)));
    }
    final faceCol = k == _A.sheep ? const Color(0xFF3B3532) : body;
    c.drawCircle(headC, hr, _fill(faceCol));
    if (k != _A.sheep && k != _A.cat) {
      c.drawOval(
        Rect.fromCenter(center: headC + Offset(hr * 0.85, hr * 0.35), width: hr * 1.1, height: hr * 0.8),
        _fill(_dark(body, 0.12)),
      );
      c.drawCircle(headC + Offset(hr * 1.3, hr * 0.2), hr * 0.14, _fill(const Color(0xFF1A1208)));
    }
    // ears and horns
    switch (k) {
      case _A.lion:
      case _A.tiger:
      case _A.cat:
        for (final sx in [-0.45, 0.35]) {
          final b = headC + Offset(hr * sx, -hr * 0.8);
          final tp = Path()
            ..moveTo(b.dx - hr * 0.3, b.dy + hr * 0.2)
            ..lineTo(b.dx, b.dy - hr * 0.75)
            ..lineTo(b.dx + hr * 0.3, b.dy + hr * 0.2)
            ..close();
          c.drawPath(tp, _fill(k == _A.lion ? _dark(body, 0.4) : body));
        }
      case _A.dog:
        c.drawOval(
          Rect.fromCenter(center: headC + Offset(-hr * 0.4, hr * 0.5), width: hr * 0.6, height: hr * 1.2),
          _fill(_dark(body, 0.45)),
        );
      case _A.sheep:
        c.drawOval(
          Rect.fromCenter(center: headC + Offset(-hr * 0.7, -hr * 0.1), width: hr * 1.0, height: hr * 0.45),
          _fill(const Color(0xFF3B3532)),
        );
      case _A.goat:
        c.drawOval(
          Rect.fromCenter(center: headC + Offset(-hr * 0.8, -hr * 0.2), width: hr * 0.9, height: hr * 0.4),
          _fill(_dark(body, 0.3)),
        );
        for (final sx in [-0.2, 0.3]) {
          final b = headC + Offset(hr * sx, -hr * 0.8);
          final hp = Path()
            ..moveTo(b.dx, b.dy)
            ..quadraticBezierTo(b.dx - hr * 0.9, b.dy - hr * 1.1, b.dx - hr * 1.5, b.dy - hr * 0.5);
          c.drawPath(hp, _line(const Color(0xFF5A4A38), u * 0.035));
        }
        final bp = Path()
          ..moveTo(headC.dx + hr * 0.9, headC.dy + hr * 0.6)
          ..lineTo(headC.dx + hr * 0.7, headC.dy + hr * 1.6)
          ..lineTo(headC.dx + hr * 0.4, headC.dy + hr * 0.7)
          ..close();
        c.drawPath(bp, _fill(_dark(body, 0.3)));
      default:
    }
    // eye
    final eye = headC + Offset(hr * 0.35, -hr * 0.2);
    if (k == _A.cat) {
      c.drawCircle(eye, hr * 0.45, Paint()..color = const Color(0xFFC6FF3A).withValues(alpha: 0.3));
      c.drawCircle(eye, hr * 0.2, _fill(const Color(0xFFE6FF5A)));
    } else {
      c.drawCircle(eye, hr * 0.14, _fill(k == _A.sheep ? Colors.white : const Color(0xFF1A1208)));
    }
  }

  void _snake(Canvas c, _Critter t, double u) {
    final col = HSVColor.fromAHSV(1, 90 + (t.hue % 60), 0.7, 0.75).toColor();
    const n = 30;
    final ph = t.dist / (u * 0.25);
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final f = i / (n - 1);
      final x = -f * u;
      final y = -u * 0.06 + math.sin(ph - f * 7) * u * 0.07 * (0.4 + f);
      pts.add(Offset(x, y));
    }
    for (var i = n - 1; i >= 0; i--) {
      final f = i / (n - 1);
      final r = u * (0.045 * (1 - f * 0.85) + 0.008);
      c.drawCircle(pts[i], r, _fill(i % 5 == 0 ? _dark(col, 0.35) : col));
    }
    final head = pts.first;
    c.drawOval(Rect.fromCenter(center: head + Offset(u * 0.02, 0), width: u * 0.13, height: u * 0.075), _fill(col));
    c.drawCircle(head + Offset(u * 0.03, -u * 0.015), u * 0.012, _fill(Colors.black));
    if (((s._clock * 3) % 1) > 0.7) {
      c.drawLine(head + Offset(u * 0.08, 0), head + Offset(u * 0.15, 0), _line(const Color(0xFFE02B4A), u * 0.012));
    }
  }

  void _frog(Canvas c, _Critter t, double u) {
    final col = HSVColor.fromAHSV(1, 95 + (t.hue % 50), 0.75, 0.8).toColor();
    final cyc = (t.age % 1.5) / 1.5;
    final hop = cyc > 0.55 ? (cyc - 0.55) / 0.45 : 0.0;
    final lift = math.sin(hop * math.pi) * u * 0.9;
    c.save();
    c.translate(0, -lift);
    final stretch = hop > 0 ? 1.0 : 0.0;
    // back leg
    final foot = Offset(-u * 0.35 - stretch * u * 0.2, -u * 0.02 + stretch * u * 0.1);
    final hip = Offset(-u * 0.15, -u * 0.25);
    final knee = Offset(-u * 0.4, -u * 0.5 + stretch * u * 0.35);
    final lp = Path()
      ..moveTo(hip.dx, hip.dy)
      ..lineTo(knee.dx, knee.dy)
      ..lineTo(foot.dx, foot.dy);
    c.drawPath(lp, _line(_dark(col, 0.2), u * 0.1));
    c.drawLine(Offset(u * 0.15, -u * 0.2), Offset(u * 0.3, -u * 0.02), _line(_dark(col, 0.2), u * 0.07));
    c.drawOval(Rect.fromCenter(center: Offset(0, -u * 0.3), width: u * 0.8, height: u * 0.5), _fill(col));
    c.drawOval(Rect.fromCenter(center: Offset(u * 0.1, -u * 0.18), width: u * 0.5, height: u * 0.25), _fill(const Color(0xFFD9F2A0)));
    for (final ex in [0.18, 0.34]) {
      c.drawCircle(Offset(u * ex, -u * 0.58), u * 0.1, _fill(col));
      c.drawCircle(Offset(u * (ex + 0.02), -u * 0.59), u * 0.045, _fill(const Color(0xFF1A1208)));
    }
    c.restore();
  }

  void _legs6(Canvas c, _Critter t, double u, Color col, double len, double w) {
    final ph = t.dist / (u * 0.3);
    for (var i = 0; i < 3; i++) {
      for (final side in [-1.0, 1.0]) {
        final base = Offset((i - 1) * u * 0.22, -u * 0.22);
        final a = math.sin(ph + i * 2.1 + (side > 0 ? math.pi : 0)) * 0.3;
        // legs reach down and to the sides (a flat view: lower and upper rows)
        final tip = base + Offset(a * len, (side > 0 ? 0.55 : 0.3) * len);
        c.drawLine(base, tip, _line(col, w));
      }
    }
  }

  void _beetle(Canvas c, _Critter t, double u) {
    final col = HSVColor.fromAHSV(1, 190 + (t.hue % 70), 0.8, 0.8).toColor();
    _legs6(c, t, u, _dark(col, 0.5), u * 0.4, u * 0.05);
    c.drawOval(Rect.fromCenter(center: Offset(0, -u * 0.25), width: u * 0.8, height: u * 0.55), _fill(col));
    c.drawLine(Offset(-u * 0.38, -u * 0.25), Offset(u * 0.3, -u * 0.25), _line(_dark(col, 0.5), u * 0.03));
    c.drawCircle(Offset(u * 0.46, -u * 0.25), u * 0.14, _fill(_dark(col, 0.4)));
    c.drawLine(Offset(u * 0.55, -u * 0.3), Offset(u * 0.8, -u * 0.5), _line(_dark(col, 0.5), u * 0.03));
    c.drawLine(Offset(u * 0.55, -u * 0.2), Offset(u * 0.8, -u * 0.05), _line(_dark(col, 0.5), u * 0.03));
  }

  void _ant(Canvas c, _Critter t, double u) {
    const col = Color(0xFF8A2E1E);
    _legs6(c, t, u, col, u * 0.5, u * 0.04);
    c.drawCircle(Offset(-u * 0.38, -u * 0.22), u * 0.2, _fill(col));
    c.drawCircle(Offset(-u * 0.02, -u * 0.22), u * 0.13, _fill(col));
    c.drawCircle(Offset(u * 0.3, -u * 0.24), u * 0.15, _fill(col));
    c.drawLine(Offset(u * 0.4, -u * 0.3), Offset(u * 0.65, -u * 0.5), _line(col, u * 0.03));
    c.drawLine(Offset(u * 0.4, -u * 0.2), Offset(u * 0.65, -u * 0.12), _line(col, u * 0.03));
  }

  void _spider(Canvas c, _Critter t, double u) {
    const col = Color(0xFF1B1626);
    final ph = t.dist / (u * 0.3);
    for (var i = 0; i < 4; i++) {
      for (final side in [-1.0, 1.0]) {
        final a = math.sin(ph + i * 1.3 + (side > 0 ? math.pi : 0)) * 0.12 * u;
        final hip = Offset((i - 1.5) * u * 0.14, -u * 0.3);
        final knee = hip + Offset(a + (i - 1.5) * u * 0.1, -u * 0.18 + side * 0.0);
        final foot = Offset(knee.dx + (i - 1.5) * u * 0.1 + a, -u * 0.02 - (side > 0 ? 0 : 0));
        final dyOff = side * u * 0.05;
        final p = Path()
          ..moveTo(hip.dx, hip.dy)
          ..lineTo(knee.dx, knee.dy - u * 0.12 + dyOff)
          ..lineTo(foot.dx, foot.dy);
        c.drawPath(p, _line(col, u * 0.04));
      }
    }
    c.drawCircle(Offset(-u * 0.12, -u * 0.32), u * 0.24, _fill(col));
    c.drawCircle(Offset(u * 0.16, -u * 0.34), u * 0.14, _fill(col));
    c.drawCircle(Offset(u * 0.2, -u * 0.38), u * 0.03, _fill(const Color(0xFFFF4DD2)));
    c.drawCircle(Offset(u * 0.26, -u * 0.34), u * 0.03, _fill(const Color(0xFFFF4DD2)));
  }

  @override
  bool shouldRepaint(_CritterPainter old) => true;
}
