import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';

/// Smoke that drifts across the screen when the sound hits the red, and party
/// streamers that burst out on the hardest peaks. Everything is random each
/// time. Drawn over the controller but see-through, and it ignores touches.
class PartyEffects extends StatefulWidget {
  const PartyEffects({super.key, required this.dj});

  final DjController dj;

  @override
  State<PartyEffects> createState() => _PartyEffectsState();
}

class _Puff {
  _Puff({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.radius,
    required this.grow,
    required this.life,
    required this.tint,
  }) : maxLife = life;

  double x, y, vx, vy, radius, grow, life;
  final double maxLife;
  final Color tint;
}

class _Streamer {
  _Streamer({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.color,
    required this.width,
    required this.life,
    required this.phase,
    required this.sway,
  }) : maxLife = life;

  double x, y, vx, vy, life;
  final double maxLife;
  final Color color;
  final double width;
  final double phase;
  final double sway;
  final List<Offset> trail = [];
}

class _Flash {
  _Flash({
    required this.kind,
    required this.color,
    required this.x,
    required this.y,
    required this.angle,
    required this.size,
    required this.life,
  }) : maxLife = life;

  final int kind; // 0 glow, 1 edge, 2 beams
  final Color color;
  final double x, y, angle, size;
  double life;
  final double maxLife;

  /// Quick rise, smooth fade.
  double get envelope {
    final t = (1 - life / maxLife).clamp(0.0, 1.0);
    return t < 0.12 ? t / 0.12 : (1 - t) / 0.88;
  }
}

