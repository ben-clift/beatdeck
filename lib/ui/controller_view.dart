import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/look_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/automix_pulldown.dart';
import 'package:sidedeck/ui/controller_widgets.dart';
import 'package:sidedeck/ui/equaliser_view.dart';
import 'package:sidedeck/state/backup_tracks.dart';
import 'package:sidedeck/state/ratings.dart';
import 'package:sidedeck/ui/fx_pulldown.dart';
import 'package:sidedeck/ui/library_drawer.dart';
import 'package:sidedeck/ui/track_picker.dart';
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
  bool get _strip => widget.dj.stripOn;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _samplerSheet() {
    final dj = widget.dj;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) => ListenableBuilder(
        listenable: dj,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Sampler',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                const Text('Tap to fire. Hold to choose a sound.',
                    style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              ]),
              const SizedBox(height: 10),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
                children: [
                  for (var i = 0; i < DjController.samplerSlots; i++)
                    GestureDetector(
                      onTapDown: (_) => dj.fireSample(i),
                      onLongPress: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: nativeAudioPickerExtensions(),
                          withData: false,
                        );
                        final path = r?.files.single.path;
                        if (path != null) await dj.loadSample(i, path);
                      },
                      onDoubleTap: () => dj.stopSample(i),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: dj.samplePaths[i] == null
                              ? Colors.transparent
                              : const Color(0xFF1E1E1E),
                          border: Border.all(
                            color: dj.samplePaths[i] == null
                                ? SideDeckTheme.muted
                                : const Color(0xFFFF9F1C),
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          dj.samplePaths[i] == null
                              ? 'EMPTY'
                              : dj.sampleNames[i],
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
              Row(children: [
                const SizedBox(width: 60, child: Text('Volume')),
                Expanded(
                  child: Slider(
                    value: dj.samplerVolume,
                    max: 1.5,
                    onChanged: dj.setSamplerVolume,
                  ),
                ),
              ]),
              const Text('Double-tap a pad to stop its sound.',
                  style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
            ],
          ),
        ),
      ),
    );
  }

  void _cueSheet() {
    final dj = widget.dj;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) => ListenableBuilder(
        listenable: dj,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Headphone cue',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final (i, label) in [
                    (0, 'Off'),
                    (1, 'Splitter cable'),
                    (2, 'Multichannel interface'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: dj.cueMode == i,
                      onSelected: (_) => dj.setCueMode(i),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                dj.cueMode == 1
                    ? 'Use a headphone splitter. Master plays in one ear and the '
                        'cue in the other, as mono. Then switch the splitter side '
                        'that feeds your speakers.'
                    : dj.cueMode == 2
                        ? 'Cue goes out on outputs 3 and 4 of a USB audio interface.'
                        : 'Tap the headphone button on a deck to send it to the cue.',
                style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
              Row(children: [
                const SizedBox(width: 70, child: Text('Volume')),
                Expanded(
                  child: Slider(
                    value: dj.cueVolume,
                    max: 1.5,
                    onChanged: (v) => dj.setCueMode(dj.cueMode, volume: v),
                  ),
                ),
              ]),
              Row(children: [
                const SizedBox(width: 70, child: Text('Cue / Master')),
                Expanded(
                  child: Slider(
                    value: dj.cueMix,
                    onChanged: (v) => dj.setCueMode(dj.cueMode, mix: v),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  String _mmss(double s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s.floor() % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  Future<void> _toggleRecord() async {
    final dj = widget.dj;
    final messenger = ScaffoldMessenger.of(context);
    if (dj.recording) {
      final path = dj.stopRecording();
      final ok = path != null && File(path).existsSync() && File(path).lengthSync() > 1000;
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(path == null
            ? 'Recording stopped'
            : ok
                ? 'Saved ${path.split(RegExp(r'[\\/]')).last}'
                : 'Recording is empty: nothing was playing?'),
        action: ok
            ? SnackBarAction(
                label: 'Share',
                onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(path)])),
              )
            : null,
      ));
      final f = widget.library.folderPath;
      if (ok && f != null && f.isNotEmpty && path.startsWith(f)) {
        widget.library.scanDirectory(f, persist: false);
      }
      return;
    }
    // The music folder is tried first; Android often refuses writes there,
    // so fall back to the app's own folder, which always works.
    final dirs = <String>[];
    final lib = widget.library.folderPath;
    if (lib != null && lib.isNotEmpty) dirs.add(lib);
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) dirs.add('${ext.path}/recordings');
    } catch (_) {}
    dirs.add('${(await getApplicationDocumentsDirectory()).path}/recordings');
    String? path;
    for (final d in dirs) {
      try {
        await Directory(d).create(recursive: true);
      } catch (_) {}
      path = dj.startRecording(d);
      if (path != null) break;
      DebugLog.add('record', 'could not write to $d');
    }
    if (path == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not start recording (no folder to write to)')),
      );
    } else {
      DebugLog.add('record', 'recording to $path');
      if (!path.startsWith(lib ?? '\u0000')) {
        messenger.showSnackBar(SnackBar(
          content: Text('Recording in the app folder: ${path.split(RegExp(r'[\\/]')).last}'),
        ));
      }
    }
  }

  List<String> get _titles => [
        'LIBRARY',
        'DECKS 1 · 2',
        if (widget.dj.showDecks34) 'DECKS 3 · 4',
        'EQUALISER',
      ];

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
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    color: _page == i ? SideDeckTheme.text : Colors.transparent,
                    child: Text(
                      _titles[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                        color: _page == i
                            ? SideDeckTheme.bg
                            : SideDeckTheme.muted,
                      ),
                    ),
                  ),
                ),
              GestureDetector(
                onTap: _cueSheet,
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: widget.dj.cueMode == 0
                      ? Colors.transparent
                      : const Color(0xFF2E9BFF),
                  child: Text(
                    'HEADPHONES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: widget.dj.cueMode == 0
                          ? SideDeckTheme.muted
                          : Colors.black,
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _toggleRecord,
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: widget.dj.recording
                      ? const Color(0xFFE5392C)
                      : Colors.transparent,
                  child: Text(
                    widget.dj.recording
                        ? 'REC ${_mmss(widget.dj.recordSeconds)}'
                        : 'REC',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: widget.dj.recording
                          ? Colors.white
                          : SideDeckTheme.muted,
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => widget.dj.setStripOn(!_strip),
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: _strip ? const Color(0xFF3DDC57) : Colors.transparent,
                  child: Text(
                    'LEVELS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: _strip ? SideDeckTheme.bg : SideDeckTheme.muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // The full equaliser page has its own spectrum, so the strip waits.
        if (_strip && _page != _titles.length - 1) EqualiserStrip(dj: widget.dj),
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
              _DeckPair(dj: widget.dj, library: widget.library, left: 0, right: 1),
              if (widget.dj.showDecks34)
                _DeckPair(dj: widget.dj, library: widget.library, left: 2, right: 3),
              EqualiserView(dj: widget.dj),
            ],
          ),
        ),
      ],
        ),
        AutomixPullDown(dj: widget.dj, library: widget.library),
        FxPullDown(dj: widget.dj),
      ],
    );
  }
}

