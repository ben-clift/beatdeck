import 'package:flutter/material.dart';
import 'package:sidedeck/suggest/genre_glossary.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// What each genre in the picker means, searchable and sorted by speed.
class GenreGlossaryPage extends StatefulWidget {
  const GenreGlossaryPage({super.key});

  @override
  State<GenreGlossaryPage> createState() => _GenreGlossaryPageState();
}

class _GenreGlossaryPageState extends State<GenreGlossaryPage> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final all = [for (final grp in genreGroups) ...grp.$2];
    all.sort((a, b) => a.min.compareTo(b.min));
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final g in all)
        if (q.isEmpty ||
            g.name.contains(q) ||
            (genreGlossary[g.name] ?? '').toLowerCase().contains(q))
          g,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('What the genres mean')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search genres',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Text(
              'The numbers are the usual speed in beats per minute (BPM). They are typical, not strict.',
              style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final g = shown[i];
                return ListTile(
                  dense: true,
                  title: Text('${g.name}   ${g.min.round()}-${g.max.round()} BPM',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(genreGlossary[g.name] ?? 'A style of electronic dance music.'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
