import 'package:flutter/material.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
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
  late RangeValues _bpm =
      RangeValues(AutoFetch.instance.bpmMin, AutoFetch.instance.bpmMax);
  late double _count = AutoFetch.instance.count.toDouble();
  late bool _endless = AutoFetch.instance.endless;

  void _remember() {
    final af = AutoFetch.instance;
    af.genre = _genre.text.trim().isEmpty ? 'house' : _genre.text.trim();
    af.bpmMin = _bpm.start;
    af.bpmMax = _bpm.end;
    af.count = _count.round();
    af.endless = _endless;
    af.save();
  }

  static const _quick = [
    'house', 'deep house', 'tech house', 'techno', 'trance', 'drum and bass',
    'disco', 'funk', 'hip hop', 'garage', 'dub', 'reggae', 'afrobeat', 'pop',
  ];

  @override
  void dispose() {
    _remember();
    _genre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final af = AutoFetch.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-fetch')),
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
            TextField(
              controller: _genre,
              enabled: !af.running,
              decoration: const InputDecoration(labelText: 'Genre'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in _quick)
                  ActionChip(
                    label: Text(g),
                    visualDensity: VisualDensity.compact,
                    onPressed: af.running ? null : () => setState(() => _genre.text = g),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Tempo  ${_bpm.start.round()} to ${_bpm.end.round()} BPM',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            RangeSlider(
              values: _bpm,
              min: 60,
              max: 200,
              divisions: 140,
              labels: RangeLabels('${_bpm.start.round()}', '${_bpm.end.round()}'),
              onChanged: af.running ? null : (v) => setState(() => _bpm = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep going until I stop it'),
              value: _endless,
              onChanged: af.running ? null : (v) => setState(() => _endless = v),
            ),
            if (!_endless)
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
                      onChanged: af.running ? null : (v) => setState(() => _count = v),
                    ),
                  ),
                  Text('${_count.round()}'),
                ],
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: af.running
                      ? af.stop
                      : () {
                          _remember();
                          af.startByGenre(
                            genre: _genre.text.trim().isEmpty ? 'house' : _genre.text.trim(),
                            bpmMin: _bpm.start,
                            bpmMax: _bpm.end,
                            library: widget.library,
                            count: _count.round(),
                            endless: _endless,
                          );
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