/// Two decks and the mixer between them, drawn on a fixed canvas that scales
/// to the screen.
class _DeckPair extends StatelessWidget {
  const _DeckPair({
    required this.dj,
    required this.library,
    required this.left,
    required this.right,
  });

  final DjController dj;
  final LibraryController library;
  final int left;
  final int right;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([dj, LookController.instance]),
      builder: (context, _) {
        // The canvas takes the shape of the screen so the decks fill it top to
        // bottom, then scales to fit.
        return LayoutBuilder(
          builder: (context, c) {
            final ratio = c.maxWidth / math.max(1.0, c.maxHeight);
            final h = ratio >= 920 / 520
                ? 520.0
                : math.min(760.0, 920 / ratio);
            final w = h * ratio;
            return FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: w,
                height: h,
                child: Row(
                  children: [
                    Expanded(
                      flex: 460,
                      child: _DeckPanel(dj: dj, library: library, index: left),
                    ),
                    SizedBox(
                      width: 200,
                      child: _MixerPanel(dj: dj, left: left, right: right),
                    ),
                    Expanded(
                      flex: 460,
                      child: _DeckPanel(dj: dj, library: library, index: right),
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
}

enum _PadMode { hotCue, loop, jump, fx }

class _DeckPanel extends StatefulWidget {
  const _DeckPanel({
    required this.dj,
    required this.library,
    required this.index,
  });

  final DjController dj;
  final LibraryController library;
  final int index;

  @override
  State<_DeckPanel> createState() => _DeckPanelState();
}

class _DeckPanelState extends State<_DeckPanel> {
  _PadMode _mode = _PadMode.hotCue;
  static const _loopBars = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0];
  static const _jumpBeats = [-1 / 16, 1 / 16, -1 / 4, 1 / 4, -1 / 2, 1 / 2, -1.0, 1.0, -4.0, 4.0, -16.0, 16.0];

  static String _jumpLabel(double b) {
    final sign = b > 0 ? '+' : '-';
    final a = b.abs();
    if (a >= 1) return '$sign${a.round()}';
    return '$sign' '1/${(1 / a).round()}';
  }
  // Tempo fader range: plus or minus 8 percent.
  static const _ranges = [0.06, 0.10, 0.16, 0.50];
  int _rangeIdx = 1;
  double get _range => _ranges[_rangeIdx];

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
              child: Row(
                children: [
                  Expanded(child: _deckBody(d, i, remaining, heard)),
                  const SizedBox(width: 8),
                  // Pitch fader runs the full height of the deck.
                  SizedBox(width: 56, child: _tempo(d)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _backup(DeckState d) async {
    final path = d.path;
    if (path == null || path.isEmpty) return;
    final err = widget.dj.removeFromDeck(widget.index);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await BackupTracks.add(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved in the playlist "Backup tracks". Play it from Auto DJ or the library another time.')),
    );
  }

  Future<void> _confirmRemove(DeckState d) async {
    final starPath = d.path;
    if (starPath != null && Ratings.instance.starsOf(starPath) > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('It has stars, so it is kept. Take the stars off first to remove it.')),
      );
      return;
    }
    final path = d.path;
    final name = d.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this track?'),
        content: Text(
            '$name\n\nIt comes off the deck, is deleted from this phone, and will not be played or searched for again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = widget.dj.removeFromDeck(widget.index);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (path != null && path.isNotEmpty) {
      await Dislikes.instance.add(path);
      final match = widget.library.tracks.where((t) => t.path == path).toList();
      if (match.isNotEmpty) {
        await widget.library.deleteTracks(match);
      } else {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Removed. It will not be played or searched for again.')),
    );
  }

  void _openPicker() => showTrackPicker(
        context,
        dj: widget.dj,
        library: widget.library,
        deck: widget.index,
      );

  Widget _deckBody(DeckState d, int i, double remaining, double heard) {
    return Column(
      children: [
        if (widget.dj.moreLikeStatus != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0x33FFC107),
            child: Text(
              widget.dj.moreLikeStatus!,
              style: const TextStyle(fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openPicker,
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                color: _accent,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    color: SideDeckTheme.bg,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d.loaded ? d.title : (widget.dj.deckHint(i) ?? 'Tap to load a track'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.library_music, size: 18),
              if (d.loaded && widget.dj.automixOn)
                IconButton(
                  tooltip: 'Skip this track',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.skip_next, size: 22),
                  onPressed: () {
                    final err = widget.dj.automixSkip(widget.index);
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    }
                  },
                ),
              if (d.loaded && widget.dj.automixOn)
                IconButton(
                  tooltip: 'More like this: library first, then Soulseek',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.auto_awesome, size: 20),
                  onPressed: () {
                    final msg = widget.dj.automixMoreLike(widget.index);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                  },
                ),
              if (d.loaded)
                IconButton(
                  tooltip: 'Less: steer away from this artist / genre / tempo',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.do_not_disturb_on_outlined, size: 20),
                  onPressed: () {
                    final msg = widget.dj.automixLessLike(widget.index);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                  },
                ),
              if (d.loaded)
                IconButton(
                  tooltip: 'Put in Backup tracks to come back to another time',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                  onPressed: () => _backup(d),
                ),
              if (d.loaded)
                IconButton(
                  tooltip: 'Remove this track and never play it again',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  onPressed: () => _confirmRemove(d),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              heard > 0 ? heard.toStringAsFixed(1) : '--',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: _accent,
              ),
            ),
            const Text(' BPM  ',
                style: TextStyle(fontSize: 10, color: SideDeckTheme.muted)),
            Text(
              d.key >= 0 ? formatKey(d.soundingKey) : '',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            if (d.loaded)
              GestureDetector(
                onTap: () => widget.dj.toggleDeckCue(widget.index),
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  color: d.cue ? const Color(0xFF2E9BFF) : Colors.transparent,
                  child: Icon(Icons.headphones,
                      size: 16, color: d.cue ? Colors.black : SideDeckTheme.muted),
                ),
              ),
            if (d.loaded) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => widget.dj.setKeyShift(widget.index, d.keyShift - 1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('−',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
              ),
              GestureDetector(
                onTap: () => widget.dj.setKeyShift(widget.index, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  color: d.keyShift == 0 ? Colors.transparent : _accent,
                  child: Text(
                    d.keyShift == 0
                        ? 'KEY'
                        : 'KEY ${d.keyShift > 0 ? '+' : ''}${d.keyShift}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: d.keyShift == 0 ? SideDeckTheme.muted : Colors.black,
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => widget.dj.setKeyShift(widget.index, d.keyShift + 1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('+',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
            const Spacer(),
            Text(
              d.loaded ? '-${formatDuration(remaining)}' : '',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _wave(d),
        if (d.loaded && d.path != null)
          AnimatedBuilder(
            animation: Ratings.instance,
            builder: (context, _) {
              final path = d.path!;
              final n = Ratings.instance.starsOf(path);
              return SizedBox(
                height: 26,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(n > 0 ? 'Kept  ' : 'Star to keep  ',
                        style: const TextStyle(fontSize: 10, color: SideDeckTheme.muted)),
                    for (var i = 1; i <= 3; i++)
                      GestureDetector(
                        onTap: () => Ratings.instance.tap(path, i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(i <= n ? Icons.star : Icons.star_border,
                              size: 20,
                              color: i <= n ? const Color(0xFFFFC107) : SideDeckTheme.muted),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 4),
        _transport(d),
        const SizedBox(height: 4),
        _modeRow(),
        const SizedBox(height: 4),
        // A big jog wheel with the pads in a column beside it.
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final size = math.min(c.maxWidth, c.maxHeight);
                    return Center(child: _jog(d, size < 80 ? 80 : size));
                  },
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(width: 124, child: _pads(d)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _wave(DeckState d) {
    return Container(
      height: 104,
      color: look.well,
      child: d.loaded && d.duration > 0
          ? WaveformView(
              playing: d.playing,
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
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPicker,
              child: Center(
              child: Text(
                'TAP TO LOAD A TRACK',
                style: TextStyle(
                  fontSize: 13,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: look.controlHigh,
                ),
              ),
            ),
            ),
    );
  }

  Widget _jog(DeckState d, double size) {
    // 33 1/3 rpm look: one turn every 1.8 seconds of track.
    final angle = d.position / 1.8 * 2 * math.pi;
    return Listener(
      onPointerDown: (_) => widget.dj.jogTouch(widget.index),
      onPointerUp: (_) => widget.dj.jogRelease(widget.index),
      onPointerCancel: (_) => widget.dj.jogRelease(widget.index),
      child: GestureDetector(
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
      ),
    );
  }

  Widget _tempo(DeckState d) {
    final v = (0.5 + (d.rate - 1.0) / (2 * _range)).clamp(0.0, 1.0).toDouble();
    final pct = (d.rate - 1.0) * 100;
    return Column(
      children: [
        Text(
          '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
        ),
        const Text('+', style: TextStyle(fontSize: 11, color: SideDeckTheme.muted)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => ControllerFader(
              value: v,
              height: c.maxHeight,
              accent: _accent,
              ticks: true,
              onChanged: (x) {
                final snapped = (x - 0.5).abs() < 0.01 ? 0.5 : x;
                widget.dj
                    .setRate(widget.index, 1.0 + (snapped - 0.5) * 2 * _range);
              },
            ),
          ),
        ),
        const Text('-', style: TextStyle(fontSize: 11, color: SideDeckTheme.muted)),
        const SizedBox(height: 2),
        _smallButton(
          '±${(_range * 100).round()}%',
          false,
          () => setState(() => _rangeIdx = (_rangeIdx + 1) % _ranges.length),
        ),
        const SizedBox(height: 3),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: on ? _accent : look.control,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
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
            height: 46,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: on ? _accent : look.control,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 17,
                letterSpacing: 1,
                color: on ? SideDeckTheme.bg : SideDeckTheme.text,
              ),
            ),
          ),
        ),
      );
    }

    Widget syncButton(
      String label,
      VoidCallback onTap, {
      bool on = false,
      VoidCallback? onLong,
      bool small = false,
    }) {
      return Expanded(
        child: GestureDetector(
          onTap: d.loaded ? onTap : null,
          onLongPress: d.loaded ? onLong : null,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: on ? (small ? Colors.white : _accent) : look.control,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: small ? 11 : 15,
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
        Expanded(
          flex: 2,
          child: Row(
            children: [
              syncButton(
                'SYNC',
                () => widget.dj.sync(widget.index),
                on: d.synced,
                onLong: () => widget.dj.unsync(widget.index),
              ),
              syncButton(
                'MASTER',
                () => widget.dj.setMasterDeck(widget.index),
                on: widget.dj.masterDeck == widget.index,
                small: true,
              ),
            ],
          ),
        ),
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
            height: 30,
            alignment: Alignment.center,
            color: on ? SideDeckTheme.text : look.control,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
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
        chip('FX', _PadMode.fx),
      ],
    );
  }

  Widget _pads(DeckState d) {
    final pads = <Widget>[];
    for (var k = 0; k < (_mode == _PadMode.jump ? _jumpBeats.length : 8); k++) {
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
        case _PadMode.fx:
          final effect = widget.dj.padFx[widget.index][k];
          pads.add(_pad(
            DjController.fxNames[effect],
            widget.dj.deckFxOn[widget.index].contains(effect),
            () => widget.dj.toggleDeckFx(widget.index, k),
            onLong: () => _assignFx(k),
          ));
        case _PadMode.jump:
          final b = _jumpBeats[k];
          pads.add(_pad(
            _jumpLabel(b),
            widget.dj.deckFxOn[widget.index].isNotEmpty && _lastJumpPad == k,
            () {
              void jump(double x) => x.abs() >= 1
                  ? widget.dj.beatJump(widget.index, x.round())
                  : widget.dj.nudgeBeats(widget.index, x);
              final now = DateTime.now();
              if (_lastJumpPad == k && now.difference(_lastJumpAt).inMilliseconds < 380) {
                // Double tap: undo the first jump and switch the effects
                // on or off, using this pad's length as the effect setting.
                jump(-b);
                _lastJumpAt = DateTime(2000);
                widget.dj.toggleDeckFxAll(widget.index, beats: b.abs());
              } else {
                _lastJumpPad = k;
                _lastJumpAt = now;
                jump(b);
              }
            },
          ));
      }
    }
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 4.0;
        final cols = _mode == _PadMode.jump ? 4 : 2;
        final rows = _mode == _PadMode.jump ? 3 : 4;
        final cellW = (c.maxWidth - gap * (cols - 1)) / cols;
        final cellH = (c.maxHeight - gap * (rows - 1)) / rows;
        return GridView.count(
          crossAxisCount: cols,
          childAspectRatio: cellW / math.max(1.0, cellH),
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: pads,
        );
      },
    );
  }

  /// Long press on an effect pad: pick which effect lives on it.
  Future<void> _assignFx(int pad) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) => SafeArea(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Put an effect on this pad',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            for (var e = 0; e < DjController.fxNames.length; e++)
              Padding(
                padding: const EdgeInsets.all(4),
                child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(ctx, e),
                  child: Text(DjController.fxNames[e]),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null) widget.dj.assignPadFx(widget.index, pad, picked);
  }

  int _lastJumpPad = -1;
  DateTime _lastJumpAt = DateTime(2000);

  Widget _pad(String label, bool on, VoidCallback onTap, {VoidCallback? onLong}) {
    return GestureDetector(
      onTap: _d.loaded ? onTap : null,
      onLongPress: onLong,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? _accent : const Color(0xFF1B1B1B),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: on ? Colors.white70 : const Color(0xFF6F6F6F),
            width: 2,
          ),
          boxShadow: on
              ? [BoxShadow(color: _accent.withValues(alpha: 0.6), blurRadius: 10)]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: on ? SideDeckTheme.bg : SideDeckTheme.text,
              ),
            ),
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
    // Bezel and ribbed rim that turns with the track.
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF050505));
    canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF3A3A3A),
    );
    const ribs = 48;
    final rim = Rect.fromCircle(center: c, radius: r - 5);
    for (var i = 0; i < ribs; i++) {
      canvas.drawArc(
        rim,
        angle + i * 2 * math.pi / ribs,
        math.pi / ribs,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = const Color(0xFF1E1E1E),
      );
    }
    // Platter with a lit edge when playing.
    final platter = r * 0.78;
    canvas.drawCircle(c, platter, Paint()..color = const Color(0xFF0C0C0C));
    canvas.drawCircle(
      c,
      platter - 2,
      Paint()
        ..shader = RadialGradient(
          colors: [face, ring, const Color(0xFF121212)],
          stops: const [0.0, 0.7, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: platter)),
    );
    canvas.drawCircle(
      c,
      platter,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = playing ? accent : inactive,
    );
    // Centre disc with the light ring.
    canvas.drawCircle(c, r * 0.36, Paint()..color = const Color(0xFF181818));
    canvas.drawCircle(
      c,
      r * 0.27,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFCFCFCF),
    );
    // Position marker.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    canvas.drawLine(
      Offset(0, -(platter * 0.62)),
      Offset(0, -(platter - 4)),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
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
      decoration: LookController.instance.panelDecoration(Colors.white),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ControllerKnob(
                label: 'MASTER',
                size: 56,
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
              trackHeight: 5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 13),
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
    return LayoutBuilder(
      builder: (context, box) {
        final k = (box.maxHeight / 5 - 16).clamp(32.0, 56.0).toDouble();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ControllerKnob(
                    label: 'TRIM',
                    size: k,
                    accent: c,
                    value: (d.gain / 2).clamp(0.0, 1.0).toDouble(),
                    center: 0.5,
                    onChanged: (v) => dj.setGain(i, v * 2),
                  ),
                  ControllerKnob(
                    label: 'HI',
                    size: k,
                    accent: c,
                    value: eqIn(d.eqHigh),
                    onChanged: (v) => dj.setEq(i, high: eqOut(v)),
                  ),
                  ControllerKnob(
                    label: 'MID',
                    size: k,
                    accent: c,
                    value: eqIn(d.eqMid),
                    onChanged: (v) => dj.setEq(i, mid: eqOut(v)),
                  ),
                  ControllerKnob(
                    label: 'LOW',
                    size: k,
                    accent: c,
                    value: eqIn(d.eqLow),
                    onChanged: (v) => dj.setEq(i, low: eqOut(v)),
                  ),
                  ControllerKnob(
                    label: 'FILTER',
                    size: k,
                    accent: c,
                    value: ((d.filter + 1) / 2).clamp(0.0, 1.0).toDouble(),
                    onChanged: (v) => dj.setFilter(i, v * 2 - 1),
                  ),
                ],
              ),
            ),
            ControllerFader(
              value: d.fader.clamp(0.0, 1.0).toDouble(),
              height: box.maxHeight - 8,
              accent: c,
              ticks: true,
              onChanged: (v) => dj.setFader(i, v),
            ),
          ],
        );
      },
    );
  }
}
