import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Horizontal scrolling DJ waveform: playhead pinned center, regular beat grid.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.min,
    required this.max,
    required this.position,
    required this.duration,
    required this.beatOffset,
    required this.bpm,
    required this.color,
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.zoomWindowSec = 3,
    this.showJumpZone = false,
  });

  final Float32List min;
  final Float32List max;
  final double position;
  final double duration;
  final double beatOffset;
  final double bpm;
  final Color color;
  /// Playback rate (file seconds per heard second). Zooms the scrolling
  /// waveform in heard-time so synced decks share a beat grid.
  final double rate;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  final double zoomWindowSec;
  final bool showJumpZone;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0A0C10));

    if (min.isEmpty || duration <= 0 || size.width <= 1 || size.height <= 1) {
      return;
    }

    var peak = 0.001;
    final n = math.min(min.length, max.length);
    for (var i = 0; i < n; i++) {
      peak = math.max(peak, math.max(min[i].abs(), max[i].abs()));
    }

    const overviewH = WaveformPainter.overviewH;
    final waveTop = overviewH;
    final waveH = size.height - overviewH;
    final mid = waveTop + waveH / 2;

    final playRate = rate.clamp(0.5, 2.0);
    // Heard-time window (what you hear), mapped back to file seconds.
    // rate > 1 compresses the wave; rate < 1 stretches it.
    final halfWin = (zoomWindowSec / 2) * playRate;
    final viewStart = position - halfWin;
    final viewEnd = position + halfWin;
    final viewDur = zoomWindowSec * playRate;

    double xForTime(double t) => ((t - viewStart) / viewDur) * size.width;

    _fillWave(
      canvas,
      n: n,
      peak: peak,
      x0: 0,
      x1: size.width,
      t0: 0,
      t1: duration,
      mid: overviewH / 2,
      halfH: (overviewH - 2) / 2,
      step: 1.0,
      outline: false,
    );
    final winL = (viewStart / duration) * size.width;
    final winR = (viewEnd / duration) * size.width;
    canvas.drawRect(
      Rect.fromLTRB(winL.clamp(0, size.width), 0, winR.clamp(0, size.width), overviewH),
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    _drawPlayhead(
      canvas,
      x: (position / duration) * size.width,
      y0: 0,
      y1: overviewH,
      coreWidth: 2.4,
      tick: true,
    );
    _drawLoopOverview(canvas, size, overviewH);

    _fillWave(
      canvas,
      n: n,
      peak: peak,
      x0: 0,
      x1: size.width,
      t0: viewStart,
      t1: viewEnd,
      mid: mid,
      halfH: waveH * 0.48,
      step: 0.75,
      outline: true,
    );

    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..strokeWidth = 1,
    );

    // Grid on top of the wave so it stays visible.
    final beatSec = bpm > 1 ? 60.0 / bpm : 0.0;
    if (beatSec > 0.05) {
      var t = beatOffset;
      if (t > viewStart) {
        t -= (((t - viewStart) / beatSec).ceil() * beatSec);
      }
      while (t < viewStart) {
        t += beatSec;
      }
      for (; t <= viewEnd; t += beatSec) {
        if (t < 0 || t > duration) continue;
        final idx = ((t - beatOffset) / beatSec).round();
        final phrase = idx % 32 == 0; // 8 bars
        final bar = idx % 4 == 0;
        final paint = Paint()
          ..strokeWidth = phrase ? 2.0 : (bar ? 1.4 : 1.0)
          ..color = phrase
              ? const Color(0xFFFFF3B0).withValues(alpha: 0.72)
              : Colors.white.withValues(alpha: bar ? 0.42 : 0.20);
        canvas.drawLine(Offset(xForTime(t), waveTop), Offset(xForTime(t), size.height), paint);
      }
    }

    _drawLoopZoomed(canvas, size, waveTop, xForTime);

    if (showJumpZone) {
      _drawJumpZone(canvas, size, waveTop);
    }

    _drawPlayhead(
      canvas,
      x: size.width / 2,
      y0: waveTop,
      y1: size.height,
      coreWidth: 2.6,
      tick: false,
    );
  }

  /// Smooth filled waveform: a mirrored envelope drawn as one shape, with
  /// values interpolated between bins so zooming in stays smooth, not blocky.
  void _fillWave(
    Canvas canvas, {
    required int n,
    required double peak,
    required double x0,
    required double x1,
    required double t0,
    required double t1,
    required double mid,
    required double halfH,
    required double step,
    required bool outline,
  }) {
    final width = x1 - x0;
    final top = <Offset>[];
    final bottom = <Offset>[];
    for (var x = 0.0; x <= width + step; x += step) {
      final ta = t0 + (x / width) * (t1 - t0);
      final tb = t0 + ((x + step) / width) * (t1 - t0);
      if (tb <= 0 || ta >= duration) {
        top.add(Offset(x0 + x, mid));
        bottom.add(Offset(x0 + x, mid));
        continue;
      }
      final v = _smoothRange(ta, tb, n);
      final hi = (v.$2 / peak).clamp(0.0, 1.0);
      final lo = (v.$1.abs() / peak).clamp(0.0, 1.0);
      top.add(Offset(x0 + x, mid - math.max(0.6, hi * halfH)));
      bottom.add(Offset(x0 + x, mid + math.max(0.6, lo * halfH)));
    }
    final path = Path()..moveTo(top.first.dx, top.first.dy);
    for (final o in top.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    for (final o in bottom.reversed) {
      path.lineTo(o.dx, o.dy);
    }
    path.close();
    final rect = Rect.fromLTRB(x0, mid - halfH, x1, mid + halfH);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, Colors.white, 0.55)!.withValues(alpha: 0.95),
            color.withValues(alpha: 0.85),
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.85),
            Color.lerp(color, Colors.white, 0.55)!.withValues(alpha: 0.95),
          ],
          stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
        ).createShader(rect),
    );
    if (outline) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..strokeJoin = StrokeJoin.round
          ..color = Color.lerp(color, Colors.white, 0.7)!.withValues(alpha: 0.9),
      );
    }
  }

  /// Min and max over [ta, tb]; interpolates between neighbouring bins when
  /// the span is narrower than one bin.
  (double, double) _smoothRange(double ta, double tb, int n) {
    final binSec = duration / n;
    if (tb - ta >= binSec) {
      return _minMaxInRange(
        ta.clamp(0.0, duration).toDouble(),
        tb.clamp(0.0, duration).toDouble(),
        n,
        duration,
      );
    }
    final f = ((ta + tb) / 2) / binSec - 0.5;
    final i = f.floor();
    final k = f - i;
    final i0 = i.clamp(0, n - 1);
    final i1 = (i + 1).clamp(0, n - 1);
    return (
      min[i0] * (1 - k) + min[i1] * k,
      max[i0] * (1 - k) + max[i1] * k,
    );
  }

  static const overviewH = 16.0;
  static const _playhead = Color(0xFFF4F7FB);

  void _drawPlayhead(
    Canvas canvas, {
    required double x,
    required double y0,
    required double y1,
    required double coreWidth,
    required bool tick,
  }) {
    final halo = Paint()
      ..color = const Color(0xE6000000)
      ..strokeWidth = coreWidth + 2.4
      ..strokeCap = StrokeCap.square;
    final core = Paint()
      ..color = _playhead
      ..strokeWidth = coreWidth
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(Offset(x, y0), Offset(x, y1), halo);
    canvas.drawLine(Offset(x, y0), Offset(x, y1), core);
    if (!tick) {
      return;
    }
    final tri = Path()
      ..moveTo(x, y1)
      ..lineTo(x - 5.5, y0)
      ..lineTo(x + 5.5, y0)
      ..close();
    canvas.drawPath(tri, Paint()..color = const Color(0xE6000000));
    final inner = Path()
      ..moveTo(x, y1 - 1)
      ..lineTo(x - 4, y0 + 1)
      ..lineTo(x + 4, y0 + 1)
      ..close();
    canvas.drawPath(inner, Paint()..color = _playhead);
  }

  static const jumpHalf = 0.14;

  /// Left edge of the beat-jump hit rect; same math as [_drawJumpZone].
  static double jumpZoneLeft(double width) => width * (0.5 - jumpHalf);

  /// Right edge of the beat-jump hit rect.
  static double jumpZoneRight(double width) => width * (0.5 + jumpHalf);
  static const _loopColor = Color(0xFF1DE9B6);

  void _drawJumpZone(Canvas canvas, Size size, double waveTop) {
    final cx = size.width / 2;
    final half = size.width * jumpHalf;
    final left = cx - half;
    final right = cx + half;
    canvas.drawRect(
      Rect.fromLTRB(left, waveTop, right, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.06),
    );
    final edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, waveTop), Offset(left, size.height), edge);
    canvas.drawLine(Offset(right, waveTop), Offset(right, size.height), edge);

    final cy = waveTop + (size.height - waveTop) / 2;
    _chevron(canvas, Offset(cx - half * 0.55, cy), left: true);
    _chevron(canvas, Offset(cx + half * 0.55, cy), left: false);
    _jumpLabel(canvas, Offset(cx - half * 0.55 + 10, cy - 7), '4');
    _jumpLabel(canvas, Offset(cx + half * 0.55 - 18, cy - 7), '4');
  }

  void _chevron(Canvas canvas, Offset c, {required bool left}) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final dx = left ? -6.0 : 6.0;
    final path = Path()
      ..moveTo(c.dx - dx, c.dy - 8)
      ..lineTo(c.dx + dx, c.dy)
      ..lineTo(c.dx - dx, c.dy + 8);
    canvas.drawPath(path, paint);
  }

  void _jumpLabel(Canvas canvas, Offset o, String s) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, o);
  }

  void _drawLoopOverview(Canvas canvas, Size size, double overviewH) {
    if (!loopEnabled || loopEnd <= loopStart || duration <= 0) return;
    final x0 = ((loopStart / duration) * size.width).clamp(0.0, size.width);
    final x1 = ((loopEnd / duration) * size.width).clamp(0.0, size.width);
    if (x1 <= x0) return;
    canvas.drawRect(
      Rect.fromLTRB(x0, 0, x1, overviewH),
      Paint()..color = _loopColor.withValues(alpha: 0.45),
    );
  }

  void _drawLoopZoomed(
    Canvas canvas,
    Size size,
    double waveTop,
    double Function(double) xForTime,
  ) {
    if (!loopEnabled || loopEnd <= loopStart) return;
    final x0 = xForTime(loopStart);
    final x1 = xForTime(loopEnd);
    if (x1 < 0 || x0 > size.width) return;
    final left = x0.clamp(0.0, size.width);
    final right = x1.clamp(0.0, size.width);
    canvas.drawRect(
      Rect.fromLTRB(left, waveTop, right, size.height),
      Paint()..color = _loopColor.withValues(alpha: 0.22),
    );
    final edge = Paint()
      ..color = _loopColor
      ..strokeWidth = 2;
    if (x0 >= 0 && x0 <= size.width) {
      canvas.drawLine(Offset(x0, waveTop), Offset(x0, size.height), edge);
    }
    if (x1 >= 0 && x1 <= size.width) {
      canvas.drawLine(Offset(x1, waveTop), Offset(x1, size.height), edge);
    }
  }

  (double, double) _minMaxInRange(double t0, double t1, int n, double duration) {
    var i0 = ((t0 / duration) * n).floor().clamp(0, n - 1);
    var i1 = ((t1 / duration) * n).ceil().clamp(0, n - 1);
    if (i1 < i0) i1 = i0;
    var lo = 0.0;
    var hi = 0.0;
    for (var i = i0; i <= i1; i++) {
      lo = math.min(lo, min[i]);
      hi = math.max(hi, max[i]);
    }
    return (lo, hi);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.duration != duration ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.beatOffset != beatOffset ||
        oldDelegate.bpm != bpm ||
        oldDelegate.rate != rate ||
        oldDelegate.loopEnabled != loopEnabled ||
        oldDelegate.loopStart != loopStart ||
        oldDelegate.loopEnd != loopEnd ||
        oldDelegate.showJumpZone != showJumpZone;
  }
}

