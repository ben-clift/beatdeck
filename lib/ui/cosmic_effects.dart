import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';

/// Stars, planets, mystic geometry and psychedelic spirals that float over
/// the decks, fade away, and come back now and then. See-through and it
/// ignores touches. Which kinds appear is chosen in Customise look.
class CosmicEffects extends StatefulWidget {
  const CosmicEffects({super.key, required this.dj});

  final DjController dj;

  @override
  State<CosmicEffects> createState() => _CosmicEffectsState();
}

enum _Kind { planet, stars, mandala, moon, spiral, nebula, shooting }

class _Thing {
  _Thing({
    required this.kind,
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.life,
    required this.hue,
    required this.variant,
    required this.spin,
  }) : maxLife = life;

  final _Kind kind;
  double x, y, vx, vy, life;
  final double size;
  final double maxLife;
  final double hue; // 0..360
  final int variant;
  final double spin;
  double age = 0;
  List<Offset> pts = const [];
  List<double> phases = const [];

  /// Smooth in, long hold, smooth out.
  double get envelope {
    final t = (age / maxLife).clamp(0.0, 1.0);
    if (t < 0.22) return math.sin(t / 0.22 * math.pi / 2);
    if (t > 0.72) return math.cos((t - 0.72) / 0.28 * math.pi / 2);
    return 1.0;
  }
}

