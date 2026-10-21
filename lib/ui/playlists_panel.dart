import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/state/playlist_store.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Local playlists and automix. Shown as the "Playlists" tab in the library.
class PlaylistsPanel extends StatefulWidget {
  const PlaylistsPanel({
    super.key,
    required this.dj,
    required this.library,
    required this.playlists,
  });

  final DjController dj;
  final LibraryController library;
  final PlaylistController playlists;

  @override
  State<PlaylistsPanel> createState() => _PlaylistsPanelState();
}

class _PlaylistsPanelState extends State<PlaylistsPanel> {
  String? _openId;
  double _fade = 12;

  String _titleFor(String path) {
    for (final t in widget.library.tracks) {
      if (t.path == path) return t.title;
    }
    return p.basenameWithoutExtension(path);
  }

  String _artistFor(String path) {
    for (final t in widget.library.tracks) {
      if (t.path == path) return t.artist;
    }
    return '';
  }

  Future<String?> _askName(String title, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final name = await _askName('New playlist');
    if (name == null) return;
    final created = await widget.playlists.create(name);
    if (mounted) setState(() => _openId = created.id);
  }

  Future<void> _rename(Playlist pl) async {
    final name = await _askName('Rename playlist', initial: pl.name);
    if (name == null) return;
    await widget.playlists.rename(pl.id, name);
  }

  Future<void> _delete(Playlist pl) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${pl.name}"?'),
        content: const Text('The music files are not deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure == true) {
      await widget.playlists.delete(pl.id);
      if (mounted && _openId == pl.id) setState(() => _openId = null);
    }
  }

  Future<void> _addTracks(Playlist pl) async {
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = query.trim().toLowerCase();
          final shown = [
            for (final t in widget.library.tracks)
              if (q.isEmpty ||
                  t.title.toLowerCase().contains(q) ||
                  t.artist.toLowerCase().contains(q))
                t,
          ];
          final current = widget.playlists.byId(pl.id);
          return AlertDialog(
            title: Text('Add to ${pl.name}'),
            content: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(hintText: 'Filter…'),
                    onChanged: (v) => setDialogState(() => query = v),
                  ),
                  Expanded(
                    child: shown.isEmpty
                        ? const Center(
                            child: Text(
                              'No tracks. Add a folder in the Local tab first.',
                            ),
                          )
                        : ListView.builder(
                            itemCount: shown.length,
                            itemBuilder: (context, i) {
                              final t = shown[i];
                              final inList =
                                  current?.paths.contains(t.path) ?? false;
                              return ListTile(
                                dense: true,
                                title: Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: t.artist.isEmpty
                                    ? null
                                    : Text(
                                        t.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                trailing: Icon(
                                  inList ? Icons.check_circle : Icons.add_circle_outline,
                                  color: inList ? SideDeckTheme.accentA : null,
                                ),
                                onTap: inList
                                    ? null
                                    : () async {
                                        await widget.playlists.add(pl.id, t.path);
                                        setDialogState(() {});
                                      },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  for (final t in shown) {
                    await widget.playlists.add(pl.id, t.path);
                  }
                  setDialogState(() {});
                },
                child: Text('Add all shown (${shown.length})'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.playlists, widget.dj, widget.library]),
      builder: (context, _) {
        final open = _openId == null ? null : widget.playlists.byId(_openId!);
        if (open == null) return _listView();
        return _detailView(open);
      },
    );
  }

  Widget _listView() {
    final lists = widget.playlists.playlists;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Your playlists',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
              ),
            ],
          ),
        ),
        Expanded(
          child: lists.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No playlists yet. Tap New, then add tracks from your library.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SideDeckTheme.muted),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      title: Text(pl.name),
                      subtitle: Text(
                        pl.paths.length == 1 ? '1 track' : '${pl.paths.length} tracks',
                      ),
                      onTap: () => setState(() => _openId = pl.id),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'rename') _rename(pl);
                          if (v == 'delete') _delete(pl);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _detailView(Playlist pl) {
    final dj = widget.dj;
    final paths = pl.paths;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: () => setState(() => _openId = null),
                icon: const Icon(Icons.arrow_back, size: 22),
              ),
              Expanded(
                child: Text(
                  pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => _addTracks(pl),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add tracks'),
              ),
            ],
          ),
        ),
        _automixBar(pl),
        const Divider(height: 1),
        Expanded(
          child: paths.isEmpty
              ? const Center(
                  child: Text(
                    'Empty. Tap Add tracks.',
                    style: TextStyle(color: SideDeckTheme.muted),
                  ),
                )
              : ReorderableListView.builder(
                  itemCount: paths.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex -= 1;
                    widget.playlists.move(pl.id, oldIndex, newIndex);
                  },
                  itemBuilder: (context, i) {
                    final path = paths[i];
                    final playingNow = dj.automixOn && dj.automixIndex == i;
                    final artist = _artistFor(path);
                    return ListTile(
                      key: ValueKey(path),
                      dense: true,
                      leading: Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: playingNow
                              ? SideDeckTheme.accentA
                              : SideDeckTheme.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      title: Text(
                        _titleFor(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: artist.isEmpty
                          ? null
                          : Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'a') {
                            dj.loadFile(0, path,
                                title: _titleFor(path), artist: artist);
                          } else if (v == 'b') {
                            dj.loadFile(1, path,
                                title: _titleFor(path), artist: artist);
                          } else if (v == 'automix') {
                            dj.startAutomix(paths.sublist(i), fadeSeconds: _fade);
                          } else if (v == 'remove') {
                            // Deleting means "not for me": never picked or searched again.
                            final removed = path;
                            widget.playlists.removeAt(pl.id, i);
                            Dislikes.instance.add(removed);
                            dj.automixDrop(removed);
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(
                                content: const Text(
                                    'Deleted. It will not be picked or searched for again.'),
                                action: SnackBarAction(
                                  label: 'UNDO',
                                  onPressed: () {
                                    Dislikes.instance.remove(removed);
                                    widget.playlists.add(pl.id, removed);
                                  },
                                ),
                              ));
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'a', child: Text('Load on deck A')),
                          PopupMenuItem(value: 'b', child: Text('Load on deck B')),
                          PopupMenuItem(
                            value: 'automix',
                            child: Text('Automix from here'),
                          ),
                          PopupMenuItem(value: 'remove', child: Text('Delete (never play again)')),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _automixBar(Playlist pl) {
    final dj = widget.dj;
    final on = dj.automixOn;
    final status = dj.automixStatus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (on)
                FilledButton.icon(
                  onPressed: dj.stopAutomix,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Stop automix'),
                )
              else
                FilledButton.icon(
                  onPressed: pl.paths.isEmpty
                      ? null
                      : () => dj.startAutomix(pl.paths, fadeSeconds: _fade),
                  icon: const Icon(Icons.auto_mode, size: 18),
                  label: const Text('Automix'),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  on
                      ? 'Track ${dj.automixIndex + 1} of ${dj.automixQueueLength}'
                      : (status ?? 'Fades tracks together on the beat'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: SideDeckTheme.muted,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Fade', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _fade,
                  min: 4,
                  max: 30,
                  divisions: 26,
                  label: '${_fade.round()} s',
                  onChanged: on ? null : (v) => setState(() => _fade = v),
                ),
              ),
              Text('${_fade.round()} s', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
