import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/automix_pulldown.dart';
import 'package:sidedeck/ui/controller_widgets.dart';
import 'package:sidedeck/ui/equaliser_view.dart';
import 'package:sidedeck/ui/library_drawer.dart';
import 'package:sidedeck/ui/waveform.dart';


/// Hardware-style layout: two decks with a mixer between them.
///
/// Pages, left to right: library and sources, decks 1 and 2, decks 3 and 4.
/// Swipe left or right to move between them.
class ControllerView extends StatefulWidget {
  const ControllerView({
    super.key,
    required this.dj,
    required this.library,
    this.onOpenSettings,
  });

  final DjController dj;
  final LibraryController library;
  final VoidCallback? onOpenSettings;

  @override
  State<ControllerView> createState() => _ControllerViewState();
}

class _ControllerViewState extends State<ControllerView> {
  final _pages = PageController(initialPage: 1);
  int _page = 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  static const _titles = ['LIBRARY', 'DECKS 1 · 2', 'DECKS 3 · 4', 'EQUALISER'];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
      children: [
        SizedBox(
          height: 26,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _titles.length; i++)
                GestureDetector(
                  onTap: () => _pages.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  ),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    color: _page == i ? SideDeckTheme.text : Colors.transparent,
                    child: Text(
                      _titles[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                        color: _page == i
                            ? SideDeckTheme.bg
                            : SideDeckTheme.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              LibraryOverlay(
                dj: widget.dj,
                library: widget.library,
                onOpenSettings: widget.onOpenSettings,
                embedded: true,
              ),
              _DeckPair(dj: widget.dj, left: 0, right: 1),
              _DeckPair(dj: widget.dj, left: 2, right: 3),
              EqualiserView(dj: widget.dj),
            ],
          ),
        ),
      ],
        ),
        AutomixPullDown(dj: widget.dj),
      ],
    );
  }
}

/// Two decks and the mixer between them, drawn on a fixed canvas that scales
/// to the screen.
class _DeckPair extends StatelessWidget {
  const _DeckPair({required this.dj, required this.left, required this.right});

  final DjController dj;
  final int left;
  final int right;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([dj, LookController.instance]),
      builder: (context, _) {
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 920,
            height: 440,
            child: Row(
              children: [
                SizedBox(width: 340, child: _DeckPanel(dj: dj, index: left)),
                SizedBox(
                  width: 240,
                  child: _MixerPanel(dj: dj, left: left, right: right),
                ),
                SizedBox(width: 340, child: _DeckPanel(dj: dj, index: right)),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _PadMode { hotCue, loop, jump }

class _DeckPanel extends StatefulWidget {
  const _DeckPanel({required this.dj, required this.index});

  final DjController dj;
  final int index;

  @override
  State<_DeckPanel> createState() => _DeckPanelState();
}

class _DeckPanelState extends State<_DeckPanel> {
  _PadMode _mode = _PadMode.hotCue;
  static const _loopBars = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0];
  static const _jumpBeats = [-1, 1, -4, 4, -8, 8, -16, 16];
  // Tempo fader range: plus or minus 8 percent.
  static const _range = 0.08;

  LookController get look => LookController.instance;
  Color get _accent => look.accent(widget.index);
  DeckState get _d => widget.dj.deck(widget.index);

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final i = widget.index;
    final remaining = d.duration > d.position ? d.duration - d.position : 0.0;
    final heard = d.bpm > 1 ? d.bpm * d.rate : 0.0;
    return Container(
      margin: const EdgeInsets.all(6),
      decoration: look.panelDecoration(_accent),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(height: 4, color: _accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _deckBody(d, i, remaining, heard),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deckBody(DeckState d, int i, double remaining, double heard) {
    return Column(
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                color: _accent,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    color: SideDeckTheme.bg,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d.loaded ? d.title : 'Empty',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                heard > 0 ? heard.toStringAsFixed(1) : '--',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: _accent,
                ),
              ),
              const Text(' BPM  ',
                  style: TextStyle(fontSize: 10, color: SideDeckTheme.muted)),
              Text(
                d.key >= 0 ? formatKey(d.key) : '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                d.loaded ? '-${formatDuration(remaining)}' : '',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _wave(d),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final size = math.min(150.0, math.min(c.maxHeight, c.maxWidth));
                      return Center(child: _jog(d, size < 80 ? 80 : size));
                    },
                  ),
                ),
                _tempo(d),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _transport(d),
          const SizedBox(height: 6),
          _modeRow(),
          const SizedBox(height: 4),
          _pads(d),
        ],
    );
  }

