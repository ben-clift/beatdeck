import 'package:flutter/material.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Bottom sheet to choose the background, controller body and deck colours.
Future<void> showLookSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SideDeckTheme.panel,
    builder: (context) => const _LookSheet(),
  );
}

class _LookSheet extends StatelessWidget {
  const _LookSheet();

  @override
  Widget build(BuildContext context) {
    final look = LookController.instance;
    return SafeArea(
      child: ListenableBuilder(
        listenable: look,
        builder: (context, _) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.9,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              shrinkWrap: true,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Customise look',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: look.reset,
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                _section('Party effects'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Smoke when the sound hits the red'),
                  value: look.smokeOn,
                  onChanged: look.setSmoke,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Party streamers on big peaks'),
                  value: look.streamersOn,
                  onChanged: look.setStreamers,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: look.testEffects,
                    child: const Text('Try the effects now'),
                  ),
                ),
                _section('Style'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final st in LookStyle.values)
                      ChoiceChip(
                        label: Text(st.label),
                        selected: look.style == st,
                        onSelected: (_) => look.setStyle(st),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    look.style.blurb,
                    style: const TextStyle(
                      fontSize: 12,
                      color: SideDeckTheme.muted,
                    ),
                  ),
                ),
                if (look.style == LookStyle.sparkle) ...[
                  _section('Sparkle shape'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sh in LookShape.values)
                        ChoiceChip(
                          label: Text(sh.label),
                          selected: look.particleShape == sh,
                          onSelected: (_) => look.setParticleShape(sh),
                        ),
                    ],
                  ),
                ],
                _section('Background'),
                _swatches(
                  LookController.backgrounds,
                  look.backgroundIndex,
                  look.setBackground,
                ),
                _section('Controller body'),
                _swatches(
                  LookController.bodies,
                  look.bodyIndex,
                  look.setBody,
                ),
                for (var d = 0; d < look.deckAccent.length; d++) ...[
                  _section('Deck ${d + 1} colour'),
                  _swatches(
                    LookController.accents,
                    look.deckAccent[d],
                    (i) => look.setDeckAccent(d, i),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: SideDeckTheme.muted,
        ),
      ),
    );
  }

  Widget _swatches(
    List<LookOption> options,
    int selected,
    ValueChanged<int> onPick,
  ) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < options.length; i++)
          Semantics(
            label: options[i].name,
            button: true,
            selected: i == selected,
            child: GestureDetector(
              onTap: () => onPick(i),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: options[i].color,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: i == selected
                        ? SideDeckTheme.text
                        : const Color(0x33FFFFFF),
                    width: i == selected ? 3 : 1,
                  ),
                ),
                child: i == selected
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: options[i].color.computeLuminance() > 0.4
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
