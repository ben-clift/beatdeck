import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/discover.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/soulseek_page.dart';

/// Genre, tempo and shop choice with a button that fetches that genre now.
/// Same controls as the Genre section of DJ Charts, for the Auto DJ panel.
class GenrePicker extends StatefulWidget {
  const GenrePicker({super.key, required this.library});
  final LibraryController library;

  @override
  State<GenrePicker> createState() => _GenrePickerState();
}

class _GenrePickerState extends State<GenrePicker> {
  final _af = AutoFetch.instance;
  late final TextEditingController _genre = TextEditingController();
  late final Set<String> _sel = {..._af.genres};
  late RangeValues _bpm = RangeValues(
    _af.bpmMin.clamp(70.0, 179.0).toDouble(),
    _af.bpmMax.clamp(71.0, 180.0).toDouble(),
  );

  final _token = TextEditingController();

  @override
  void initState() {
    super.initState();
    Discover.loadToken().then((_) {
      if (mounted) _token.text = Discover.token;
    });
    _af.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _af.removeListener(_changed);
    _genre.dispose();
    _token.dispose();
    super.dispose();
  }

  bool _fits(GenreInfo g) => math.min(g.max, _bpm.end) - math.max(g.min, _bpm.start) > 0;

  List<GenreInfo> _sorted() {
    final all = [for (final grp in genreGroups) ...grp.$2];
    all.sort((a, b) {
      final fa = _fits(a) ? 0 : 1;
      final fb = _fits(b) ? 0 : 1;
      return fa != fb ? fa.compareTo(fb) : a.min.compareTo(b.min);
    });
    return all;
  }

  void _addTyped() {
    final g = _genre.text.trim().toLowerCase();
    if (g.isEmpty) return;
    setState(() {
      _sel.add(g);
      _genre.clear();
    });
  }

  /// Tempo range that covers every ticked genre.
  void _fitTempo() {
    double? lo, hi;
    for (final grp in genreGroups) {
      for (final g in grp.$2) {
        if (_sel.contains(g.name)) {
          lo = lo == null ? g.min : math.min(lo, g.min);
          hi = hi == null ? g.max : math.max(hi, g.max);
        }
      }
    }
    if (lo != null && hi != null) {
      final l = lo.clamp(70.0, 179.0).toDouble();
      _bpm = RangeValues(l, hi.clamp(l + 1, 180.0).toDouble());
    }
  }

  void _go() {
    _addTyped();
    if (_sel.isEmpty) return;
    _af.genres = _sel.toList();
    _af.genre = _af.genres.first;
    _af.pinned = true;
    _af.source = 'genre';
    _af.bpmMin = _bpm.start;
    _af.bpmMax = _bpm.end;
    _af.save();
    // Restart so a track of the ticked genres is fetched at once and mixed in.
    _af.toggle(false, widget.library);
    _af.toggle(true, widget.library);
  }

  void _clear() {
    setState(() => _sel.clear());
    _af.genres = [];
    _af.pinned = false;
    _af.save();
    _af.refresh();
  }

  Widget _src(String label, bool value, void Function(bool) set) => FilterChip(
        label: Text(label),
        selected: value,
        visualDensity: VisualDensity.compact,
        onSelected: (v) {
          set(v);
          _af.save();
          _af.refresh();
        },
      );

  Widget _fetchButton() => FilledButton.icon(
        onPressed: (_sel.isEmpty && _genre.text.trim().isEmpty) ? null : _go,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Fetch & mix now'),
      );

