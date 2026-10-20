import 'package:flutter/material.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/soulseek_page.dart';

/// The track the suggestions are built around. Soulseek results use it to mark
/// files whose name shows a key or tempo that fits.
class SuggestSeed {
  static CamelotKey? key;
  static double bpm = 0;
}

/// Suggests what to play or download next, from the key and tempo of a deck.
class SuggestPage extends StatefulWidget {
  const SuggestPage({super.key, required this.dj, required this.library});

  final DjController dj;
  final LibraryController library;

  @override
  State<SuggestPage> createState() => _SuggestPageState();
}

class _SuggestPageState extends State<SuggestPage> {
  final _service = SuggestService();
  int _deck = 0;
  SeedInfo? _info;
  List<Suggestion>? _online;
  bool _busy = false;
  double _range = 8;
  int _count = 5;

  @override
  void initState() {
    super.initState();
    final dj = widget.dj;
    for (var i = 0; i < widget.dj.visibleDecks; i++) {
      if (dj.deck(i).loaded && dj.deck(i).playing) {
        _deck = i;
        break;
      }
      if (dj.deck(i).loaded && !dj.deck(_deck).loaded) _deck = i;
    }
    _refresh();
  }

  DeckState get _d => widget.dj.deck(_deck);

  CamelotKey? get _key => CamelotKey.fromIndex(_d.soundingKey);

  Future<void> _refresh() async {
    SuggestSeed.key = _key;
    SuggestSeed.bpm = _d.bpm;
    setState(() {
      _info = null;
      _online = null;
    });
    if (!_d.loaded) return;
    setState(() => _busy = true);
    final info = await _service.lookupSeed(_d.artist, _d.title);
    if (!mounted) return;
    setState(() => _info = info);
    if (info.artistId != null) {
      final list = await _service.candidates(info.artistId!, _d.artist);
      if (!mounted) return;
      setState(() => _online = list);
    }
    if (mounted) setState(() => _busy = false);
  }

  List<(LibraryTrack, KeyMatch, double)> _libraryMatches() {
    final k = _key;
    final out = <(LibraryTrack, KeyMatch, double)>[];
    for (final t in widget.library.tracks) {
      if (t.path == _d.path || t.key == null || t.key! < 0 || !t.hasAnalysis) continue;
      final ck = CamelotKey.fromIndex(t.key!);
      if (ck == null || k == null) continue;
      final m = keyMatch(k, ck);
      final gap = bpmGapPercent(_d.bpm, t.bpm!);
      if (m.score == 0 || gap.abs() > _range) continue;
      out.add((t, m, gap));
    }
    out.sort((a, b) {
      final s = b.$2.score.compareTo(a.$2.score);
      return s != 0 ? s : a.$3.abs().compareTo(b.$3.abs());
    });
    return out.take(25).toList();
  }

