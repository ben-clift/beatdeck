import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/set_flow.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Automix drawer that pulls down from the top of the controller screen.
/// Drag the AUTOMIX tab down (or tap it) to open; drag up or tap to close.
/// Must be a child of a [Stack].
class AutomixPullDown extends StatefulWidget {
  const AutomixPullDown({super.key, required this.dj, required this.library});

  final DjController dj;
  final LibraryController library;

  @override
  State<AutomixPullDown> createState() => _AutomixPullDownState();
}

class _AutomixPullDownState extends State<AutomixPullDown> {
  double get _panelH => math.min(MediaQuery.of(context).size.height * 0.85, 380.0);
  static const _tabH = 24.0;

  final _playlists = PlaylistController();
  bool _open = false;
  double _fade = 20;
  double _offset = 10;
  FlowArc _arc = FlowArc.off;
  double _len = 60;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        // One-time reset so everyone starts from 20 s and 10 s.
        if (p.getBool('automix_times_v2') != true) {
          p.setBool('automix_times_v2', true);
          p.setDouble('automix_fade', 20);
          p.setDouble('automix_offset', 10);
        }
        _fade = p.getDouble('automix_fade') ?? _fade;
        _offset = p.getDouble('automix_offset') ?? _offset;
        _arc = FlowArc.values[(p.getInt('automix_arc') ?? 0).clamp(0, FlowArc.values.length - 1)];
        _len = p.getDouble('automix_len') ?? _len;
      });
    }).catchError((_) {});
  }

  void _saveTimes() {
    SharedPreferences.getInstance().then((p) {
      p.setDouble('automix_fade', _fade);
      p.setDouble('automix_offset', _offset);
      p.setInt('automix_arc', _arc.index);
      p.setDouble('automix_len', _len);
    }).catchError((_) {});
  }
  String? _selectedId;

  @override
  void dispose() {
    _playlists.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _open = !_open);

  static const _libShuffle = 'lib:shuffle';
  static const _libTempo = 'lib:tempo';
  static const _libAz = 'lib:az';

  /// What automix will play: the chosen option, else the first playlist,
  /// else the whole library.
  String _choice(List<Playlist> lists) {
    final id = _selectedId;
    if (id != null &&
        (id.startsWith('lib:') || lists.any((p) => p.id == id))) {
      return id;
    }
    return lists.isEmpty ? _libShuffle : lists.first.id;
  }

  List<String> _pathsFor(String id, List<Playlist> lists) {
    final tracks = List<LibraryTrack>.of(widget.library.tracks);
    switch (id) {
      case _libShuffle:
        tracks.shuffle();
        return [for (final t in tracks) t.path];
      case _libTempo:
        final analysed = tracks.where((t) => t.hasAnalysis).toList()
          ..sort((a, b) => a.bpm!.compareTo(b.bpm!));
        return [for (final t in analysed) t.path];
      case _libAz:
        tracks.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return [for (final t in tracks) t.path];
    }
    for (final p in lists) {
      if (p.id == id) return List<String>.of(p.paths);
    }
    return const [];
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
          widget.library,
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
    final choice = _choice(lists);
    final paths = _pathsFor(choice, lists);
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
        child: SingleChildScrollView(
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
                    onPressed: paths.isEmpty
                        ? null
                        : () {
                            dj.startAutomix(paths, fadeSeconds: _fade, startOffsetSeconds: _offset, arc: _arc, lengthMinutes: _len);
                            setState(() => _open = false);
                          },
                    icon: const Icon(Icons.auto_mode, size: 18),
                    label: const Text('Start'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (paths.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Nothing to play yet. Add music to the library, or for tempo '
                  'order analyse it first.',
                  style: TextStyle(color: SideDeckTheme.muted),
                ),
              ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (id, label) in [
                    (_libShuffle, 'Library · shuffle'),
                    (_libTempo, 'Library · slow to fast'),
                    (_libAz, 'Library · A to Z'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: choice == id,
                        onSelected: (_) {
                          setState(() => _selectedId = id);
                          if (on) widget.dj.automixSwitchTo(_pathsFor(id, lists));
                        },
                      ),
                    ),
                  for (final pl in lists)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${pl.name} · ${pl.paths.length}'),
                        selected: choice == pl.id,
                        onSelected: (_) {
                          setState(() => _selectedId = pl.id);
                          if (on) widget.dj.automixSwitchTo(_pathsFor(pl.id, lists));
                        },
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Set flow', style: TextStyle(fontSize: 12)),
                  for (final a in FlowArc.values)
                    ChoiceChip(
                      label: Text(a.label, style: const TextStyle(fontSize: 12)),
                      selected: _arc == a,
                      onSelected: on
                          ? null
                          : (_) {
                              setState(() => _arc = a);
                              _saveTimes();
                            },
                    ),
                ],
              ),
            ),
            Text(_arc.blurb,
                style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted)),
            if (_arc != FlowArc.off)
              Row(
                children: [
                  const SizedBox(
                    width: 150,
                    child: Text('Set length', style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: _len,
                      min: 20,
                      max: 180,
                      divisions: 32,
                      label: '${_len.round()} min',
                      onChanged: on
                          ? null
                          : (v) {
                              setState(() => _len = v);
                              _saveTimes();
                            },
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text('${_len.round()} min', style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            Row(
              children: [
                const SizedBox(
                  width: 150,
                  child: Text('Start mixing, seconds from the end',
                      style: TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: Slider(
                    value: _fade,
                    min: 4,
                    max: 60,
                    divisions: 56,
                    label: '${_fade.round()} s',
                    onChanged: on
                        ? null
                        : (v) {
                            setState(() => _fade = v);
                            _saveTimes();
                          },
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${_fade.round()} s', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(
                  width: 150,
                  child: Text('Next track starts this far in',
                      style: TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: Slider(
                    value: _offset,
                    min: 0,
                    max: 60,
                    divisions: 60,
                    label: '${_offset.round()} s',
                    onChanged: on
                        ? null
                        : (v) {
                            setState(() => _offset = v);
                            _saveTimes();
                          },
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${_offset.round()} s', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }
}
