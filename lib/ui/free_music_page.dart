import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

class _Song {
  _Song(this.title, this.artist, this.url, this.ext);

  final String title;
  final String artist;
  final String url;
  final String ext;
}

/// Free, legal music: Jamendo (artist-approved music, needs a free client id)
/// and the Internet Archive (public domain and live recordings, no key).
class FreeMusicPage extends StatefulWidget {
  const FreeMusicPage({super.key, required this.library});

  final LibraryController library;

  @override
  State<FreeMusicPage> createState() => _FreeMusicPageState();
}

class _FreeMusicPageState extends State<FreeMusicPage> {
  final _query = TextEditingController();
  final _jamendoId = TextEditingController();
  final List<_Song> _songs = [];
  final List<Map<String, String>> _archiveItems = [];
  final Map<String, String> _status = {};
  String _source = 'jamendo';
  bool _busy = false;
  String? _error;
  String _archiveTitle = '';

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _jamendoId.text = prefs.getString('jamendo_id') ?? '';
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _query.dispose();
    _jamendoId.dispose();
    super.dispose();
  }

  Future<String> _dir() async {
    final d = widget.library.folderPath;
    if (d != null && d.isNotEmpty) return d;
    final ext = await getExternalStorageDirectory();
    final dir = Directory('${ext?.path ?? (await getApplicationSupportDirectory()).path}/free_music');
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _songs.clear();
      _archiveItems.clear();
      _archiveTitle = '';
    });
    try {
      if (_source == 'jamendo') {
        final id = _jamendoId.text.trim();
        if (id.isEmpty) {
          _error = 'Paste your free Jamendo client id first (devportal.jamendo.com).';
        } else {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('jamendo_id', id);
          } catch (_) {}
          final uri = Uri.https('api.jamendo.com', '/v3.0/tracks/', {
            'client_id': id,
            'format': 'json',
            'limit': '40',
            'search': q,
            'audioformat': 'mp32',
            'include': 'musicinfo',
          });
          final res = await http.get(uri).timeout(const Duration(seconds: 20));
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          for (final t in (data['results'] as List? ?? [])) {
            final m = t as Map<String, dynamic>;
            final url = (m['audiodownload_allowed'] == true
                    ? m['audiodownload']
                    : m['audio']) as String? ??
                '';
            if (url.isEmpty) continue;
            _songs.add(_Song(
              m['name'] as String? ?? 'Track',
              m['artist_name'] as String? ?? '',
              url,
              'mp3',
            ));
          }
          if (_songs.isEmpty) _error = 'Nothing found.';
        }
      } else {
        final uri = Uri.https('archive.org', '/advancedsearch.php', {
          'q': '($q) AND mediatype:audio',
          'fl[]': ['identifier', 'title', 'creator'],
          'rows': '30',
          'output': 'json',
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        final docs = ((jsonDecode(res.body) as Map)['response'] as Map?)?['docs'] as List? ?? [];
        for (final d in docs) {
          final m = d as Map<String, dynamic>;
          _archiveItems.add({
            'id': '${m['identifier']}',
            'title': '${m['title'] ?? m['identifier']}',
            'creator': m['creator'] is List
                ? '${(m['creator'] as List).join(', ')}'
                : '${m['creator'] ?? ''}',
          });
        }
        if (_archiveItems.isEmpty) _error = 'Nothing found.';
      }
    } catch (_) {
      _error = 'Could not reach the service. Check your connection.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openArchive(Map<String, String> item) async {
    setState(() {
      _busy = true;
      _error = null;
      _songs.clear();
      _archiveTitle = item['title'] ?? '';
    });
    try {
      final id = item['id']!;
      final res = await http
          .get(Uri.parse('https://archive.org/metadata/$id'))
          .timeout(const Duration(seconds: 20));
      final files = ((jsonDecode(res.body) as Map)['files'] as List? ?? []);
      for (final f in files) {
        final m = f as Map<String, dynamic>;
        final name = '${m['name']}';
        final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
        if (!const {'mp3', 'flac', 'ogg', 'wav', 'm4a'}.contains(ext)) continue;
        if (m['source'] == 'derivative' && ext == 'ogg') continue;
        _songs.add(_Song(
          m['title'] as String? ?? p.basenameWithoutExtension(name),
          item['creator'] ?? '',
          'https://archive.org/download/$id/${Uri.encodeComponent(name)}',
          ext,
        ));
        if (_songs.length >= 60) break;
      }
      if (_songs.isEmpty) _error = 'No audio files in that item.';
    } catch (_) {
      _error = 'Could not load that item.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _download(_Song s) async {
    setState(() => _status[s.url] = 'Downloading');
    try {
      final dir = await _dir();
      final safe = '${s.artist.isEmpty ? '' : '${s.artist} - '}${s.title}'
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      var file = File(p.join(dir, '$safe.${s.ext}'));
      var n = 1;
      while (file.existsSync()) {
        file = File(p.join(dir, '$safe ($n).${s.ext}'));
        n++;
      }
      final client = http.Client();
      try {
        final resp = await client.send(http.Request('GET', Uri.parse(s.url)));
        if (resp.statusCode != 200) {
          throw HttpException('${resp.statusCode}');
        }
        final sink = file.openWrite();
        await resp.stream.pipe(sink);
      } finally {
        client.close();
      }
      _status[s.url] = 'Saved';
      widget.library.refresh();
    } catch (_) {
      _status[s.url] = 'Failed';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Free music')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'jamendo', label: Text('Jamendo')),
                ButtonSegment(value: 'archive', label: Text('Internet Archive')),
              ],
              selected: {_source},
              onSelectionChanged: (v) => setState(() {
                _source = v.first;
                _songs.clear();
                _archiveItems.clear();
                _error = null;
              }),
            ),
          ),
          if (_source == 'jamendo')
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _jamendoId,
                decoration: const InputDecoration(
                  labelText: 'Jamendo client id (free at devportal.jamendo.com)',
                  isDense: true,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: _source == 'jamendo'
                    ? 'Search artists, tracks or genres'
                    : 'Search live sets, old records, public domain',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (_archiveTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _search,
                  ),
                  Expanded(
                    child: Text(_archiveTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _list() {
    if (_source == 'archive' && _songs.isEmpty && _archiveItems.isNotEmpty) {
      return ListView(
        children: [
          for (final it in _archiveItems)
            ListTile(
              dense: true,
              title: Text(it['title']!, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(it['creator']!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openArchive(it),
            ),
        ],
      );
    }
    if (_songs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Free, legal music you can download and mix. Search above.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _songs.length,
      itemBuilder: (context, i) {
        final s = _songs[i];
        final st = _status[s.url];
        return ListTile(
          dense: true,
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${s.artist}  ·  ${s.ext.toUpperCase()}'
              '${st == null ? '' : '  ·  $st'}'),
          trailing: IconButton(
            icon: Icon(st == 'Saved' ? Icons.check : Icons.download),
            onPressed: st == 'Downloading' || st == 'Saved' ? null : () => _download(s),
          ),
        );
      },
    );
  }
}
