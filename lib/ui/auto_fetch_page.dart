import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/storage_guard.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/suggest/suggest_service.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Pick a genre and tempo, press start, and tracks keep arriving from
/// Soulseek into the library.
class AutoFetchPage extends StatefulWidget {
  const AutoFetchPage({super.key, required this.library});

  final LibraryController library;

  @override
  State<AutoFetchPage> createState() => _AutoFetchPageState();
}

class _AutoFetchPageState extends State<AutoFetchPage> {
  final _genre = TextEditingController(text: AutoFetch.instance.genre);
  late RangeValues _bpm = RangeValues(
    AutoFetch.instance.bpmMin.clamp(70.0, 179.0).toDouble(),
    AutoFetch.instance.bpmMax.clamp(71.0, 180.0).toDouble(),
  );
  late double _count = AutoFetch.instance.count.toDouble();
  late bool _endless = AutoFetch.instance.endless;
  late String _source = AutoFetch.instance.source;
  late final _pasted = TextEditingController(text: AutoFetch.instance.pasted);
  late bool _chartTempo = AutoFetch.instance.chartTempo;
  List<(int, String)> _charts = const [];
  List<Suggestion> _tracks = const [];
  bool _loadingTracks = false;
  int _loadedFor = -1;
  final Set<int> _picked = {};
  bool _underground = false;
  bool _yearFilter = false;
  RangeValues _years = const RangeValues(1995, 2026);

  bool _yearShown(Suggestion s) =>
      !_yearFilter || (s.year > 0 && s.year >= _years.start && s.year <= _years.end);
  // Tracks already shown this session, so a reload brings only new ones.
  static final Set<String> _seen = {};

  Future<void> _loadTracks() async {
    final af = AutoFetch.instance;
    final id = _charts.any((c) => c.$1 == af.chartId) ? af.chartId : (_charts.isEmpty ? -1 : _charts.first.$1);
    if (id < 0 || _loadingTracks) return;
    final name = _charts.firstWhere((c) => c.$1 == id).$2;
    setState(() {
      _loadingTracks = true;
      _loadedFor = id;
      _picked.clear();
    });
    final svc = SuggestService();
    final t = _underground
        ? await svc.underground(
            name,
            bpmMin: _chartTempo ? _bpm.start : null,
            bpmMax: _chartTempo ? _bpm.end : null,
            skip: _seen,
          )
        : await svc.chart(
            id,
            name,
            bpmMin: _chartTempo ? _bpm.start : null,
            bpmMax: _chartTempo ? _bpm.end : null,
            want: 50,
            needDetails: true,
            skip: _seen,
          );
    for (final s in t) {
      _seen.add('${s.artist} ${s.title}'.toLowerCase());
    }
    if (!mounted) return;
    setState(() {
      _tracks = t;
      _loadingTracks = false;
    });
  }