  @override
  Widget build(BuildContext context) {
    final noSource = !_af.useHardwax && !_af.useTrax && !_af.useRa && !_af.useBandcamp && !_af.useDiscogs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _fetchButton(),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Fetches your ticked genres and mixes the first match in.',
                  style: TextStyle(fontSize: 11, color: SideDeckTheme.muted)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Search Soulseek', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SoulseekPage(library: widget.library)),
              ),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Open search'),
            ),
          ],
        ),
        const Text('Find it on', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        Wrap(
          spacing: 8,
          children: [
            _src('Hardwax', _af.useHardwax, (v) => _af.useHardwax = v),
            _src('Traxsource', _af.useTrax, (v) => _af.useTrax = v),
            _src('RA', _af.useRa, (v) => _af.useRa = v),
            _src('Bandcamp', _af.useBandcamp, (v) => _af.useBandcamp = v),
            _src('Discogs', _af.useDiscogs, (v) => _af.useDiscogs = v),
          ],
        ),
        if (_af.useDiscogs)
          TextField(
            controller: _token,
            onChanged: Discover.saveToken,
            decoration: const InputDecoration(
              labelText: 'Discogs token (free, discogs.com/settings/developers)',
              isDense: true,
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _genre,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _addTyped(),
          decoration: InputDecoration(
            labelText: 'Type a genre and press enter, or tick as many as you like',
            isDense: true,
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _addTyped),
          ),
        ),
        if (_sel.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final g in _sel)
                InputChip(
                  label: Text(g),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => setState(() {
                    _sel.remove(g);
                    _fitTempo();
                  }),
                ),
              TextButton(onPressed: _clear, child: const Text('Clear all')),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text('Tempo  ${_bpm.start.round()} to ${_bpm.end.round()} BPM',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        RangeSlider(
          values: _bpm,
          min: 70,
          max: 180,
          divisions: 110,
          labels: RangeLabels('${_bpm.start.round()}', '${_bpm.end.round()}'),
          onChanged: (v) => setState(() {
            _bpm = v;
            _af.bpmMin = v.start;
            _af.bpmMax = v.end;
          }),
          onChangeEnd: (_) => _af.save(),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Use this tempo for every new track'),
          subtitle: const Text('Off: new tracks follow the tempo of what is playing',
              style: TextStyle(fontSize: 11)),
          value: _af.tempoPinned,
          onChanged: (v) {
            _af.tempoPinned = v;
            _af.bpmMin = _bpm.start;
            _af.bpmMax = _bpm.end;
            _af.save();
            _af.refresh();
          },
        ),
        const SizedBox(height: 6),
        const Text('Intensity', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        Wrap(
          spacing: 8,
          children: [
            for (final e in const [(0, 'Any'), (1, 'Medium'), (2, 'High'), (3, 'Peak')])
              ChoiceChip(
                label: Text(e.$2),
                visualDensity: VisualDensity.compact,
                selected: _af.intensity == e.$1,
                onSelected: (_) {
                  _af.intensity = e.$1;
                  _af.save();
                  _af.refresh();
                },
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text(
            'Higher intensity prefers faster tracks and turns down downloads that are quiet or sparse.',
            style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ),
        Text(
          'Genres that fit ${_bpm.start.round()}-${_bpm.end.round()} BPM are lit.',
          style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (final g in _sorted())
              ChoiceChip(
                label: Text('${g.name}  ${g.min.round()}-${g.max.round()}'),
                visualDensity: VisualDensity.compact,
                selected: _sel.contains(g.name),
                selectedColor: const Color(0xFFFF9F1C),
                backgroundColor: _fits(g) ? const Color(0xFF2E7D32) : Colors.transparent,
                labelStyle: TextStyle(
                  color: _sel.contains(g.name)
                      ? Colors.black
                      : (_fits(g) ? Colors.white : SideDeckTheme.muted),
                  fontWeight: _fits(g) ? FontWeight.w700 : FontWeight.w400,
                ),
                onSelected: (_) => setState(() {
                  if (!_sel.remove(g.name)) _sel.add(g.name);
                  _fitTempo();
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _fetchButton(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                noSource
                    ? 'No shop ticked: only your own picks and Soulseek search are used.'
                    : (_af.status.isEmpty ? '' : _af.status),
                style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
