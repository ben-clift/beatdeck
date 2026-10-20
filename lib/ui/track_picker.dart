import 'package:flutter/material.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Bottom sheet for loading a library track onto a deck without leaving the
/// controller screen.
Future<void> showTrackPicker(
  BuildContext context, {
  required DjController dj,
  required LibraryController library,
  required int deck,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SideDeckTheme.panel,
    builder: (ctx) => _TrackPicker(dj: dj, library: library, deck: deck),
  );
}

class _TrackPicker extends StatefulWidget {
  const _TrackPicker({
    required this.dj,
    required this.library,
    required this.deck,
  });

  final DjController dj;
  final LibraryController library;
  final int deck;

  @override
  State<_TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends State<_TrackPicker> {
  String _q = '';

  Future<void> _pick(LibraryTrack t) async {
    final nav = Navigator.of(context);
    nav.pop();
    final ok = await widget.dj.loadFile(
      widget.deck,
      t.path,
      title: t.title,
      artist: t.artist,
    );
    if (ok) {
      widget.library.upsertAnalysis(
        t.path,
        bpm: widget.dj.deck(widget.deck).bpm,
        key: widget.dj.deck(widget.deck).key,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final tracks = widget.library.tracks.where((t) {
      if (q.isEmpty) return true;
      return t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final height = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Text(
                    'LOAD TO DECK ${widget.deck + 1}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      autofocus: false,
                      onChanged: (v) => setState(() => _q = v),
                      decoration: const InputDecoration(
                        hintText: 'Search your library',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No tracks yet. Go to the Library page and pick a '
                          'folder or add files.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: SideDeckTheme.muted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        return ListTile(
                          dense: true,
                          title: Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (t.artist.isNotEmpty) t.artist,
                              if (t.hasAnalysis) '${t.bpm!.round()} BPM',
                            ].join('  ·  '),
                          ),
                          onTap: () => _pick(t),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
