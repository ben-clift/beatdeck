import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Automix drawer that pulls down from the top of the controller screen.
/// Drag the AUTOMIX tab down (or tap it) to open; drag up or tap to close.
/// Must be a child of a [Stack].
class AutomixPullDown extends StatefulWidget {
  const AutomixPullDown({super.key, required this.dj});

  final DjController dj;

  @override
  State<AutomixPullDown> createState() => _AutomixPullDownState();
}

class _AutomixPullDownState extends State<AutomixPullDown> {
  static const _panelH = 170.0;
  static const _tabH = 24.0;

  final _playlists = PlaylistController();
  bool _open = false;
  double _fade = 12;
  String? _selectedId;

  @override
  void dispose() {
    _playlists.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _open = !_open);

  Playlist? _selected(List<Playlist> lists) {
    for (final p in lists) {
      if (p.id == _selectedId) return p;
    }
    return lists.isEmpty ? null : lists.first;
  }

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
        listenable: Listenable.merge([
          widget.dj,
          _playlists,
          LookController.instance,
        ]),
        builder: (context, _) {
          return Column(
            children: [
              SizedBox(height: _panelH, child: _panel()),
              _tab(),
            ],
          );
        },
      ),
    );
  }

  Widget _tab() {
    final dj = widget.dj;
    final on = dj.automixOn;
    final accent = LookController.instance.accent(0);
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 120 && !_open) setState(() => _open = true);
          if (v < -120 && _open) setState(() => _open = false);
        },
        child: Container(
          height: _tabH,
          margin: const EdgeInsets.only(left: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? accent : const Color(0xFF3A3834),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 16,
                color: on ? SideDeckTheme.bg : SideDeckTheme.text,
              ),
              const SizedBox(width: 4),
              Text(
                on
                    ? 'AUTOMIX ${dj.automixIndex + 1}/${dj.automixQueueLength}'
                    : 'AUTOMIX',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: on ? SideDeckTheme.bg : SideDeckTheme.text,
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
    final lists = _playlists.playlists.where((p) => p.paths.isNotEmpty).toList();
    final selected = _selected(lists);
    final on = dj.automixOn;
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -120) setState(() => _open = false);
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: Color.lerp(look.body, Colors.black, 0.15),
          border: Border(bottom: BorderSide(color: look.accent(0), width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'AUTOMIX',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    on
                        ? 'Track ${dj.automixIndex + 1} of ${dj.automixQueueLength}'
                        : (dj.automixStatus ?? 'Fades your playlist together on the beat'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: SideDeckTheme.muted,
                    ),
                  ),
                ),
                if (on)
                  FilledButton.icon(
                    onPressed: dj.stopAutomix,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop'),
                  )
                else
                  FilledButton.icon(
                    onPressed: selected == null
                        ? null
                        : () {
                            dj.startAutomix(selected.paths, fadeSeconds: _fade);
                            setState(() => _open = false);
                          },
                    icon: const Icon(Icons.auto_mode, size: 18),
                    label: const Text('Start'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (lists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No playlists yet. Make one in Library, Playlists tab.',
                  style: TextStyle(color: SideDeckTheme.muted),
                ),
              )
            else
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final pl in lists)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${pl.name} · ${pl.paths.length}'),
                          selected: selected?.id == pl.id,
                          onSelected: on
                              ? null
                              : (_) => setState(() => _selectedId = pl.id),
                        ),
                      ),
                  ],
                ),
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
                    onChanged: on ? null : (v) => setState(() => _fade = v),
                  ),
                ),
                Text('${_fade.round()} s', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
