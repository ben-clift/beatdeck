import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Effects drawer that pulls down from the top-right of the controller screen.
/// Must be a child of a [Stack].
class FxPullDown extends StatefulWidget {
  const FxPullDown({super.key, required this.dj});

  final DjController dj;

  @override
  State<FxPullDown> createState() => _FxPullDownState();
}

class _FxPullDownState extends State<FxPullDown> {
  static const _panelH = 150.0;
  static const _tabH = 24.0;
  static const _names = ['OFF', 'ECHO', 'REVERB', 'FLANGER'];
  static const _beatOptions = [0.25, 0.5, 0.75, 1.0, 2.0];
  static const _beatLabels = ['1/4', '1/2', '3/4', '1', '2'];

  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      top: _open ? 0 : -_panelH,
      left: 0,
      right: 0,
      height: _panelH + _tabH,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.dj, LookController.instance]),
        builder: (context, _) => Column(
          children: [
            SizedBox(height: _panelH, child: _panel()),
            _tab(),
          ],
        ),
      ),
    );
  }

  Widget _tab() {
    final dj = widget.dj;
    final on = dj.fxType != 0;
    final accent = LookController.instance.accent(1);
    final fg = on ? SideDeckTheme.bg : SideDeckTheme.text;
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 120 && !_open) setState(() => _open = true);
          if (v < -120 && _open) setState(() => _open = false);
        },
        child: Container(
          height: _tabH,
          margin: const EdgeInsets.only(right: 84),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? accent : const Color(0xFF3A3834),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 16,
                color: fg,
              ),
              const SizedBox(width: 4),
              Text(
                on ? 'FX ${_names[dj.fxType]}' : 'FX',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    final dj = widget.dj;
    final look = LookController.instance;
    final timed = dj.fxType == 1 || dj.fxType == 3;
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -120) setState(() => _open = false);
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        decoration: BoxDecoration(
          color: Color.lerp(look.body, Colors.black, 0.15),
          border: Border(bottom: BorderSide(color: look.accent(1), width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'EFFECTS',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(width: 14),
                for (var i = 0; i < _names.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_names[i]),
                      selected: dj.fxType == i,
                      onSelected: (_) => dj.setFx(type: i),
                    ),
                  ),
              ],
            ),
            Row(
              children: [
                const SizedBox(
                  width: 52,
                  child: Text('AMOUNT', style: TextStyle(fontSize: 11)),
                ),
                Expanded(
                  child: Slider(
                    value: dj.fxAmount,
                    onChanged: dj.fxType == 0
                        ? null
                        : (v) => dj.setFx(amount: v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    dj.fxType == 3 ? 'SPEED' : 'BEATS',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                for (var i = 0; i < _beatOptions.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_beatLabels[i]),
                      selected: dj.fxBeats == _beatOptions[i],
                      onSelected: timed
                          ? (_) => dj.setFx(beats: _beatOptions[i])
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