  Widget _wave(DeckState d) {
    return Container(
      height: 60,
      color: look.well,
      child: d.loaded && d.duration > 0
          ? WaveformView(
              min: d.waveMin,
              max: d.waveMax,
              position: d.position,
              duration: d.duration,
              beatOffset: d.beatOffset,
              bpm: d.bpm,
              rate: d.rate,
              color: _accent,
              loopEnabled: d.loopEnabled,
              loopStart: d.loopStart,
              loopEnd: d.loopEnd,
              onOverviewSeek: (t) => widget.dj.seekTo(widget.index, t),
            )
          : Center(
              child: Text(
                'LOAD A TRACK',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: look.controlHigh,
                ),
              ),
            ),
    );
  }

  Widget _jog(DeckState d, double size) {
    // 33 1/3 rpm look: one turn every 1.8 seconds of track.
    final angle = d.position / 1.8 * 2 * math.pi;
    return GestureDetector(
      onPanUpdate: (u) {
        if (!d.loaded) return;
        final c = Offset(size / 2, size / 2);
        final p = u.localPosition - c;
        final prev = p - u.delta;
        var da = math.atan2(p.dy, p.dx) - math.atan2(prev.dy, prev.dx);
        if (da > math.pi) da -= 2 * math.pi;
        if (da < -math.pi) da += 2 * math.pi;
        // Turning clockwise moves forward through the track.
        widget.dj.seekTo(widget.index, d.position + da / (2 * math.pi) * 1.8);
      },
      child: CustomPaint(
        size: Size.square(size),
        painter: _JogPainter(
          angle: angle,
          accent: _accent,
          playing: d.playing,
          well: look.well,
          ring: look.control,
          inactive: look.controlHigh,
          face: look.body,
        ),
      ),
    );
  }

  Widget _tempo(DeckState d) {
    final v = (0.5 + (d.rate - 1.0) / (2 * _range)).clamp(0.0, 1.0).toDouble();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('+', style: TextStyle(fontSize: 10, color: SideDeckTheme.muted)),
        ControllerFader(
          value: v,
          height: 116,
          accent: _accent,
          onChanged: (x) {
            final snapped = (x - 0.5).abs() < 0.01 ? 0.5 : x;
            widget.dj.setRate(widget.index, 1.0 + (snapped - 0.5) * 2 * _range);
          },
        ),
        const Text('-', style: TextStyle(fontSize: 10, color: SideDeckTheme.muted)),
        const SizedBox(height: 2),
        _smallButton(
          'KEY LOCK',
          d.keylock,
          () => widget.dj.toggleKeylock(widget.index),
        ),
      ],
    );
  }

  Widget _smallButton(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: on ? _accent : look.control,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w800,
            color: on ? SideDeckTheme.bg : SideDeckTheme.muted,
          ),
        ),
      ),
    );
  }

  Widget _transport(DeckState d) {
    Widget big(String label, VoidCallback onTap, {bool on = false}) {
      return Expanded(
        child: GestureDetector(
          onTap: d.loaded ? onTap : null,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: on ? _accent : look.control,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                letterSpacing: 1,
                color: on ? SideDeckTheme.bg : SideDeckTheme.text,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        big('CUE', () => widget.dj.cue(widget.index)),
        big(d.playing ? 'PAUSE' : 'PLAY', () => widget.dj.playPause(widget.index),
            on: d.playing),
        big('SYNC', () => widget.dj.sync(widget.index), on: d.synced),
      ],
    );
  }

  Widget _modeRow() {
    Widget chip(String label, _PadMode m) {
      final on = _mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _mode = m),
          child: Container(
            height: 20,
            alignment: Alignment.center,
            color: on ? SideDeckTheme.text : look.control,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: on ? SideDeckTheme.bg : SideDeckTheme.muted,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('HOT CUE', _PadMode.hotCue),
        chip('LOOP', _PadMode.loop),
        chip('JUMP', _PadMode.jump),
      ],
    );
  }

  Widget _pads(DeckState d) {
    final pads = <Widget>[];
    for (var k = 0; k < 8; k++) {
      switch (_mode) {
        case _PadMode.hotCue:
          final set = d.hotcues[k] >= 0;
          pads.add(_pad(
            '${k + 1}',
            set,
            () => widget.dj.hotcue(widget.index, k),
            onLong: set ? () => widget.dj.clearHotcue(widget.index, k) : null,
          ));
        case _PadMode.loop:
          if (k < _loopBars.length) {
            final bars = _loopBars[k];
            final active = d.loopEnabled && d.loopBars == bars;
            pads.add(_pad(
              bars < 1 ? '1/${(1 / bars).round()}' : '${bars.round()}',
              active,
              () => widget.dj.setLoop(widget.index, !active, bars),
            ));
          } else if (k == 6) {
            pads.add(_pad('½', false, () => widget.dj.halfLoop(widget.index)));
          } else {
            pads.add(_pad('×2', false, () => widget.dj.doubleLoop(widget.index)));
          }
        case _PadMode.jump:
          final b = _jumpBeats[k];
          pads.add(_pad(
            b > 0 ? '+$b' : '$b',
            false,
            () => widget.dj.beatJump(widget.index, b),
          ));
      }
    }
    return SizedBox(
      height: 76,
      child: GridView.count(
        crossAxisCount: 4,
        childAspectRatio: 2.1,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: pads,
      ),
    );
  }

  Widget _pad(String label, bool on, VoidCallback onTap, {VoidCallback? onLong}) {
    return GestureDetector(
      onTap: _d.loaded ? onTap : null,
      onLongPress: onLong,
      child: Container(
        alignment: Alignment.center,
        color: on ? _accent : look.control,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            color: on ? SideDeckTheme.bg : SideDeckTheme.text,
          ),
        ),
      ),
    );
  }
}