class _PartyEffectsState extends State<PartyEffects>
    with SingleTickerProviderStateMixin {
  final _look = LookController.instance;
  final _rnd = math.Random();
  final _puffs = <_Puff>[];
  final _streamers = <_Streamer>[];
  final _flashes = <_Flash>[];
  double _flashCool = 1;
  final _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _spawn = 0;
  double _cooldown = 2;
  double _clock = 0;
  Size _size = Size.zero;

  static const _partyColors = [
    Color(0xFFFF3B7F),
    Color(0xFFFFD60A),
    Color(0xFF30D158),
    Color(0xFF64D2FF),
    Color(0xFFBF5AF2),
    Color(0xFFFF9F0A),
  ];

  @override
  void initState() {
    super.initState();
    _look.addListener(_sync);
    _look.testTrigger.addListener(_burstNow);
    _sync();
    _ticker = createTicker(_onTick)..start();
  }

  void _sync() {
    widget.dj.setEffectsOn(_look.smokeOn || _look.streamersOn || _look.flashOn);
  }

  void _burstNow() {
    if (_size.isEmpty) return;
    if (_look.smokeOn) {
      for (var i = 0; i < 9; i++) {
        _spawnPuff();
      }
    }
    if (_look.streamersOn) {
      _spawnStreamers();
    }
    if (_look.flashOn) {
      _spawnFlash();
    }
  }

  @override
  void dispose() {
    _look.removeListener(_sync);
    _look.testTrigger.removeListener(_burstNow);
    widget.dj.setEffectsOn(false);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  double _level() {
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
    if (dt > 0.05) dt = 0.05;
    _clock += dt;
    if (_size.isEmpty) return;

    final level = _level();

    // Smoke while the sound is in the red.
    if (_look.smokeOn && level > 0.85) {
      final heat = ((level - 0.85) / 0.15).clamp(0.0, 1.0);
      _spawn += (1.5 + heat * 7) * (0.5 + _rnd.nextDouble()) * dt;
      while (_spawn >= 1 && _puffs.length < 36) {
        _spawn -= 1;
        _spawnPuff();
      }
      if (_puffs.length >= 36) _spawn = 0;
    }

    // Random coloured light flashes, only while the sound is in the red.
    // Never more than about three a second, at irregular moments.
    _flashCool -= dt;
    if (_look.flashOn && level > 0.85 && _flashCool <= 0) {
      final heat = ((level - 0.85) / 0.15).clamp(0.0, 1.0);
      if (_rnd.nextDouble() < dt * (1.2 + heat * 3.5)) {
        _spawnFlash();
        final r = _rnd.nextDouble();
        _flashCool = 0.34 + r * r * 2.6;
      }
    }

    // Streamers on the hardest peaks, not too often.
    _cooldown -= dt;
    if (_look.streamersOn && level >= 0.95 && _cooldown <= 0) {
      _cooldown = 3.5 + _rnd.nextDouble() * 4;
      _spawnStreamers();
    }

    for (final p in _puffs) {
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vx += (_rnd.nextDouble() - 0.5) * 12 * dt;
      p.radius += p.grow * dt;
      p.life -= dt;
    }
    _puffs.removeWhere((p) => p.life <= 0);

    for (final s in _streamers) {
      s.vy += 300 * dt;
      final drag = 1 - 0.9 * dt;
      s.vx *= drag;
      s.vy *= drag;
      s.x += s.vx * dt + math.sin(_clock * 6 + s.phase) * s.sway * dt;
      s.y += s.vy * dt;
      s.life -= dt;
      s.trail.add(Offset(s.x, s.y));
      if (s.trail.length > 26) s.trail.removeAt(0);
    }
    _streamers.removeWhere((s) => s.life <= 0 || s.y > _size.height + 60);
    for (final f in _flashes) {
      f.life -= dt;
    }
    _flashes.removeWhere((f) => f.life <= 0);

    if (_puffs.isNotEmpty || _streamers.isNotEmpty || _flashes.isNotEmpty) {
      _repaint.value++;
    }
  }

  void _spawnPuff() {
    final w = _size.width;
    final h = _size.height;
    final r = 60 + _rnd.nextDouble() * 90;
    final speed = 30 + _rnd.nextDouble() * 70;
    final edge = _rnd.nextInt(3); // 0 bottom, 1 left, 2 right
    double x, y, vx, vy;
    switch (edge) {
      case 1:
        x = -r;
        y = _rnd.nextDouble() * h;
        vx = speed;
        vy = -10 - _rnd.nextDouble() * 25;
      case 2:
        x = w + r;
        y = _rnd.nextDouble() * h;
        vx = -speed;
        vy = -10 - _rnd.nextDouble() * 25;
      default:
        x = _rnd.nextDouble() * w;
        y = h + r * 0.5;
        vx = (_rnd.nextDouble() - 0.5) * speed * 1.6;
        vy = -speed * 0.6;
    }
    final grey = 205 + _rnd.nextInt(45);
    var tint = Color.fromARGB(255, grey, grey, grey);
    if (_rnd.nextInt(3) == 0) {
      tint = Color.lerp(tint, _look.accent(_rnd.nextInt(4)), 0.35)!;
    }
    _puffs.add(_Puff(
      x: x,
      y: y,
      vx: vx,
      vy: vy,
      radius: r,
      grow: 10 + _rnd.nextDouble() * 18,
      life: 5 + _rnd.nextDouble() * 4,
      tint: tint,
    ));
  }

  void _spawnFlash() {
    if (_flashes.length >= 4) return;
    final w = _size.width;
    final h = _size.height;
    final palette = [..._partyColors, _look.accent(0), _look.accent(1), _look.accent(2), _look.accent(3)];
    final kind = _rnd.nextInt(3);
    final count = kind == 2 ? 2 + _rnd.nextInt(3) : 1;
    for (var i = 0; i < count; i++) {
      final fromTop = _rnd.nextBool();
      _flashes.add(_Flash(
        kind: kind,
        color: palette[_rnd.nextInt(palette.length)],
        x: kind == 2 ? _rnd.nextDouble() * w : _rnd.nextDouble() * w,
        y: kind == 2 ? (fromTop ? -10 : h + 10) : _rnd.nextDouble() * h,
        // For beams: which way they point (down from the top or up from below)
        // plus a random lean. For edges: which edge (0..3).
        angle: kind == 1
            ? _rnd.nextInt(4).toDouble()
            : (fromTop ? math.pi / 2 : -math.pi / 2) + (_rnd.nextDouble() - 0.5) * 1.1,
        size: kind == 0
            ? 90 + _rnd.nextDouble() * 200
            : (kind == 1 ? 70 + _rnd.nextDouble() * 120 : 280 + _rnd.nextDouble() * 200),
        life: 0.25 + _rnd.nextDouble() * 0.45,
      ));
    }
  }

  void _spawnStreamers() {
    final w = _size.width;
    final h = _size.height;
    final count = 14 + _rnd.nextInt(20);
    final origin = _rnd.nextInt(4); // 0 left, 1 right, 2 both bottom corners, 3 top
    for (var i = 0; i < count; i++) {
      double x, y, angle;
      switch (origin) {
        case 0:
          x = 0;
          y = h * (0.35 + _rnd.nextDouble() * 0.5);
          angle = -math.pi / 3 + (_rnd.nextDouble() - 0.5) * 0.9;
        case 1:
          x = w;
          y = h * (0.35 + _rnd.nextDouble() * 0.5);
          angle = -2 * math.pi / 3 + (_rnd.nextDouble() - 0.5) * 0.9;
        case 2:
          final left = i.isEven;
          x = left ? 0 : w;
          y = h;
          angle = (left ? -math.pi / 3 : -2 * math.pi / 3) +
              (_rnd.nextDouble() - 0.5) * 0.8;
        default:
          x = w * (0.2 + _rnd.nextDouble() * 0.6);
          y = -10;
          angle = math.pi / 2 + (_rnd.nextDouble() - 0.5) * 1.4;
      }
      final speed = 320 + _rnd.nextDouble() * 420;
      final palette = [..._partyColors, _look.accent(0), _look.accent(1)];
      _streamers.add(_Streamer(
        x: x,
        y: y,
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed,
        color: palette[_rnd.nextInt(palette.length)],
        width: 2.5 + _rnd.nextDouble() * 3,
        life: 3 + _rnd.nextDouble() * 2.5,
        phase: _rnd.nextDouble() * 6.28,
        sway: 40 + _rnd.nextDouble() * 120,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, c) {
            _size = Size(c.maxWidth, c.maxHeight);
            return CustomPaint(
              painter: _EffectsPainter(_puffs, _streamers, _flashes, _repaint),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _EffectsPainter extends CustomPainter {
  _EffectsPainter(this.puffs, this.streamers, this.flashes, Listenable repaint)
      : super(repaint: repaint);

  final List<_Puff> puffs;
  final List<_Streamer> streamers;
  final List<_Flash> flashes;

  @override
  void paint(Canvas canvas, Size size) {
    // Light flashes first, soft and see-through (never full-screen white).
    for (final f in flashes) {
      final a = 0.34 * f.envelope;
      if (a <= 0.01) continue;
      switch (f.kind) {
        case 0:
          final c = Offset(f.x, f.y);
          canvas.drawCircle(
            c,
            f.size,
            Paint()
              ..shader = RadialGradient(
                colors: [f.color.withValues(alpha: a), f.color.withValues(alpha: 0)],
              ).createShader(Rect.fromCircle(center: c, radius: f.size)),
          );
        case 1:
          final edge = f.angle.round();
          final rect = switch (edge) {
            0 => Rect.fromLTWH(0, 0, size.width, f.size),
            1 => Rect.fromLTWH(0, size.height - f.size, size.width, f.size),
            2 => Rect.fromLTWH(0, 0, f.size, size.height),
            _ => Rect.fromLTWH(size.width - f.size, 0, f.size, size.height),
          };
          final begin = switch (edge) {
            0 => Alignment.topCenter,
            1 => Alignment.bottomCenter,
            2 => Alignment.centerLeft,
            _ => Alignment.centerRight,
          };
          final end = switch (edge) {
            0 => Alignment.bottomCenter,
            1 => Alignment.topCenter,
            2 => Alignment.centerRight,
            _ => Alignment.centerLeft,
          };
          canvas.drawRect(
            rect,
            Paint()
              ..shader = LinearGradient(
                begin: begin,
                end: end,
                colors: [f.color.withValues(alpha: a), f.color.withValues(alpha: 0)],
              ).createShader(rect),
          );
        default:
          final origin = Offset(f.x, f.y);
          final spread = 0.16;
          final tip1 = origin + Offset(math.cos(f.angle - spread), math.sin(f.angle - spread)) * f.size * 1.6;
          final tip2 = origin + Offset(math.cos(f.angle + spread), math.sin(f.angle + spread)) * f.size * 1.6;
          final path = Path()
            ..moveTo(origin.dx, origin.dy)
            ..lineTo(tip1.dx, tip1.dy)
            ..lineTo(tip2.dx, tip2.dy)
            ..close();
          canvas.drawPath(
            path,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [f.color.withValues(alpha: a * 0.8), f.color.withValues(alpha: 0)],
              ).createShader(Rect.fromPoints(origin, (tip1 + tip2) / 2)),
          );
      }
    }

    // Smoke: soft, low opacity so the controller stays visible underneath.
    for (final p in puffs) {
      final age = 1 - p.life / p.maxLife;
      final fade = math.sin(math.pi * age.clamp(0.0, 1.0));
      final alpha = 0.20 * fade;
      if (alpha <= 0.005) continue;
      final c = Offset(p.x, p.y);
      canvas.drawCircle(
        c,
        p.radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              p.tint.withValues(alpha: alpha),
              p.tint.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: p.radius)),
      );
    }
    // Streamers: curling ribbons with a bright head.
    for (final s in streamers) {
      if (s.trail.length < 2) continue;
      final fade = (s.life / s.maxLife).clamp(0.0, 1.0);
      final path = Path()..moveTo(s.trail.first.dx, s.trail.first.dy);
      for (var i = 1; i < s.trail.length; i++) {
        path.lineTo(s.trail[i].dx, s.trail[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = s.width
          ..color = s.color.withValues(alpha: 0.85 * math.min(1.0, fade * 2)),
      );
      canvas.drawCircle(
        s.trail.last,
        s.width * 0.9,
        Paint()..color = s.color.withValues(alpha: math.min(1.0, fade * 2)),
      );
    }
  }

  @override
  bool shouldRepaint(_EffectsPainter old) => true;
}
