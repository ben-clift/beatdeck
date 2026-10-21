import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/backup_tracks.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/automix/transition_style.dart';
import 'package:sidedeck/automix/set_flow.dart';
import 'package:sidedeck/soulseek/slsk_keeper.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/ui/genre_picker.dart';
import 'package:sidedeck/ui/soulseek_page.dart';
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
  double get _panelH => math.min(MediaQuery.of(context).size.height * 0.92, 560.0);
  static const _tabH = 24.0;

  final _playlists = PlaylistController();
  bool _open = false;
  double _fade = 120;
  double _offset = 10;
  FlowArc _arc = FlowArc.journey;
  TransitionStyle _style = TransitionStyle.auto;
  double _len = 60;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        // One-time reset so everyone starts from 20 s and 10 s.
        if (p.getBool('automix_times_v3') != true) {
          p.setBool('automix_times_v3', true);
          p.setDouble('automix_fade', 120);
          p.setDouble('automix_offset', 10);
        }
        _fade = p.getDouble('automix_fade') ?? _fade;
        _offset = p.getDouble('automix_offset') ?? _offset;
        _arc = FlowArc.values[(p.getInt('automix_arc') ?? FlowArc.journey.index).clamp(0, FlowArc.values.length - 1)];
        _len = p.getDouble('automix_len') ?? _len;
        _style = TransitionStyle.values[(p.getInt('automix_style') ?? 0).clamp(0, TransitionStyle.values.length - 1)];
      });
    }).catchError((_) {});
  }

  void _saveTimes() {
    SharedPreferences.getInstance().then((p) {
      p.setDouble('automix_fade', _fade);
      p.setDouble('automix_offset', _offset);
      p.setInt('automix_arc', _arc.index);
      p.setDouble('automix_len', _len);
      p.setInt('automix_style', _style.index);
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
    final away = BackupTracks.hidden.value;
    final tracks = [for (final t in widget.library.tracks) if (!away.contains(t.path)) t];
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
          soulseek,
          SlskKeeper.instance,
          AutoFetch.instance,
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

  Future<void> _start(List<String> paths) async {
    final dj = widget.dj;
    // The Soulseek helper is part of Start: stay signed in, fetch matches.
    if (_helper) {
      SlskKeeper.instance.setEnabled(true);
      SlskSetup.setAutoFetchForAutomix(true);
    }
    await dj.startAutomix(paths,
        fadeSeconds: _fade,
        startOffsetSeconds: _offset,
        arc: _arc,
        lengthMinutes: _len,
        style: _style);
    // Stay open when it could not start, so the reason stays visible.
    if (mounted && dj.automixOn) setState(() => _open = false);
  }

  bool get _helper => SlskKeeper.instance.enabled && SlskSetup.autoFetchForAutomix;

  Future<void> _setHelper(bool v) async {
    await SlskKeeper.instance.setEnabled(v);
    await SlskSetup.setAutoFetchForAutomix(v);
    if (mounted) setState(() {});
  }

  String _soulseekLine() {
    if (soulseek.online) {
      final af = AutoFetch.instance;
      if (af.running && af.status.isNotEmpty) return af.status;
      return 'Connected to Soulseek';
    }
    if (soulseek.status == SlskStatus.connecting) return 'Connecting to Soulseek…';
    final note = SlskKeeper.instance.note;
    return note.isEmpty ? 'Not connected to Soulseek' : note;
  }

  Widget _step(String n, String title, String help, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: SideDeckTheme.muted.withOpacity(0.35),
                child: Text(n, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 30, top: 2, bottom: 6),
            child: Text(help, style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
          ),
          child,
        ],
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
    final signedIn = soulseek.online || soulseek.status == SlskStatus.connecting;
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -120) setState(() => _open = false);
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        decoration: BoxDecoration(
          color: Color.lerp(look.body, Colors.black, 0.15),
          border: Border(bottom: BorderSide(color: look.accent(0), width: 3)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The one thing most people need: a big start button.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: on
                    ? FilledButton.icon(
                        onPressed: dj.stopAutomix,
                        icon: const Icon(Icons.stop),
                        label: Text(
                          'Stop Auto DJ  ·  track ${dj.automixIndex + 1} of ${dj.automixQueueLength}',
                          style: const TextStyle(fontSize: 16),
                        ),
                      )
                    : FilledButton.icon(
                        onPressed: paths.isEmpty ? null : () => _start(paths),
                        icon: const Icon(Icons.auto_mode),
                        label: const Text('Start Auto DJ', style: TextStyle(fontSize: 18)),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 12),
                child: Text(
                  on
                      ? (dj.automixStatus ?? 'Mixing for you. Deck 1 and 2 swap over automatically.')
                      : paths.isEmpty
                          ? 'Add music to your library first (folder icon in the Library), then come back.'
                          : (dj.automixStatus ??
                              'It plays your music and mixes each track into the next, all by itself.'),
                  style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted),
                ),
              ),
              _step(
                '1',
                'Play from',
                'Pick what it plays. You can change this while it is running.',
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final (id, label) in [
                        (_libShuffle, 'Whole library, shuffled'),
                        (_libTempo, 'Slow to fast'),
                        (_libAz, 'A to Z'),
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
              ),
              _step(
                '2',
                'Find new tracks for me',
                'Stays signed in to Soulseek and downloads a matching track '
                    'whenever nothing left in the list fits. Needs a free Soulseek account.',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Keep me connected and fetch matches'),
                      value: _helper,
                      onChanged: _setHelper,
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 10,
                          color: soulseek.online
                              ? Colors.greenAccent
                              : (soulseek.status == SlskStatus.connecting
                                  ? Colors.amber
                                  : Colors.redAccent),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_soulseekLine(),
                              style: const TextStyle(fontSize: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (!signedIn)
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SoulseekPage(library: widget.library),
                              ),
                            ),
                            child: const Text('Sign in'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _step(
                '3',
                'Pick a genre and shop',
                'Choose a genre, tempo and where to look. The track is downloaded '
                    'right away and plays next.',
                GenrePicker(library: widget.library),
              ),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('More options',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: const Text('Optional. The defaults work well.',
                      style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
                  children: [
                    _step(
                      '4',
                      'How tracks blend',
                      _style.blurb,
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final t in TransitionStyle.values)
                            ChoiceChip(
                              label: Text(t == TransitionStyle.auto ? 'Auto (recommended)' : t.label,
                                  style: const TextStyle(fontSize: 12)),
                              selected: _style == t,
                              onSelected: (_) {
                                setState(() => _style = t);
                                widget.dj.automixStyle = t;
                                _saveTimes();
                              },
                            ),
                        ],
                      ),
                    ),
                    _step(
                      '5',
                      'Order of the set',
                      _arc.blurb,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            children: [
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
                          if (_arc != FlowArc.off)
                            _slider('Set length', _len, 20, 180, 32, '${_len.round()} min', on,
                                (v) => setState(() => _len = v)),
                        ],
                      ),
                    ),
                    _step(
                      '6',
                      'Timing',
                      'When the blend starts, and where the next track begins.',
                      Column(
                        children: [
                          _slider('Start blending this long before the end', _fade, 4, 180, 176,
                              '${_fade.round()} s', on, (v) => setState(() => _fade = v)),
                          _slider('Next track starts this far in', _offset, 0, 60, 60,
                              '${_offset.round()} s', on, (v) => setState(() => _offset = v)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, int divisions,
      String shown, bool locked, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: shown,
            onChanged: locked
                ? null
                : (v) {
                    onChanged(v);
                    _saveTimes();
                  },
          ),
        ),
        SizedBox(width: 46, child: Text(shown, style: const TextStyle(fontSize: 12))),
      ],
    );
  }
}