class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    required this.min,
    required this.max,
    required this.position,
    required this.duration,
    required this.color,
    this.beatOffset = 0,
    this.bpm = 0,
    this.rate = 1,
    this.loopEnabled = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.onSeek,
    this.onOverviewSeek,
    this.playing = false,
  });

  final Float32List min;
  final Float32List max;
  final double position;
  final double duration;
  final double beatOffset;
  final double bpm;
  final double rate;
  final Color color;
  final bool loopEnabled;
  final double loopStart;
  final double loopEnd;
  /// Zoomed jump-zone tap (typically ±4 beat jump toward the tap).
  final ValueChanged<double>? onSeek;
  /// Full-track overview strip tap → absolute position in seconds.
  final ValueChanged<double>? onOverviewSeek;

  /// When true the view glides between position updates, so the wave flows
  /// smoothly instead of stepping 20 times a second.
  final bool playing;

  static const zoom = 3.0;

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _basePos = 0;
  Duration _baseAt = Duration.zero;
  Duration _now = Duration.zero;

  @override
  void initState() {
    super.initState();
    _basePos = widget.position;
    _ticker = createTicker((d) {
      _now = d;
      if (widget.playing) setState(() {});
    })..start();
  }

  @override
  void didUpdateWidget(WaveformView old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position || old.playing != widget.playing) {
      _basePos = widget.position;
      _baseAt = _now;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double get _position {
    if (!widget.playing) return widget.position;
    final dt = (_now - _baseAt).inMicroseconds / 1e6;
    // Never run ahead more than a couple of update intervals.
    final glide = dt.clamp(0.0, 0.12);
    return (_basePos + glide * widget.rate)
        .clamp(0.0, widget.duration > 0 ? widget.duration : _basePos)
        .toDouble();
  }

  Color get color => widget.color;
  Float32List get min => widget.min;
  Float32List get max => widget.max;
  double get duration => widget.duration;
  double get beatOffset => widget.beatOffset;
  double get bpm => widget.bpm;
  double get rate => widget.rate;
  bool get loopEnabled => widget.loopEnabled;
  double get loopStart => widget.loopStart;
  double get loopEnd => widget.loopEnd;
  ValueChanged<double>? get onSeek => widget.onSeek;
  ValueChanged<double>? get onOverviewSeek => widget.onOverviewSeek;
  /// Heard seconds across the view. Eight beats are always on screen, so the
  /// wave scrolls in time with the tempo and synced decks line up.
  double get zoom {
    final heard = widget.bpm * widget.rate;
    if (heard < 30) return WaveformView.zoom;
    return (_beatsOnScreen * 60 / heard).clamp(1.5, 8.0).toDouble();
  }

  static const _beatsOnScreen = 8;

  @override
  Widget build(BuildContext context) {
    final position = _position;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
        final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 88.0;
        final paint = CustomPaint(
          painter: WaveformPainter(
            min: min,
            max: max,
            position: position,
            duration: duration,
            beatOffset: beatOffset,
            bpm: bpm,
            rate: rate,
            color: color,
            loopEnabled: loopEnabled,
            loopStart: loopStart,
            loopEnd: loopEnd,
            zoomWindowSec: zoom,
            showJumpZone: onSeek != null,
          ),
          size: Size(w, h),
        );
        if ((onSeek == null && onOverviewSeek == null) || duration <= 0) {
          return paint;
        }
        return GestureDetector(
          onTapDown: (d) {
            final nx = (d.localPosition.dx / w).clamp(0.0, 1.0);
            if (d.localPosition.dy < WaveformPainter.overviewH) {
              onOverviewSeek?.call(nx * duration);
              return;
            }
            if (onSeek == null) return;
            if ((nx - 0.5).abs() > WaveformPainter.jumpHalf) return;
            final playRate = rate.clamp(0.5, 2.0);
            final heard = (nx - 0.5) * zoom;
            final t = position + heard * playRate;
            onSeek!(t.clamp(0.0, duration).toDouble());
          },
          child: paint,
        );
      },
    );
  }
}
