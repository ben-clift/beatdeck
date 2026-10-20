import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/ui/suggest_page.dart';

/// Search the Soulseek network and download straight into the library folder.
class SoulseekPage extends StatefulWidget {
  const SoulseekPage({super.key, required this.library, this.initialQuery});

  final LibraryController library;

  /// Searched as soon as you are signed in.
  final String? initialQuery;

  @override
  State<SoulseekPage> createState() => _SoulseekPageState();
}

class _SoulseekPageState extends State<SoulseekPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _query = TextEditingController();
  bool _hide = true;
  String _fallbackDir = '';

  @override
  void initState() {
    super.initState();
    soulseek.downloadDir = () => widget.library.folderPath ?? _fallbackDir;
    soulseek.onFileSaved = () => widget.library.refresh();
    _loadSaved();
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) {
      _query.text = q;
      _pendingSearch = q;
      soulseek.addListener(_trySearch);
      WidgetsBinding.instance.addPostFrameCallback((_) => _trySearch());
    }
  }

  String? _pendingSearch;

  void _trySearch() {
    final q = _pendingSearch;
    if (q != null && soulseek.online) {
      _pendingSearch = null;
      soulseek.search(q);
    }
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _user.text = prefs.getString('slsk_user') ?? '';
      _pass.text = prefs.getString('slsk_pass') ?? '';
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        final d = Directory('${dir.path}/soulseek');
        await d.create(recursive: true);
        _fallbackDir = d.path;
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    soulseek.removeListener(_trySearch);
    _user.dispose();
    _pass.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final u = _user.text.trim();
    final p = _pass.text;
    if (u.isEmpty || p.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('slsk_user', u);
      await prefs.setString('slsk_pass', p);
    } catch (_) {}
    await soulseek.connect(u, p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soulseek'),
        actions: [
          ListenableBuilder(
            listenable: soulseek,
            builder: (context, _) => soulseek.online
                ? TextButton(
                    onPressed: soulseek.disconnect,
                    child: const Text('Sign out'),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: soulseek,
        builder: (context, _) {
          if (!soulseek.online) return _signInView();
          return _mainView();
        },
      ),
    );
  }

  Widget _signInView() {
    final connecting = soulseek.status == SlskStatus.connecting;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Sign in with your Soulseek name. A name that does not exist yet is '
          'created for you the first time you sign in.',
          style: TextStyle(color: SideDeckTheme.muted),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _user,
          decoration: const InputDecoration(labelText: 'Username'),
          autocorrect: false,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pass,
          obscureText: _hide,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
          autocorrect: false,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: connecting ? null : _signIn,
          child: Text(connecting ? 'Connecting' : 'Sign in'),
        ),
        if (soulseek.error != null) ...[
          const SizedBox(height: 12),
          Text(soulseek.error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        const Text(
          'Your password is saved on this phone only.',
          style: TextStyle(fontSize: 12, color: SideDeckTheme.muted),
        ),
      ],
    );
  }

  Widget _mainView() {
    final results = List<SlskResult>.of(soulseek.results)
      ..sort((a, b) {
        if (a.freeSlot != b.freeSlot) return a.freeSlot ? -1 : 1;
        if (a.bitrate != b.bitrate) return b.bitrate.compareTo(a.bitrate);
        return b.speed.compareTo(a.speed);
      });
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: soulseek.search,
              decoration: InputDecoration(
                hintText: 'Search artist or track',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: soulseek.searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: () => soulseek.search(_query.text),
                      ),
              ),
            ),
          ),
          TabBar(
            tabs: [
              Tab(text: 'Results (${results.length})'),
              Tab(text: 'Downloads (${soulseek.downloads.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [_resultsList(results), _downloadsList()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsList(List<SlskResult> results) {
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            soulseek.searching
                ? 'Searching. Results appear as people answer.'
                : 'Search for a track to see what people are sharing.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final r = results[i];
        final mb = (r.size / 1048576).toStringAsFixed(1);
        final info = [
          if (r.bitrate > 0) '${r.bitrate} kbps',
          r.ext.toUpperCase(),
          '$mb MB',
          r.freeSlot ? 'free slot' : 'queue ${r.queue}',
        ].join('  ·  ');
        final hint = parseNameHints('${r.folder} ${r.fileName}');
        final seedKey = SuggestSeed.key;
        String? fit;
        if (seedKey != null && hint.key != null) {
          final m = keyMatch(seedKey, hint.key!);
          if (m.score > 0) fit = '${hint.key!.code} fits';
        }
        if (fit != null && hint.bpm != null && SuggestSeed.bpm > 0) {
          if (bpmGapPercent(SuggestSeed.bpm, hint.bpm!).abs() > 8) fit = null;
        }
        return ListTile(
          dense: true,
          leading: fit == null
              ? null
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  color: const Color(0xFF2E7D32),
                  child: Text(fit,
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
          title: Text(r.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${r.folder}  ·  ${r.user}\n$info',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: IconButton(
            icon: const Icon(Icons.download),
            onPressed: () {
              soulseek.download(r);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Downloading ${r.fileName}')),
              );
            },
          ),
        );
      },
    );
  }

  Widget _downloadsList() {
    final list = soulseek.downloads;
    if (list.isEmpty) {
      return const Center(
        child: Text(
          'Nothing downloading yet.',
          style: TextStyle(color: SideDeckTheme.muted),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final d = list[i];
        final status = switch (d.state) {
          DlState.done => 'Saved to your library folder',
          DlState.downloading =>
            '${(d.progress * 100).round()}%  of ${(d.size / 1048576).toStringAsFixed(1)} MB',
          _ => d.message,
        };
        return ListTile(
          dense: true,
          title: Text(
            d.result.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${d.user}  ·  $status',
                style: TextStyle(
                  color: d.state == DlState.failed ? Colors.redAccent : null,
                ),
              ),
              if (d.state == DlState.downloading)
                LinearProgressIndicator(value: d.progress),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => soulseek.removeDownload(d),
          ),
        );
      },
    );
  }
}
