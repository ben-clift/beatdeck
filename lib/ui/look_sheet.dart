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
