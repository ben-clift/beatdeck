import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Small AUTOMIX button for the controller screen. Tap to pick a playlist and
/// start; tap again to stop.
class AutomixChip extends StatefulWidget {
  const AutomixChip({super.key, required this.dj});

  final DjController dj;

  @override
  State<AutomixChip> createState() => _AutomixChipState();
}

class _AutomixChipState extends State<AutomixChip> {
  final _playlists = PlaylistController();
  double _fade = 12;

  @override
  void dispose() {
    _playlists.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final messenger = ScaffoldMessenger.of(context);
    final lists = _playlists.playlists.where((p) => p.paths.isNotEmpty).toList();
    if (lists.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Make a playlist first (Library, Playlists tab)'),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: SideDeckTheme.panel,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Start automix from',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    Row(
                      children: [
                        const Text('Fade', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _fade,
                            min: 4,
                            max: 30,
                            divisions: 26,
                            label: '${_fade.round()} s',
                            onChanged: (v) => setSheetState(() => _fade = v),
                          ),
                        ),
                        Text('${_fade.round()} s',
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final pl in lists)
                            ListTile(
                              dense: true,
                              title: Text(pl.name),
                              subtitle: Text(pl.paths.length == 1
                                  ? '1 track'
                                  : '${pl.paths.length} tracks'),
                              trailing: const Icon(Icons.play_arrow),
                              onTap: () {
                                widget.dj.startAutomix(
                                  pl.paths,
                                  fadeSeconds: _fade,
                                );
                                Navigator.pop(sheetContext);
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.dj, _playlists]),
      builder: (context, _) {
        final dj = widget.dj;
        final on = dj.automixOn;
        final accent = LookController.instance.accent(0);
        return GestureDetector(
          onTap: on ? dj.stopAutomix : _pick,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: on ? accent : const Color(0x33FFFFFF),
            child: Text(
              on
                  ? 'AUTOMIX ${dj.automixIndex + 1}/${dj.automixQueueLength}  ■'
                  : 'AUTOMIX',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: on ? SideDeckTheme.bg : SideDeckTheme.text,
              ),
            ),
          ),
        );
      },
    );
  }
}
