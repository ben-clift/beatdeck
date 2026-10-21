import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/discover.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

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
  late final TextEditingController _genre = TextEditingController(text: _af.genre);
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

  void _go() {
    final g = _genre.text.trim();
    if (g.isEmpty) return;
    _af.source = 'genre';
    _af.genre = g;
    _af.bpmMin = _bpm.start;
    _af.bpmMax = _bpm.end;
    _af.save();
    // Restart so the new genre is fetched at once (and plays next).
    _af.toggle(false, widget.library);
    _af.toggle(true, widget.library);
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

  @override
  Widget build(BuildContext context) {
    final noSource = !_af.useHardwax && !_af.useTrax && !_af.useRa && !_af.useBandcamp && !_af.useDiscogs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _genre,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Genre', isDense: true),
        ),
        const SizedBox(height: 8),
        Text('Tempo  ${_bpm.start.round()} to ${_bpm.end.round()} BPM',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        RangeSlider(
          values: _bpm,
          min: 70,
          max: 180,
          divisions: 110,
          labels: RangeLabels('${_bpm.start.round()}', '${_bpm.end.round()}'),
          onChanged: (v) => setState(() => _bpm = v),
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
                selected: _genre.text.trim().toLowerCase() == g.name,
                selectedColor: const Color(0xFFFF9F1C),
                backgroundColor: _fits(g) ? const Color(0xFF2E7D32) : Colors.transparent,
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
        const SizedBox(height: 10),
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
        Row(
          children: [
            FilledButton(
              onPressed: _genre.text.trim().isEmpty ? null : _go,
              child: const Text('Fetch and play this genre'),
            ),
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
