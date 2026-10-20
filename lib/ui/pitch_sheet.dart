import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Bottom sheet with a pitch / tempo fader, range choice, reset and key lock
/// for one deck.
Future<void> showPitchSheet(
  BuildContext context, {
  required DjController dj,
  required int deck,
  required Color accent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SideDeckTheme.panel,
    builder: (context) => _PitchSheet(dj: dj, deck: deck, accent: accent),
  );
}

class _PitchSheet extends StatefulWidget {
  const _PitchSheet({
    required this.dj,
    required this.deck,
    required this.accent,
  });

  final DjController dj;
  final int deck;
  final Color accent;

  @override
  State<_PitchSheet> createState() => _PitchSheetState();
}

class _PitchSheetState extends State<_PitchSheet> {
  static const _ranges = [8.0, 16.0, 50.0];
  double _range = 16;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: ListenableBuilder(
          listenable: widget.dj,
          builder: (context, _) {
            final d = widget.dj.deck(widget.deck);
            final percent = (d.rate - 1.0) * 100.0;
            final shown = percent.clamp(-_range, _range).toDouble();
            final heard = d.bpm > 1 ? d.bpm * d.rate : 0.0;
            final sign = percent > 0 ? '+' : '';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Deck ${widget.deck == 0 ? 'A' : 'B'} pitch and tempo',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '$sign${percent.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: widget.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (heard > 0)
                      Text(
                        '${heard.toStringAsFixed(1)} BPM',
                        style: const TextStyle(color: SideDeckTheme.muted),
                      ),
                    const Spacer(),
                    for (final r in _ranges)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          label: Text('±${r.round()}%'),
                          selected: _range == r,
                          onSelected: (_) => setState(() => _range = r),
                        ),
                      ),
                  ],
                ),
                Slider(
                  value: shown,
                  min: -_range,
                  max: _range,
                  onChanged: !d.loaded
                      ? null
                      : (v) {
                          // Small dead zone so 0% is easy to land on.
                          final snapped = v.abs() < 0.15 ? 0.0 : v;
                          widget.dj.setRate(widget.deck, 1.0 + snapped / 100.0);
                        },
                ),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: d.loaded
                          ? () => widget.dj.setRate(widget.deck, 1.0)
                          : null,
                      child: const Text('Reset to 0%'),
                    ),
                    const Spacer(),
                    const Text('Key lock'),
                    Switch(
                      value: d.keylock,
                      onChanged: (v) => widget.dj.setKeylock(widget.deck, v),
                    ),
                  ],
                ),
                Text(
                  d.keylock
                      ? 'Key lock is on: the fader changes tempo only, the pitch stays the same.'
                      : 'Key lock is off: the pitch rises and falls with the speed, like a turntable.',
                  style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