  void _download(List<Suggestion> list) {
    if (list.isEmpty) return;
    if (!soulseek.online) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to Soulseek first')),
      );
      return;
    }
    AutoFetch.instance.enqueueTracks(list, widget.library);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added ${list.length} to download')),
    );
    setState(_picked.clear);
  }

  @override
  void initState() {
    super.initState();
    SuggestService().genres().then((g) {
      if (mounted) {
        setState(() => _charts = g);
        if (_source == 'chart') _loadTracks();
      }
    });
  }

  void _remember() {
    final af = AutoFetch.instance;
    af.genre = _genre.text.trim().isEmpty ? 'house' : _genre.text.trim();
    af.bpmMin = _bpm.start;
    af.bpmMax = _bpm.end;
    af.count = _count.round();
    af.endless = _endless;
    af.source = _source;
    af.pasted = _pasted.text;
    af.chartTempo = _chartTempo;
    af.save();
  }

  bool _fits(GenreInfo g) =>
      math.min(g.max, _bpm.end) - math.max(g.min, _bpm.start) > 0;

  List<GenreInfo> _sortedGenres() {
    final all = [for (final grp in genreGroups) ...grp.$2];
    all.sort((a, b) {
      final fa = _fits(a) ? 0 : 1;
      final fb = _fits(b) ? 0 : 1;
      return fa != fb ? fa.compareTo(fb) : a.min.compareTo(b.min);
    });
    return all;
  }

  @override
  void dispose() {
    _remember();
    _genre.dispose();
    _pasted.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final af = AutoFetch.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('DJ Charts')),
      body: ListenableBuilder(
        listenable: Listenable.merge([af, soulseek]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text(
              'Choose a genre and a tempo. It finds tracks that fit online, '
              'searches Soulseek, downloads the best match into your library, '
              'then moves straight on to the next. Only fetch music you have '
              'the right to have.',
              style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'chart', label: Text('Charts')),
                ButtonSegment(value: 'genre', label: Text('Genre')),
                ButtonSegment(value: 'list', label: Text('My list')),
              ],
              selected: {_source},
              onSelectionChanged: (v) {
                setState(() => _source = v.first);
                if (v.first == 'chart' && _tracks.isEmpty) _loadTracks();
              },
            ),
            const SizedBox(height: 10),
            if (_source == 'chart') ...[
              const Text(
                'The most played tracks of a genre right now, from Deezer\'s '
                'charts. Dance and Electro are the dance floor ones.',
                style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
              const SizedBox(height: 6),
              if (_charts.isEmpty)
                const Text('Loading charts…')
              else
                DropdownButton<int>(
                  isExpanded: true,
                  value: _charts.any((c) => c.$1 == AutoFetch.instance.chartId)
                      ? AutoFetch.instance.chartId
                      : _charts.first.$1,
                  items: [
                    for (final c in _charts)
                      DropdownMenuItem(value: c.$1, child: Text(c.$2)),
                  ],
                  onChanged: (v) {
                    setState(() {
                      final c = _charts.firstWhere((e) => e.$1 == v);
                      af.chartId = c.$1;
                      af.chartName = c.$2;
                      _tracks = const [];
                    });
                    _loadTracks();
                  },
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Underground'),
                subtitle: const Text('Less-played tracks, not the big hits',
                    style: TextStyle(fontSize: 12)),
                value: _underground,
                onChanged: (v) {
                  setState(() {
                    _underground = v;
                    _tracks = const [];
                  });
                  _loadTracks();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only tracks in the tempo range below'),
                value: _chartTempo,
                onChanged: (v) {
                  setState(() => _chartTempo = v);
                  _loadTracks();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only these years'),
                subtitle: Text(
                  _yearFilter
                      ? '${_years.start.round()} to ${_years.end.round()}'
                      : 'Off: any year',
                  style: const TextStyle(fontSize: 12),
                ),
                value: _yearFilter,
                onChanged: (v) => setState(() => _yearFilter = v),
              ),
              if (_yearFilter)
                RangeSlider(
                  values: _years,
                  min: 1920,
                  max: 2026,
                  divisions: 106,
                  labels: RangeLabels('${_years.start.round()}', '${_years.end.round()}'),
                  onChanged: (v) => setState(() => _years = v),
                ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadingTracks ? null : _loadTracks,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(_tracks.isEmpty ? 'Show tracks' : 'Reload'),
                  ),
                  const Spacer(),
                  if (_picked.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () => _download([for (final i in _picked) _tracks[i]]),
                      icon: const Icon(Icons.download, size: 18),
                      label: Text('Download ${_picked.length}'),
                    )
                  else if (_tracks.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => _picked.addAll([
                          for (var i = 0; i < _tracks.length; i++)
                            if (_yearShown(_tracks[i])) i
                        ])),
                      child: const Text('Select all'),
                    ),
                ],
              ),
              if (_loadingTracks)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loadingTracks && _loadedFor >= 0 && _tracks.isEmpty)
                const Text('No new tracks left for this chart and tempo this session.',
                    style: TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              for (var i = 0; i < _tracks.length; i++)
                if (_yearShown(_tracks[i]))
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _picked.contains(i),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _picked.add(i);
                    } else {
                      _picked.remove(i);
                    }
                  }),
                  title: Text('${_tracks[i].artist} - ${_tracks[i].title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (_tracks[i].bpm > 0) '${_tracks[i].bpm.round()} BPM',
                      if (_tracks[i].year > 0) '${_tracks[i].year}',
                    ].join('  ·  '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  secondary: IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Download now',
                    onPressed: () => _download([_tracks[i]]),
                  ),
                ),
            ],
            if (_source == 'list') ...[
              const Text(
                'Paste a chart or any list, one track per line as "Artist - Title". '
                'Copy a Beatport or Juno top 100 from their page and paste it here. '
                'Leading numbers are ignored. It works down the list once.',
                style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _pasted,
                enabled: true,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '1. Artist - Title\n2. Artist - Title',
                ),
              ),
            ],
            if (_source == 'genre') ...[
            TextField(
              controller: _genre,
              enabled: true,
              decoration: const InputDecoration(labelText: 'Genre'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only these years'),
              subtitle: Text(
                af.useYearRange ? '${af.yearFrom} to ${af.yearTo}' : 'Off: any year',
                style: const TextStyle(fontSize: 12),
              ),
              value: af.useYearRange,
              onChanged: (v) {
                af.useYearRange = v;
                af.save();
                setState(() {});
              },
            ),
            if (af.useYearRange)
              RangeSlider(
                values: RangeValues(af.yearFrom.toDouble(), af.yearTo.toDouble()),
                min: 1920,
                max: 2026,
                divisions: 106,
                labels: RangeLabels('${af.yearFrom}', '${af.yearTo}'),
                onChanged: (v) {
                  af.yearFrom = v.start.round();
                  af.yearTo = v.end.round();
                  af.save();
                  setState(() {});
                },
              ),
            const SizedBox(height: 8),
            Text(
              'Genres that fit ${_bpm.start.round()}-${_bpm.end.round()} BPM are lit. '
              'Move the tempo and the list follows.',
              style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final g in _sortedGenres())
                  ChoiceChip(
                    label: Text('${g.name}  ${g.min.round()}-${g.max.round()}'),
                    visualDensity: VisualDensity.compact,
                    selected: _genre.text.trim().toLowerCase() == g.name,
                    selectedColor: const Color(0xFFFF9F1C),
                    backgroundColor: _fits(g)
                        ? const Color(0xFF2E7D32)
                        : Colors.transparent,
                    labelStyle: TextStyle(
                      color: _genre.text.trim().toLowerCase() == g.name
                          ? Colors.black
                          : (_fits(g) ? Colors.white : SideDeckTheme.muted),
                      fontWeight: _fits(g) ? FontWeight.w700 : FontWeight.w400,
                    ),
                    onSelected: (_) => setState(() {
                              _genre.text = g.name;
                              final lo = g.min.clamp(70.0, 179.0).toDouble();
                              _bpm = RangeValues(lo, g.max.clamp(lo + 1, 180.0).toDouble());
                            }),
                  ),
              ],
            ),
            ],
            if (_source != 'list') ...[
            const SizedBox(height: 14),
            Text('Tempo  ${_bpm.start.round()} to ${_bpm.end.round()} BPM',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            RangeSlider(
              values: _bpm,
              min: 70,
              max: 180,
              divisions: 110,
              labels: RangeLabels('${_bpm.start.round()}', '${_bpm.end.round()}'),
              onChanged: (v) => setState(() => _bpm = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep going until I stop it'),
              value: _endless,
              onChanged: (v) => setState(() => _endless = v),
            ),
            ],
            if (_source != 'list' && !_endless)
              Row(
                children: [
                  const Text('How many'),
                  Expanded(
                    child: Slider(
                      value: _count,
                      min: 1,
                      max: 30,
                      divisions: 29,
                      label: '${_count.round()}',
                      onChanged: (v) => setState(() => _count = v),
                    ),
                  ),
                  Text('${_count.round()}'),
                ],
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep to similar years'),
              subtitle: Text(
                af.similarYears
                    ? 'Each track within ${af.yearSpan} years of the one before it. '
                        'Not used for pasted lists.'
                    : 'Off: any year',
                style: const TextStyle(fontSize: 12),
              ),
              value: af.similarYears,
              onChanged: (v) {
                      af.similarYears = v;
                      af.save();
                      setState(() {});
                    },
            ),
            if (af.similarYears)
              Row(
                children: [
                  const Text('Within'),
                  Expanded(
                    child: Slider(
                      value: af.yearSpan.toDouble(),
                      min: 1,
                      max: 15,
                      divisions: 14,
                      label: '${af.yearSpan} years',
                      onChanged: (v) {
                              af.yearSpan = v.round();
                              af.save();
                              setState(() {});
                            },
                    ),
                  ),
                  Text('±${af.yearSpan} yrs'),
                ],
              ),
            Row(
              children: [
                const Expanded(
                  child: Text('Pause when this many tracks are waiting to be played'),
                ),
                Text('${af.buffer}'),
              ],
            ),
            Slider(
              value: af.buffer.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${af.buffer}',
              onChanged: (v) {
                af.buffer = v.round();
                af.save();
                setState(() {});
              },
            ),
            const Divider(),
            Text(
              'Phone space  ·  ${StorageGuard.usageLine(SlskSetup.dirFor(widget.library))}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            Row(
              children: [
                const Expanded(child: Text('Most space downloads may use')),
                Text('${StorageGuard.maxGb.round()} GB'),
              ],
            ),
            Slider(
              value: StorageGuard.maxGb,
              min: 1,
              max: 50,
              divisions: 49,
              label: '${StorageGuard.maxGb.round()} GB',
              onChanged: (v) {
                StorageGuard.maxGb = v;
                StorageGuard.save();
                setState(() {});
              },
            ),
            Row(
              children: [
                const Expanded(child: Text('Always keep this much free')),
                Text('${StorageGuard.reserveGb.round()} GB'),
              ],
            ),
            Slider(
              value: StorageGuard.reserveGb,
              min: 1,
              max: 30,
              divisions: 29,
              label: '${StorageGuard.reserveGb.round()} GB',
              onChanged: (v) {
                StorageGuard.reserveGb = v;
                StorageGuard.save();
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: af.running
                      ? af.stop
                      : () {
                          _remember();
                          af.toggle(true, widget.library);
                        },
                  child: Text(af.running ? 'Stop' : 'Start'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    af.status.isEmpty
                        ? (soulseek.online ? '' : 'Sign in to Soulseek first')
                        : '${af.status}  (${af.fetched}${af.limit > 0 ? '/${af.limit}' : ''})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final l in af.log) Text('✓ $l', style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