class _JogPainter extends CustomPainter {
  _JogPainter({
    required this.angle,
    required this.accent,
    required this.playing,
    required this.well,
    required this.ring,
    required this.inactive,
    required this.face,
  });

  final double angle;
  final Color accent;
  final bool playing;
  final Color well;
  final Color ring;
  final Color inactive;
  final Color face;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = well);
    canvas.drawCircle(c, r - 8, Paint()..color = ring);
    canvas.drawCircle(
      c,
      r - 8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = playing ? accent : inactive,
    );
    canvas.drawCircle(c, r * 0.5, Paint()..color = face);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    canvas.drawLine(
      Offset.zero,
      Offset(0, -(r - 12)),
      Paint()
        ..color = accent
        ..strokeWidth = 5,
    );
    canvas.restore();
    canvas.drawCircle(c, 6, Paint()..color = well);
  }

  @override
  bool shouldRepaint(_JogPainter old) =>
      old.angle != angle ||
      old.playing != playing ||
      old.accent != accent ||
      old.well != well ||
      old.ring != ring ||
      old.inactive != inactive ||
      old.face != face;
}

class _MixerPanel extends StatelessWidget {
  const _MixerPanel({required this.dj, required this.left, required this.right});

  final DjController dj;
  final int left;
  final int right;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(6),
      decoration: LookController.instance.style == LookStyle.matte
          ? BoxDecoration(
              color: LookController.instance.well,
              borderRadius: BorderRadius.circular(4),
            )
          : LookController.instance.panelDecoration(Colors.white),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ControllerKnob(
                label: 'MASTER',
                value: (dj.master / 1.5).clamp(0.0, 1.0).toDouble(),
                center: 1.0 / 1.5,
                accent: Colors.white70,
                onChanged: (v) => dj.setMaster(v * 1.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _channel(left)),
                Expanded(child: _channel(right)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          const Text('CROSSFADER',
              style: TextStyle(fontSize: 8, color: SideDeckTheme.muted)),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
            ),
            child: Slider(
              value: dj.xfader.clamp(0.0, 1.0).toDouble(),
              onChanged: dj.setXfader,
            ),
          ),
        ],
      ),
    );
  }

  Widget _channel(int i) {
    final d = dj.deck(i);
    final c = LookController.instance.accent(i);
    // EQ knobs run -12 to +12 dB with the middle at 0.
    double eqIn(double db) => ((db + 12) / 24).clamp(0.0, 1.0).toDouble();
    double eqOut(double v) => v * 24 - 12;
    return Column(
      children: [
        ControllerKnob(
          label: 'TRIM',
          size: 34,
          accent: c,
          value: (d.gain / 2).clamp(0.0, 1.0).toDouble(),
          center: 0.5,
          onChanged: (v) => dj.setGain(i, v * 2),
        ),
        ControllerKnob(
          label: 'HI',
          size: 34,
          accent: c,
          value: eqIn(d.eqHigh),
          onChanged: (v) => dj.setEq(i, high: eqOut(v)),
        ),
        ControllerKnob(
          label: 'MID',
          size: 34,
          accent: c,
          value: eqIn(d.eqMid),
          onChanged: (v) => dj.setEq(i, mid: eqOut(v)),
        ),
        ControllerKnob(
          label: 'LOW',
          size: 34,
          accent: c,
          value: eqIn(d.eqLow),
          onChanged: (v) => dj.setEq(i, low: eqOut(v)),
        ),
        ControllerKnob(
          label: 'FILTER',
          size: 34,
          accent: c,
          value: ((d.filter + 1) / 2).clamp(0.0, 1.0).toDouble(),
          onChanged: (v) => dj.setFilter(i, v * 2 - 1),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Center(
            child: ControllerFader(
              value: d.fader.clamp(0.0, 1.0).toDouble(),
              height: 90,
              accent: c,
              onChanged: (v) => dj.setFader(i, v),
            ),
          ),
        ),
      ],
    );
  }
}
