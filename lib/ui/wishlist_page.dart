import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/soulseek_page.dart';
import 'package:sidedeck/wishlist/wishlist.dart';

/// Song lists copied from other services (names only) with a button to find
/// each song on Soulseek.
class WishListPage extends StatefulWidget {
  const WishListPage({super.key, required this.library});

  final LibraryController library;

  @override
  State<WishListPage> createState() => _WishListPageState();
}

class _WishListPageState extends State<WishListPage> {
  final _ctl = WishListController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _open(WishList l) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WishDetail(ctl: _ctl, list: l, library: widget.library),
      ),
    );
  }

  Future<void> _import() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SideDeckTheme.panel,
      builder: (_) => _ImportSheet(ctl: _ctl),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Song wish lists')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _import,
        icon: const Icon(Icons.playlist_add),
        label: const Text('Import a list'),
      ),
      body: ListenableBuilder(
        listenable: _ctl,
        builder: (context, _) {
          if (_ctl.lists.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Bring in the songs from a Spotify, Deezer, Tidal or YouTube '
                  'playlist. Only the names come across. Then tap Find on each '
                  'song to search Soulseek for it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SideDeckTheme.muted),
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final l in _ctl.lists)
                ListTile(
                  title: Text(l.name),
                  subtitle: Text(
                    '${l.source}  ·  ${l.items.where((i) => i.done).length} of '
                    '${l.items.length} found',
                  ),
                  onTap: () => _open(l),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _ctl.remove(l),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _WishDetail extends StatelessWidget {
  const _WishDetail({
    required this.ctl,
    required this.list,
    required this.library,
  });

  final WishListController ctl;
  final WishList list;
  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(list.name)),
      body: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) => ListView.builder(
          itemCount: list.items.length,
          itemBuilder: (context, i) {
            final it = list.items[i];
            return ListTile(
              dense: true,
              leading: Checkbox(
                value: it.done,
                onChanged: (_) => ctl.toggleDone(it),
              ),
              title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: it.artist.isEmpty ? null : Text(it.artist),
              trailing: TextButton.icon(
                icon: const Icon(Icons.travel_explore, size: 18),
                label: const Text('Find'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SoulseekPage(
                      library: library,
                      initialQuery: it.query,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.ctl});

  final WishListController ctl;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  final _link = TextEditingController();
  final _spId = TextEditingController();
  final _spSecret = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    try {
      final p = await SharedPreferences.getInstance();
      _spId.text = p.getString('spotify_id') ?? '';
      _spSecret.text = p.getString('spotify_secret') ?? '';
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    _link.dispose();
    _spId.dispose();
    _spSecret.dispose();
    super.dispose();
  }

  Future<void> _done(Future<bool> f) async {
    final ok = await f;
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _file() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt'],
      withData: true,
    );
    final bytes = res?.files.single.bytes;
    if (bytes == null) return;
    final name = res!.files.single.name.replaceAll(RegExp(r'\.\w+$'), '');
    await _done(widget.ctl.importText(name, utf8.decode(bytes, allowMalformed: true), source: 'File'));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: ListenableBuilder(
            listenable: widget.ctl,
            builder: (context, _) => Column(
              children: [
                const TabBar(tabs: [
                  Tab(text: 'Paste or file'),
                  Tab(text: 'Deezer'),
                  Tab(text: 'Spotify'),
                ]),
                if (widget.ctl.message != null)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      widget.ctl.message!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                if (widget.ctl.busy) const LinearProgressIndicator(),
                Expanded(
                  child: TabBarView(
                    children: [_pasteTab(), _deezerTab(), _spotifyTab()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pasteTab() => ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text(
            'Works for any service. Paste one "Artist - Title" per line, or pick '
            'a CSV file exported from your playlist (for example with Exportify '
            'for Spotify, or TuneMyMusic for Tidal and YouTube).',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'List name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            minLines: 5,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Songs',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: () => _done(
                  widget.ctl.importText(_name.text.trim(), _text.text),
                ),
                child: const Text('Add list'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _file,
                icon: const Icon(Icons.upload_file),
                label: const Text('Pick a CSV'),
              ),
            ],
          ),
        ],
      );

  Widget _deezerTab() => ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text(
            'Paste the link of a public Deezer playlist. No sign in needed.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _link,
            decoration: const InputDecoration(labelText: 'Deezer playlist link'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: widget.ctl.busy
                ? null
                : () => _done(widget.ctl.importDeezer(_link.text.trim())),
            child: const Text('Import'),
          ),
        ],
      );

  Widget _spotifyTab() => ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text(
            'Spotify needs a free developer app of your own: create one at '
            'developer.spotify.com, then paste its client id and secret here. '
            'Spotify sometimes refuses playlists it does not own; if so, use '
            'the CSV route on the first tab.',
            style: TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _link,
            decoration: const InputDecoration(labelText: 'Spotify playlist link'),
          ),
          TextField(
            controller: _spId,
            decoration: const InputDecoration(labelText: 'Client id'),
          ),
          TextField(
            controller: _spSecret,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Client secret'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: widget.ctl.busy
                ? null
                : () async {
                    try {
                      final p = await SharedPreferences.getInstance();
                      await p.setString('spotify_id', _spId.text.trim());
                      await p.setString('spotify_secret', _spSecret.text.trim());
                    } catch (_) {}
                    await _done(widget.ctl.importSpotify(
                      _link.text.trim(),
                      _spId.text.trim(),
                      _spSecret.text.trim(),
                    ));
                  },
            child: const Text('Import'),
          ),
        ],
      );
}
