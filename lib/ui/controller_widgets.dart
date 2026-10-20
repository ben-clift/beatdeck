import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Rotary knob. Drag up to turn it up, drag down to turn it down.
/// [value] runs from 0 to 1. Double tap resets to [center].
class ControllerKnob extends StatelessWidget {
  const ControllerKnob({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = '',
    this.size = 44,
    this.center = 0.5,
    this.accent = SideDeckTheme.accentA,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final String label;
  final double size;
  final double center;
  final Color accent;

  // A full sweep takes about 160 logical pixels of dragging.
  static const _pixelsForFullTurn = 160.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) {
            // Dragging up gives a negative dy, which should raise the value.
            final next = value - d.delta.dy / _pixelsForFullTurn;
            onChanged(next.clamp(0.0, 1.0).toDouble());
          },
          onDoubleTap: () => onChanged(center),
          child: CustomPaint(
            size: Size.square(size),
            painter: _KnobPainter(
              value: value,
              accent: accent,
              base: LookController.instance.knobBase,
              face: LookController.instance.knobFace,
            ),
          ),
        ),
        if (label.isNotEmpty)
          Text(
            label,
            style: const TextStyle(fontSize: 9, letterSpacing: 1.4, color: Color(0xFFA0A0A0)),
          ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({
    required this.value,
    required this.accent,
    required this.base,
    required this.face,
  });

  final double value;
  final Color accent;
  final Color base;
  final Color face;

  // The pointer sweeps 270 degrees, from 7 o'clock round to 5 o'clock.
  static const _start = 0.75 * math.pi;
  static const _sweep = 1.5 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width / 2;
    final r = outer * 0.74; // knob body leaves room for the printed scale
    // Printed scale marks around the sweep.
    final tick = Paint()
      ..color = const Color(0xFF8A8A8A)
      ..strokeWidth = 1;
    for (var i = 0; i <= 10; i++) {
      final a = _start + _sweep * i / 10;
      final len = i % 5 == 0 ? 0.2 : 0.11;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (outer * (1 - len)),
        c + Offset(math.cos(a), math.sin(a)) * outer,
        tick,
      );
    }
    // Lit arc showing the setting.
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: outer * 0.86),
      _start,
      _sweep * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );
    // Black knob with a grey rim and a soft highlight.
    canvas.drawCircle(c + const Offset(0, 1.5), r, Paint()..color = const Color(0xAA000000));
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF6A6A6A));
    canvas.drawCircle(
      c,
      r - 1.5,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          colors: [face, base, const Color(0xFF0C0C0C)],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final angle = _start + _sweep * value;
    canvas.drawLine(
      c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.25),
      c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.9),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.value != value ||
      old.accent != accent ||
      old.base != base ||
      old.face != face;
}

/// Vertical fader. Drag up to raise it, drag down to lower it.
/// [value] runs from 0 (bottom) to 1 (top).
class ControllerFader extends StatelessWidget {
  const ControllerFader({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = 120,
    this.accent = SideDeckTheme.accentA,
    this.ticks = false,
  });

  /// Draws a printed scale either side of the slot, like a tempo fader.
  final bool ticks;
  final double value;
  final ValueChanged<double> onChanged;
  final double height;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    const capHeight = 26.0;
    final travel = height - capHeight;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        final next = value - d.delta.dy / travel;
        onChanged(next.clamp(0.0, 1.0).toDouble());
      },
      child: SizedBox(
        width: 34,
        height: height,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            if (ticks)
              Positioned.fill(
                top: capHeight / 2,
                bottom: capHeight / 2,
                child: CustomPaint(painter: _TickPainter()),
              ),
            Positioned(
              top: capHeight / 2,
              bottom: capHeight / 2,
              child: Container(
                width: 6,
                decoration: BoxDecoration(
                  color: const Color(0xFF050505),
                  border: Border.all(color: const Color(0xFF3A3A3A), width: 0.8),
                ),
              ),
            ),
            Positioned(
              top: (1 - value) * travel,
              child: Container(
                width: 30,
                height: capHeight,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [
                    Color(0xFF141414),
                    Color(0xFF353535),
                    Color(0xFF141414),
                  ]),
                  border: Border.all(color: Colors.black),
                  boxShadow: const [
                    BoxShadow(color: Color(0xAA000000), blurRadius: 4, offset: Offset(0, 2)),
                  ],
                ),
                child: Center(
                  child: Container(height: 2, width: 22, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scale marks for a tempo fader: a long mark at the centre, shorter ones
/// every tenth of the throw.
class _TickPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF8A8A8A)
      ..strokeWidth = 1;
    final cx = size.width / 2;
    for (var i = 0; i <= 20; i++) {
      final y = size.height * i / 20;
      final centre = i == 10;
      final major = i % 5 == 0;
      final len = centre ? 15.0 : (major ? 11.0 : 6.0);
      canvas.drawLine(Offset(cx - len, y), Offset(cx - 5, y), paint);
      canvas.drawLine(Offset(cx + 5, y), Offset(cx + len, y), paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => false;
}