  void _find(String q) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SoulseekPage(library: widget.library, initialQuery: q),
    ));
  }

  Future<void> _loadTo(LibraryTrack t) async {
    final dj = widget.dj;
    // Prefer a stopped deck on the other side of the crossfader.
    final order = [for (var i = 0; i < 4; i++) i]
      ..sort((a, b) {
        int cost(int i) =>
            (dj.deck(i).playing ? 4 : 0) + (i % 2 == _deck % 2 ? 2 : 0) + (i == _deck ? 8 : 0);
        return cost(a).compareTo(cost(b));
      });
    final target = order.first;
    final ok = await dj.loadFile(target, t.path, title: t.title, artist: t.artist);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Loaded on deck ${target + 1}' : 'Load failed'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final k = _key;
    return Scaffold(
      appBar: AppBar(title: const Text('Suggest')),
      body: ListenableBuilder(
        listenable: widget.dj,
        builder: (context, _) {
          if (!_d.loaded) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Load a track on a deck first. Suggestions are built around it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SideDeckTheme.muted),
                ),
              ),
            );
          }
          final lib = _libraryMatches();
          final online = (_online ?? const <Suggestion>[])
              .where((s) => s.bpm == 0 || bpmGapPercent(_d.bpm, s.bpm).abs() <= _range)
              .toList()
            ..sort((a, b) {
              double g(Suggestion s) => s.bpm == 0 ? 50 : bpmGapPercent(_d.bpm, s.bpm).abs();
              return g(a).compareTo(g(b));
            });
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < widget.dj.visibleDecks; i++)
                    if (widget.dj.deck(i).loaded)
                      ChoiceChip(
                        label: Text('Deck ${i + 1}'),
                        selected: _deck == i,
                        onSelected: (_) {
                          _deck = i;
                          _refresh();
                        },
                      ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _d.artist.isEmpty ? _d.title : '${_d.artist} - ${_d.title}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${k?.code ?? '?'}  ·  ${formatKey(_d.soundingKey)}  ·  ${_d.bpm.toStringAsFixed(1)} BPM',
                style: const TextStyle(color: SideDeckTheme.muted),
              ),
              const SizedBox(height: 4),
              Text(
                _info == null
                    ? (_busy ? 'Looking it up online…' : '')
                    : _info!.genres.isEmpty
                        ? (_info!.error ?? 'No genre found online')
                        : _info!.genres.join(' · '),
              ),
              const SizedBox(height: 14),
              const Text('Keys that mix in',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              if (k == null)
                const Text('Key not detected yet for this track.',
                    style: TextStyle(color: SideDeckTheme.muted))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final (c, m) in compatibleKeys(k))
                      Chip(
                        label: Text('${c.code}  ${m.label}'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('Tempo within'),
                  Expanded(
                    child: Slider(
                      value: _range,
                      min: 3,
                      max: 16,
                      divisions: 13,
                      label: '±${_range.round()}%',
                      onChanged: (v) => setState(() => _range = v),
                    ),
                  ),
                  Text('±${_range.round()}%'),
                ],
              ),
              const SizedBox(height: 6),
              Text('In your library (${lib.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (lib.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Nothing analysed matches yet. Analyse the library from its menu.',
                    style: TextStyle(color: SideDeckTheme.muted),
                  ),
                ),
              for (final (t, m, gap) in lib)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.artist.isEmpty ? t.title : '${t.artist} - ${t.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${CamelotKey.fromIndex(t.key!)?.code}  ·  ${t.bpm!.toStringAsFixed(0)} BPM'
                    '  ·  ${gap >= 0 ? '+' : ''}${gap.toStringAsFixed(1)}% tempo'
                    '  ·  ${m.label}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.play_circle_outline),
                    onPressed: () => _loadTo(t),
                  ),
                ),
              const SizedBox(height: 14),
              ListenableBuilder(
                listenable: AutoFetch.instance,
                builder: (context, _) {
                  final af = AutoFetch.instance;
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: SideDeckTheme.muted),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Auto-fetch from Soulseek',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        const Text(
                          'Looks up what goes with this track, downloads the best '
                          'match, then carries on from that one, each as soon as '
                          'the last has finished. Only fetch music you have the '
                          'right to have.',
                          style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
                        ),
                        Row(
                          children: [
                            const Text('How many'),
                            Expanded(
                              child: Slider(
                                value: _count.toDouble(),
                                min: 1,
                                max: 20,
                                divisions: 19,
                                label: '$_count',
                                onChanged: af.running
                                    ? null
                                    : (v) => setState(() => _count = v.round()),
                              ),
                            ),
                            Text('$_count'),
                          ],
                        ),
                        Row(
                          children: [
                            FilledButton(
                              onPressed: af.running
                                  ? af.stop
                                  : () => af.start(
                                        artist: _d.artist,
                                        title: _d.title,
                                        seedBpm: _d.bpm,
                                        seedKey: _key,
                                        library: widget.library,
                                        count: _count,
                                        tempoRange: _range,
                                      ),
                              child: Text(af.running ? 'Stop' : 'Start'),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                af.status.isEmpty
                                    ? ''
                                    : '${af.status}  (${af.fetched}/${af.limit})',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        for (final l in af.log)
                          Text('✓ $l', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('Find online (${online.length})',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Tempo is checked before you download. The key is only known '
                  'once the file is in, so Soulseek results are marked when the '
                  'file name shows a key that fits.',
                  style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
                ),
              ),
              for (final s in online)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${s.artist} - ${s.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${s.bpm > 0 ? '${s.bpm.round()} BPM  ·  ' : ''}${s.reason}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.travel_explore),
                    tooltip: 'Find on Soulseek',
                    onPressed: () => _find(s.query),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