class _CosmicEffectsState extends State<CosmicEffects>
    with SingleTickerProviderStateMixin {
  final _look = LookController.instance;
  final _rnd = math.Random();
  final _things = <_Thing>[];
  final _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _next = 1.5;
  double _shootCool = 8;
  double _clock = 0;
  double _level = 0;
  double _frame = 0;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _look.addListener(_onLook);
    _ticker = createTicker(_onTick)..start();
  }

  void _onLook() {
    if (!_look.cosmicOn) _things.clear();
  }

  @override
  void dispose() {
    _look.removeListener(_onLook);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  List<_Kind> get _allowed {
    final m = _look.cosmicMask;
    return [
      if (m & 1 != 0) _Kind.stars,
      if (m & 2 != 0) _Kind.planet,
      if (m & 4 != 0) ...[_Kind.mandala, _Kind.moon],
      if (m & 8 != 0) ...[_Kind.spiral, _Kind.nebula],
    ];
  }

  double _maxLevel() {
    var m = 0.0;
    for (final v in widget.dj.spectrum) {
      if (v > m) m = v;
    }
    return m;
  }

  void _onTick(Duration elapsed) {
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;
    if (!_look.cosmicOn || _size.isEmpty) return;
    _clock += dt;
    final lv = _maxLevel();
    _level += (lv - _level) * math.min(1.0, dt * 8);

    for (final t in _things) {
      t.age += dt;
      t.life -= dt;
      t.x += t.vx * dt;
      t.y += t.vy * dt;
    }
    _things.removeWhere((t) => t.life <= 0);

    final allowed = _allowed;
    if (allowed.isEmpty) return;
    _next -= dt;
    final fresh = _things.where((t) => t.kind != _Kind.shooting).length;
    if (_next <= 0 && fresh < 3) {
      _spawn(allowed);
      _next = 6 + _rnd.nextDouble() * 16;
    } else if (_next <= 0) {
      _next = 3;
    }
    _shootCool -= dt;
    if (_shootCool <= 0 && allowed.contains(_Kind.stars) && (_level >= 0.9 || _rnd.nextDouble() < dt * 0.05)) {
      _spawnShooting();
      _shootCool = 9 + _rnd.nextDouble() * 12;
    }

    // About 30 repaints a second is plenty and keeps the phone cool.
    _frame += dt;
    if (_frame >= 1 / 30 && _things.isNotEmpty) {
      _frame = 0;
      _repaint.value++;
    }
  }

  void _spawn(List<_Kind> allowed) {
    final w = _size.width;
    final h = _size.height;
    final kind = allowed[_rnd.nextInt(allowed.length)];
    final size = switch (kind) {
      _Kind.planet => 40 + _rnd.nextDouble() * 70,
      _Kind.stars => 90 + _rnd.nextDouble() * 120,
      _Kind.mandala => 90 + _rnd.nextDouble() * 90,
      _Kind.moon => 40 + _rnd.nextDouble() * 40,
      _Kind.spiral => 100 + _rnd.nextDouble() * 100,
      _Kind.nebula => 180 + _rnd.nextDouble() * 160,
      _Kind.shooting => 120.0,
    };
    final sp = 6 + _rnd.nextDouble() * 18;
    final ang = _rnd.nextDouble() * math.pi * 2;
    final t = _Thing(
      kind: kind,
      x: size + _rnd.nextDouble() * math.max(1.0, w - 2 * size),
      y: size * 0.6 + _rnd.nextDouble() * math.max(1.0, h - 1.2 * size),
      vx: math.cos(ang) * sp,
      vy: math.sin(ang) * sp * 0.6,
      size: size,
      life: 11 + _rnd.nextDouble() * 12,
      hue: _rnd.nextDouble() * 360,
      variant: _rnd.nextInt(4),
      spin: (_rnd.nextDouble() - 0.5) * 0.5,
    );
    if (kind == _Kind.stars) {
      final n = 14 + _rnd.nextInt(14);
      t.pts = [
        for (var i = 0; i < n; i++)
          Offset((_rnd.nextDouble() - 0.5) * size * 2, (_rnd.nextDouble() - 0.5) * size * 1.4),
      ];
      t.phases = [for (var i = 0; i < n; i++) _rnd.nextDouble() * 6.28];
    }
    _things.add(t);
  }

  void _spawnShooting() {
    final w = _size.width;
    final h = _size.height;
    final fromLeft = _rnd.nextBool();
    final speed = 420 + _rnd.nextDouble() * 260;
    final ang = (fromLeft ? 0.25 : math.pi - 0.25) + (_rnd.nextDouble() - 0.5) * 0.3;
    _things.add(_Thing(
      kind: _Kind.shooting,
      x: fromLeft ? w * _rnd.nextDouble() * 0.3 : w * (0.7 + _rnd.nextDouble() * 0.3),
      y: h * _rnd.nextDouble() * 0.4,
      vx: math.cos(ang) * speed,
      vy: math.sin(ang) * speed,
      size: 120,
      life: 1.1,
      hue: 200 + _rnd.nextDouble() * 80,
      variant: 0,
      spin: 0,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, c) {
            _size = Size(c.maxWidth, c.maxHeight);
            return CustomPaint(
              painter: _CosmicPainter(this, _repaint),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _CosmicPainter extends CustomPainter {
  _CosmicPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _CosmicEffectsState s;

  static Color _hsv(double hue, double sat, double val, double a) =>
      HSVColor.fromAHSV(a.clamp(0.0, 1.0).toDouble(), hue % 360, sat, val).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in s._things) {
      final e = t.envelope;
      if (e <= 0.01) continue;
      final pulse = 1 + 0.07 * s._level;
      switch (t.kind) {
        case _Kind.planet:
          _planet(canvas, t, e, pulse);
        case _Kind.stars:
          _stars(canvas, t, e);
        case _Kind.mandala:
          _mandala(canvas, t, e, pulse);
        case _Kind.moon:
          _moon(canvas, t, e);
        case _Kind.spiral:
          _spiral(canvas, t, e, pulse);
        case _Kind.nebula:
          _nebula(canvas, t, e, pulse);
        case _Kind.shooting:
          _shooting(canvas, t, e);
      }
    }
  }

  void _planet(Canvas canvas, _Thing t, double e, double pulse) {
    final c = Offset(t.x, t.y);
    final r = t.size * 0.5 * pulse;
    final a = 0.8 * e;
    final hue = t.hue;
    final ringed = t.variant % 2 == 0;
    final tilt = -0.35 + t.variant * 0.1;
    void ring(bool front) {
      if (!ringed) return;
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(tilt);
      final rect = Rect.fromCenter(center: Offset.zero, width: r * 3.0, height: r * 0.85);
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.22
        ..color = _hsv(hue + 30, 0.35, 0.95, a * 0.7);
      canvas.drawArc(rect, front ? 0 : math.pi, math.pi, false, p);
      p
        ..strokeWidth = r * 0.07
        ..color = _hsv(hue + 50, 0.25, 1.0, a * 0.8);
      final rect2 = Rect.fromCenter(center: Offset.zero, width: r * 3.5, height: r * 1.0);
      canvas.drawArc(rect2, front ? 0 : math.pi, math.pi, false, p);
      canvas.restore();
    }

    // glow
    canvas.drawCircle(
      c,
      r * 1.9,
      Paint()
        ..shader = RadialGradient(colors: [
          _hsv(hue, 0.5, 1.0, a * 0.25),
          _hsv(hue, 0.5, 1.0, 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r * 1.9)),
    );
    ring(false);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.4),
          radius: 1.0,
          colors: [
            _hsv(hue, 0.35, 1.0, a),
            _hsv(hue + 15, 0.75, 0.75, a),
            _hsv(hue + 30, 0.9, 0.25, a),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // soft bands
    for (var i = -1; i <= 1; i++) {
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
      canvas.drawRect(
        Rect.fromCenter(center: c + Offset(0, i * r * 0.4), width: r * 2.2, height: r * 0.16),
        Paint()..color = _hsv(hue + 40, 0.5, 0.9, a * 0.18),
      );
      canvas.restore();
    }
    ring(true);
  }

  void _stars(Canvas canvas, _Thing t, double e) {
    for (var i = 0; i < t.pts.length; i++) {
      final tw = 0.5 + 0.5 * math.sin(s._clock * (1.5 + (i % 5) * 0.6) + t.phases[i]);
      final p = Offset(t.x, t.y) + t.pts[i];
      final a = (0.35 + 0.65 * tw) * e;
      final r = 0.9 + (i % 4) * 0.5;
      final col = _hsv(t.hue + i * 9, 0.18, 1.0, a);
      canvas.drawCircle(p, r, Paint()..color = col);
      if (i % 4 == 0) {
        final g = r * (3 + 3 * tw);
        final lp = Paint()
          ..strokeWidth = 1
          ..color = col.withValues(alpha: a * 0.7);
        canvas.drawLine(p - Offset(g, 0), p + Offset(g, 0), lp);
        canvas.drawLine(p - Offset(0, g), p + Offset(0, g), lp);
      }
    }
  }

  void _mandala(Canvas canvas, _Thing t, double e, double pulse) {
    final c = Offset(t.x, t.y);
    final rot = s._clock * t.spin;
    final petals = 6 + t.variant * 2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    for (var layer = 0; layer < 4; layer++) {
      final rr = t.size * (0.25 + layer * 0.22) * pulse;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = _hsv(t.hue + layer * 40 + s._clock * 12, 0.6, 1.0, 0.55 * e);
      canvas.save();
      canvas.rotate(rot * (layer.isEven ? 1 : -1) + layer * 0.2);
      for (var i = 0; i < petals; i++) {
        canvas.save();
        canvas.rotate(i * 2 * math.pi / petals);
        canvas.drawOval(Rect.fromCenter(center: Offset(0, -rr * 0.55), width: rr * 0.5, height: rr * 1.1), p);
        canvas.restore();
      }
      canvas.restore();
      canvas.drawCircle(Offset.zero, rr, p..strokeWidth = 0.8);
    }
    // hexagram in the middle
    final hp = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _hsv(t.hue + 180, 0.4, 1.0, 0.6 * e);
    for (var k = 0; k < 2; k++) {
      final path = Path();
      for (var i = 0; i < 3; i++) {
        final a = rot * 2 + k * math.pi / 3 + i * 2 * math.pi / 3 - math.pi / 2;
        final pt = Offset(math.cos(a), math.sin(a)) * t.size * 0.3;
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      canvas.drawPath(path, hp);
    }
    canvas.restore();
  }

  void _moon(Canvas canvas, _Thing t, double e) {
    final c = Offset(t.x, t.y);
    final r = t.size * 0.5;
    final a = 0.85 * e;
    canvas.drawCircle(
      c,
      r * 2.2,
      Paint()
        ..shader = RadialGradient(colors: [
          _hsv(50, 0.2, 1.0, a * 0.25),
          _hsv(50, 0.2, 1.0, 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r * 2.2)),
    );
    final path = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: c, radius: r)),
      Path()..addOval(Rect.fromCircle(center: c + Offset(r * 0.5, -r * 0.1), radius: r * 0.88)),
    );
    canvas.drawPath(path, Paint()..color = _hsv(48, 0.18, 1.0, a));
  }

  void _spiral(Canvas canvas, _Thing t, double e, double pulse) {
    final c = Offset(t.x, t.y);
    final arms = 3 + t.variant;
    final rot = s._clock * (0.4 + t.spin);
    final maxR = t.size * pulse;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    for (var a = 0; a < arms; a++) {
      final path = Path();
      const steps = 48;
      for (var i = 0; i <= steps; i++) {
        final f = i / steps;
        final ang = rot + a * 2 * math.pi / arms + f * 5.5;
        final rr = maxR * f;
        final pt = Offset(math.cos(ang), math.sin(ang)) * rr;
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.2
          ..color = _hsv(t.hue + a * 50 + s._clock * 25, 0.85, 1.0, 0.5 * e),
      );
    }
    canvas.restore();
  }

  void _nebula(Canvas canvas, _Thing t, double e, double pulse) {
    final c = Offset(t.x, t.y);
    for (var i = 0; i < 3; i++) {
      final off = Offset(
        math.cos(s._clock * 0.2 + i * 2.1 + t.hue) * t.size * 0.35,
        math.sin(s._clock * 0.17 + i * 1.7) * t.size * 0.25,
      );
      final cc = c + off;
      final r = t.size * (0.7 + i * 0.12) * pulse;
      canvas.drawCircle(
        cc,
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            _hsv(t.hue + i * 55, 0.7, 1.0, 0.22 * e),
            _hsv(t.hue + i * 55, 0.7, 1.0, 0),
          ]).createShader(Rect.fromCircle(center: cc, radius: r)),
      );
    }
  }

  void _shooting(Canvas canvas, _Thing t, double e) {
    final head = Offset(t.x, t.y);
    final dir = Offset(t.vx, t.vy);
    final len = dir.distance;
    if (len <= 0) return;
    final tail = head - dir / len * t.size;
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [
          _hsv(t.hue, 0.3, 1.0, 0),
          _hsv(t.hue, 0.15, 1.0, 0.9 * e),
        ]).createShader(Rect.fromPoints(tail, head)),
    );
    canvas.drawCircle(head, 2.2, Paint()..color = Colors.white.withValues(alpha: 0.9 * e));
  }

  @override
  bool shouldRepaint(_CosmicPainter old) => true;
}
