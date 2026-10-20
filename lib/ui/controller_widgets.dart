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
            style: const TextStyle(fontSize: 9, color: SideDeckTheme.muted),
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
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = base);
    canvas.drawCircle(c, r * 0.65, Paint()..color = face);
    final angle = _start + _sweep * value;
    canvas.drawLine(
      c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.2),
      c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.92),
      Paint()
        ..color = accent
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.butt,
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
  });

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
            Positioned(
              top: capHeight / 2,
              bottom: capHeight / 2,
              child: Container(width: 6, color: LookController.instance.well),
            ),
            Positioned(
              top: (1 - value) * travel,
              child: Container(
                width: 30,
                height: capHeight,
                decoration: const BoxDecoration(color: Color(0xFFD9D4CA)),
                child: Center(
                  child: Container(height: 2, width: 22, color: accent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
