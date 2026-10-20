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
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _Star {
  const _Star(this.x, this.y, this.phase, this.size, this.speed, this.tint);

  final double x;
  final double y;
  final double phase;
  final double size;
  final double speed;
  final int tint; // -1 = white, otherwise a deck accent index
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
      ),
  ];
}();

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required Animation<double> repaint,
    required this.style,
    required this.bg,
    required this.accents,
  })  : _t = repaint,
        super(repaint: repaint);

  final Animation<double> _t;
  final LookStyle style;
  final Color bg;
  final List<Color> accents;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);
    final t = _t.value * math.pi * 2;
    switch (style) {
      case LookStyle.matte:
        break;
      case LookStyle.neon:
        _glow(canvas, size, Offset(size.width * 0.2, size.height * 1.05),
            size.width * 0.5, accents[0], 0.22);
        _glow(canvas, size, Offset(size.width * 0.8, size.height * 1.05),
            size.width * 0.5, accents[1], 0.22);
      case LookStyle.chrome:
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(bg, Colors.white, 0.10)!,
                bg,
                Color.lerp(bg, Colors.black, 0.35)!,
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
          _glow(canvas, size, c, size.width * 0.38, accents[i], 0.30);
        }
      case LookStyle.sparkle:
        final paint = Paint()..strokeCap = StrokeCap.round;
        for (final s in _stars) {
          final tw = 0.5 + 0.5 * math.sin(t * s.speed + s.phase);
          final alpha = 0.12 + 0.88 * tw * tw;
          final base = s.tint < 0 ? Colors.white : accents[s.tint];
          final p = Offset(s.x * size.width, s.y * size.height);
          final len = s.size * (1.2 + 2.2 * tw);
          paint
            ..color = base.withValues(alpha: alpha)
            ..strokeWidth = math.max(0.8, s.size * 0.35);
          canvas.drawLine(p - Offset(len, 0), p + Offset(len, 0), paint);
          canvas.drawLine(p - Offset(0, len), p + Offset(0, len), paint);
          canvas.drawCircle(p, s.size * 0.45, Paint()..color = base.withValues(alpha: alpha));
        }
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
      old.style != style || old.bg != bg || old.accents != accents;
}
