
import 'package:flutter/material.dart';
import 'package:sidedeck/debug/debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/soulseek/playable.dart';
import 'package:sidedeck/soulseek/slsk_setup.dart';
import 'package:sidedeck/soulseek/soulseek_client.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/suggest/harmony.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/ui/auto_fetch_page.dart';
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

  @override
  void initState() {
    super.initState();
    SlskSetup.wire(widget.library);
    // Anything already in the save folder joins the library.
    widget.library.scanDirectory(SlskSetup.dirFor(widget.library), persist: false);
    _loadSaved();
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) {
      _query.text = q;
      _pendingSearch = q;
      soulseek.addListener(_trySearch);
      WidgetsBinding.instance.addPostFrameCallback((_) => _trySearch());
    }
  }

  void _openAuto() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AutoFetchPage(library: widget.library),
    ));
  }

  bool _showAll = false;
  bool _panelOpen = false;

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
      await SlskSetup.load();
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
    final all = List<SlskResult>.of(soulseek.results);
    final hidden = _showAll ? 0 : all.where((r) => !slskPlayable(r)).length;
    final results = (_showAll ? all : all.where(slskPlayable).toList())
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
          ListenableBuilder(
            listenable: AutoFetch.instance,
            builder: (context, _) {
              final af = AutoFetch.instance;
              return InkWell(
                onTap: () => setState(() => _panelOpen = !_panelOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(
                    children: [
                      Icon(_panelOpen ? Icons.expand_less : Icons.expand_more, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          af.running
                              ? 'AUTO ON  ·  ${af.status.isEmpty ? af.genre : af.status}  (${af.fetched})'
                              : 'Download settings  ·  AUTO off',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: af.running ? const Color(0xFF3DDC57) : SideDeckTheme.muted,
                          ),
                        ),
                      ),
                      Switch(
                        value: af.running,
                        onChanged: (v) => af.toggle(v, widget.library),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (_panelOpen) ...[
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open),
            title: Text(
              'Saving to ${SlskSetup.dirFor(widget.library)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: const Text(
              'Finished downloads are added to your library automatically.',
              style: TextStyle(fontSize: 11),
            ),
            trailing: TextButton(
              onPressed: () async {
                if (await SlskSetup.choose(widget.library)) setState(() {});
              },
              child: const Text('Change'),
            ),
          ),
          ListenableBuilder(
            listenable: AutoFetch.instance,
            builder: (context, _) {
              final af = AutoFetch.instance;
              return Container(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                decoration: BoxDecoration(
                  color: af.running ? const Color(0xFF2E7D32) : const Color(0xFF1E1E1E),
                  border: Border.all(
                    color: af.running ? const Color(0xFF3DDC57) : SideDeckTheme.muted,
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                  children: [
                    Text(
                      'AUTO',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: af.running ? Colors.white : SideDeckTheme.muted,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      af.running ? 'ON' : 'OFF',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: af.running ? const Color(0xFF3DDC57) : SideDeckTheme.muted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Transform.scale(
                      scale: 1.3,
                      child: Switch(
                        value: af.running,
                        onChanged: (v) => af.toggle(v, widget.library),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        af.running && af.status.isNotEmpty
                            ? '${af.status}  (${af.fetched})'
                            : '${af.source == 'trax' || af.source == 'chart' ? [if (af.useHardwax) 'Hardwax', if (af.useTrax) 'Traxsource'].join(' + ') : '${af.genre}  ${af.bpmMin.round()}-${af.bpmMax.round()} BPM'}'
                                '${af.endless ? '  ·  keeps going' : '  ·  ${af.count} tracks'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _openAuto,
                      child: const Text('Set up'),
                    ),
                  ],
                ),
                    Row(
                      children: [
                        const Text('Take tracks from:', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Hardwax'),
                          selected: af.useHardwax,
                          onSelected: (v) {
                            af.useHardwax = v;
                            af.save();
                            af.refresh();
                          },
                        ),
                        const SizedBox(width: 6),
                        FilterChip(
                          label: const Text('Traxsource'),
                          selected: af.useTrax,
                          onSelected: (v) {
                            af.useTrax = v;
                            af.save();
                            af.refresh();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          ],
          TabBar(
            tabs: [
              Tab(text: 'Results (${results.length})'),
              Tab(text: 'Downloads (${soulseek.downloads.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [_resultsList(results, hidden), _downloadsList()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsList(List<SlskResult> results, int hidden) {
    if (results.isEmpty && hidden == 0) {
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
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(
            _showAll
                ? 'Showing every file, including ones the decks cannot play'
                : (hidden > 0
                    ? '$hidden hidden: formats or files the decks cannot play'
                    : 'Only files the decks can play are shown'),
            style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted),
          ),
          trailing: Switch(
            value: _showAll,
            onChanged: (v) => setState(() => _showAll = v),
          ),
        ),
        Expanded(child: _resultRows(results)),
      ],
    );
  }

  Widget _resultRows(List<SlskResult> results) {
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
              DebugLog.add('download', 'tapped: ${r.fileName} from ${r.user}');
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
          DlState.done => 'In your library  ·  ${d.savedPath ?? ''}',
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
