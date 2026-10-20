import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/look_controller.dart';

/// Backdrop behind the controller. Plain for matte, neon and chrome; moving
/// for sparkle and aurora.
class LookBackground extends StatefulWidget {
  const LookBackground({super.key});

  @override
  State<LookBackground> createState() => _LookBackgroundState();
}

class _LookBackgroundState extends State<LookBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  );
  final _look = LookController.instance;

  @override
  void initState() {
    super.initState();
    _look.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (_look.style.animated) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _look.removeListener(_sync);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackdropPainter(
          repaint: _clock,
          style: _look.style,
          bg: _look.bg,
          accents: [for (var i = 0; i < 4; i++) _look.accent(i)],
          shape: _look.particleShape,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _Star {
  const _Star(
    this.x,
    this.y,
    this.phase,
    this.size,
    this.speed,
    this.tint,
    this.mix,
  );

  final double x;
  final double y;
  final double phase;
  final double size;
  final double speed;
  final int tint; // -1 = white, otherwise a deck accent index
  final int mix; // shape used when the shape is Mixed
}

final List<_Star> _stars = () {
  final r = math.Random(7);
  return [
    for (var i = 0; i < 80; i++)
      _Star(
        r.nextDouble(),
        r.nextDouble(),
        r.nextDouble() * math.pi * 2,
        0.8 + r.nextDouble() * 2.4,
        3 + r.nextInt(9).toDouble(),
        r.nextInt(3) == 0 ? r.nextInt(4) : -1,
        r.nextInt(5),
      ),
  ];
}();

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required Animation<double> repaint,
    required this.style,
    required this.bg,
    required this.accents,
    required this.shape,
  })  : _t = repaint,
        super(repaint: repaint);

  final Animation<double> _t;
  final LookStyle style;
  final Color bg;
  final List<Color> accents;
  final LookShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);
    final t = _t.value * math.pi * 2;
    switch (style) {
      case LookStyle.matte:
        break;
      case LookStyle.neon:
        canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.55));
        _glow(canvas, size, Offset(size.width * 0.25, size.height * 1.0),
            size.width * 0.55, accents[0], 0.40);
        _glow(canvas, size, Offset(size.width * 0.75, size.height * 1.0),
            size.width * 0.55, accents[1], 0.40);
        _gridFloor(canvas, size, t);
      case LookStyle.chrome:
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(bg, Colors.white, 0.30)!,
                bg,
                Color.lerp(bg, Colors.black, 0.6)!,
              ],
            ).createShader(rect),
        );
      case LookStyle.aurora:
        for (var i = 0; i < 4; i++) {
          final a = t + i * 1.7;
          final c = Offset(
            size.width * (0.5 + 0.42 * math.sin(a * 1.0 + i)),
            size.height * (0.5 + 0.38 * math.cos(a * 0.8 + i * 2)),
          );
          _glow(canvas, size, c, size.width * 0.45, accents[i], 0.55);
        }
      case LookStyle.sparkle:
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(bg, accents[0], 0.22)!,
                bg,
                Color.lerp(bg, accents[1], 0.22)!,
              ],
            ).createShader(rect),
        );
        for (final s in _stars) {
          final tw = 0.5 + 0.5 * math.sin(t * s.speed + s.phase);
          final alpha = 0.15 + 0.85 * tw * tw;
          final base = s.tint < 0 ? Colors.white : accents[s.tint];
          final p = Offset(s.x * size.width, s.y * size.height);
          final radius = s.size * (1.6 + 1.6 * tw);
          final which = shape == LookShape.mixed
              ? LookShape.values[s.mix]
              : shape;
          canvas.save();
          canvas.translate(p.dx, p.dy);
          canvas.rotate(math.sin(t * 3 + s.phase) * 0.35);
          canvas.drawCircle(
            Offset.zero,
            radius * 1.9,
            Paint()..color = base.withValues(alpha: alpha * 0.12),
          );
          _drawShape(canvas, which, radius, base.withValues(alpha: alpha));
          canvas.restore();
        }
    }
  }

  void _drawShape(Canvas canvas, LookShape which, double r, Color color) {
    final fill = Paint()..color = color;
    switch (which) {
      case LookShape.star:
        final path = Path();
        for (var i = 0; i < 10; i++) {
          final rad = i.isEven ? r : r * 0.42;
          final a = -math.pi / 2 + i * math.pi / 5;
          final pt = Offset(math.cos(a) * rad, math.sin(a) * rad);
          if (i == 0) {
            path.moveTo(pt.dx, pt.dy);
          } else {
            path.lineTo(pt.dx, pt.dy);
          }
        }
        path.close();
        canvas.drawPath(path, fill);
      case LookShape.heart:
        final path = Path()
          ..moveTo(0, r * 0.9)
          ..cubicTo(-r * 1.3, 0, -r * 0.8, -r, 0, -r * 0.35)
          ..cubicTo(r * 0.8, -r, r * 1.3, 0, 0, r * 0.9)
          ..close();
        canvas.drawPath(path, fill);
      case LookShape.diamond:
        final path = Path()
          ..moveTo(0, -r * 1.2)
          ..lineTo(r * 0.7, 0)
          ..lineTo(0, r * 1.2)
          ..lineTo(-r * 0.7, 0)
          ..close();
        canvas.drawPath(path, fill);
      case LookShape.bubble:
        canvas.drawCircle(
          Offset.zero,
          r,
          Paint()
            ..color = color.withValues(alpha: color.a * 0.25),
        );
        canvas.drawCircle(
          Offset.zero,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = color,
        );
        canvas.drawCircle(Offset(-r * 0.35, -r * 0.35), r * 0.2, fill);
      case LookShape.twinkle:
        final k = r * 1.4;
        final path = Path()
          ..moveTo(0, -k)
          ..quadraticBezierTo(0, 0, k, 0)
          ..quadraticBezierTo(0, 0, 0, k)
          ..quadraticBezierTo(0, 0, -k, 0)
          ..quadraticBezierTo(0, 0, 0, -k)
          ..close();
        canvas.drawPath(path, fill);
      case LookShape.mixed:
        canvas.drawCircle(Offset.zero, r * 0.6, fill);
    }
  }

  /// Retro grid floor in the lower half, sliding towards the viewer.
  void _gridFloor(Canvas canvas, Size size, double t) {
    final horizon = size.height * 0.55;
    final line = Paint()
      ..strokeWidth = 1
      ..color = accents[0].withValues(alpha: 0.35);
    final cx = size.width / 2;
    for (var i = -12; i <= 12; i++) {
      canvas.drawLine(
        Offset(cx + i * 8, horizon),
        Offset(cx + i * size.width * 0.12, size.height),
        line,
      );
    }
    final slide = (t / (math.pi * 2) * 60) % 1;
    for (var i = 0; i < 8; i++) {
      final f = ((i + slide) / 8);
      final y = horizon + (size.height - horizon) * f * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  void _glow(Canvas canvas, Size size, Offset c, double radius, Color color,
      double alpha) {
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: c, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.style != style ||
      old.bg != bg ||
      old.accents != accents ||
      old.shape != shape;
}
