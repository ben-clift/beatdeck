import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';

/// 1980s style graphic equaliser: LED spectrum analyser on the left, ten
/// sliders on the right. The sliders shape the whole mix (master output).
class EqualiserView extends StatefulWidget {
  const EqualiserView({super.key, required this.dj});

  final DjController dj;

  @override
  State<EqualiserView> createState() => _EqualiserViewState();
}

class _EqualiserViewState extends State<EqualiserView> {
  static const _specLabels = [
    '40', '63', '100', '160', '250', '400', '630',
    '1k', '1.6k', '2.5k', '4k', '6.3k', '10k', '16k',
  ];
  static const _eqLabels = [
    '31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k',
  ];

  static const _silver = Color(0xFFC9CCD2);
  static const _dim = Color(0xFF7D8088);

  @override
  void initState() {
    super.initState();
    widget.dj.setSpectrumOn(true);
  }

  @override
  void dispose() {
    widget.dj.setSpectrumOn(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.dj,
      builder: (context, _) {
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 920,
            height: 440,
            child: Container(
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF8E9199), width: 2),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF303134), Color(0xFF18181A)],
                ),
              ),
              child: Column(
                children: [
                  _header(),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(flex: 14, child: _spectrumPanel()),
                        const SizedBox(width: 18),
                        Expanded(flex: 12, child: _sliderPanel()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: Color(0xFFFF3B30),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Color(0xAAFF3B30), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'GRAPHIC EQUALIZER',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 4,
            color: _silver,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          '10 BAND  ·  SPECTRUM ANALYZER',
          style: TextStyle(fontSize: 10, letterSpacing: 2, color: _dim),
        ),
        const Spacer(),
        GestureDetector(
          onTap: widget.dj.resetMasterEq,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFD7DADF), Color(0xFF8E9199)],
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text(
              'FLAT',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: Color(0xFF18181A),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0B0C),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF4A4C52)),
      ),
      child: child,
    );
  }

  Widget _spectrumPanel() {
    final dj = widget.dj;
    return _panel(
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              painter: _LedPainter(
                levels: List<double>.of(dj.spectrum),
                peaks: List<double>.of(dj.spectrumPeak),
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final l in _specLabels)
                Expanded(
                  child: Text(
                    l,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9, color: _dim),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'HZ',
            style: TextStyle(fontSize: 9, letterSpacing: 2, color: _dim),
          ),
        ],
      ),
    );
  }

  Widget _sliderPanel() {
    final dj = widget.dj;
    return _panel(
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                const SizedBox(
                  width: 26,
                  child: _DbScale(),
                ),
                for (var b = 0; b < DjController.eqBandCount; b++)
                  Expanded(
                    child: _EqSlider(
                      db: dj.eqBands[b],
                      onChanged: (v) => dj.setMasterEq(b, v),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 26),
              for (var b = 0; b < DjController.eqBandCount; b++)
                Expanded(
                  child: Text(
                    _eqLabels[b],
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9, color: _dim),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'HZ   ·   DRAG UP / DOWN   ·   DOUBLE TAP = 0',
            style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: _dim),
          ),
        ],
      ),
    );
  }
}

class _DbScale extends StatelessWidget {
  const _DbScale();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 9, color: Color(0xFF7D8088));
    return const Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('+12', style: style),
        Text('+6', style: style),
        Text('0', style: style),
        Text('-6', style: style),
        Text('-12', style: style),
      ],
    );
  }
}

/// Vertical slider with a ridged cap. Up is louder, down is quieter.
class _EqSlider extends StatelessWidget {
  const _EqSlider({required this.db, required this.onChanged});

  final double db;
  final ValueChanged<double> onChanged;

  static const _capH = 22.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        final travel = h - _capH;
        final top = (12 - db) / 24 * travel;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) {
            final next = db - d.delta.dy / travel * 24;
            onChanged(next.clamp(-12.0, 12.0).toDouble());
          },
          onDoubleTap: () => onChanged(0),
          child: SizedBox(
            height: h,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Positioned(
                  top: _capH / 2,
                  bottom: _capH / 2,
                  child: Container(
                    width: 5,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: const Color(0xFF3A3C41)),
                    ),
                  ),
                ),
                // centre line
                Positioned(
                  top: h / 2,
                  child: Container(
                    width: 18,
                    height: 1,
                    color: const Color(0xFF5A5D64),
                  ),
                ),
                Positioned(
                  top: top,
                  child: Container(
                    width: 26,
                    height: _capH,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFE4E6EA), Color(0xFF8A8D95)],
                      ),
                      boxShadow: const [
                        BoxShadow(color: Color(0x99000000), blurRadius: 3, offset: Offset(0, 2)),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < 3; i++)
                          Container(
                            height: 1,
                            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 3),
                            color: i == 1
                                ? const Color(0xFFFF3B30)
                                : const Color(0x66000000),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LedPainter extends CustomPainter {
  _LedPainter({
    required this.levels,
    required this.peaks,
    this.segments = 20,
    this.gapY = 3.0,
    this.gapX = 5.0,
  });

  final List<double> levels;
  final List<double> peaks;
  final int segments;
  final double gapY;
  final double gapX;

  int get _segments => segments;
  static const _green = Color(0xFF3DDC57);
  static const _yellow = Color(0xFFF2D230);
  static const _red = Color(0xFFF2483A);

  Color _colorFor(int seg) {
    final f = (seg + 1) / _segments;
    if (f <= 0.6) return _green;
    if (f <= 0.85) return _yellow;
    return _red;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final colW = (size.width - gapX * (n - 1)) / n;
    final segH = (size.height - gapY * (_segments - 1)) / _segments;
    for (var i = 0; i < n; i++) {
      final x = i * (colW + gapX);
      final lit = (levels[i] * _segments).round().clamp(0, _segments);
      final peakSeg =
          (peaks[i] * _segments).round().clamp(0, _segments) - 1;
      for (var s = 0; s < _segments; s++) {
        final y = size.height - (s + 1) * segH - s * gapY;
        final color = _colorFor(s);
        final on = s < lit || s == peakSeg;
        final paint = Paint()..color = on ? color : color.withValues(alpha: 0.12);
        final rect = Rect.fromLTWH(x, y, colW, segH);
        if (on) {
          canvas.drawRect(
            rect.inflate(2),
            Paint()..color = color.withValues(alpha: 0.18),
          );
        }
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_LedPainter old) => true;
}


/// Slim LED spectrum that sits across the top of the controller screen.
class EqualiserStrip extends StatelessWidget {
  const EqualiserStrip({super.key, required this.dj, this.height = 54});

  final DjController dj;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dj,
      builder: (context, _) {
        return Container(
          height: height,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          decoration: BoxDecoration(
            color: const Color(0xFF0B0B0C),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF4A4C52)),
          ),
          child: CustomPaint(
            painter: _LedPainter(
              levels: List<double>.of(dj.spectrum),
              peaks: List<double>.of(dj.spectrumPeak),
              segments: 10,
              gapY: 1.5,
              gapX: 4,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}
