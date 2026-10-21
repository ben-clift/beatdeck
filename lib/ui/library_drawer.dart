import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/app_launcher.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/track_analyzer.dart';
import 'package:sidedeck/state/dislikes.dart';
import 'package:sidedeck/state/dj_controller.dart';
import 'package:sidedeck/state/library_controller.dart';
import 'package:sidedeck/state/playlist_controller.dart';
import 'package:sidedeck/ui/playlists_panel.dart';
import 'package:sidedeck/ui/free_music_page.dart';
import 'package:sidedeck/ui/soulseek_page.dart';
import 'package:sidedeck/ui/suggest_page.dart';
import 'package:sidedeck/ui/wishlist_page.dart';
import 'package:sidedeck/subsonic/subsonic_client.dart';
import 'package:sidedeck/state/backup_tracks.dart';
import 'package:sidedeck/suggest/auto_fetch.dart';
import 'package:sidedeck/suggest/genres.dart';
import 'package:sidedeck/theme/sidedeck_theme.dart';

/// Modal library overlay (opened from the Library button).
class LibraryOverlay extends StatefulWidget {
  const LibraryOverlay({
    super.key,
    required this.dj,
    required this.library,
    this.onOpenSettings,
    this.embedded = false,
  });

  final DjController dj;
  final LibraryController library;
  final VoidCallback? onOpenSettings;

  /// True when shown as a page inside the controller view: loading a track
  /// or tapping close must not pop the route.
  final bool embedded;

  @override
  State<LibraryOverlay> createState() => _LibraryOverlayState();
}

class _LibraryOverlayState extends State<LibraryOverlay> {
  SubsonicClient? _client;
  List<SubsonicTrack> _remote = [];
  List<SubsonicPlaylist> _playlists = [];
  SubsonicPlaylist? _openPlaylist;
  bool _searching = false;
  bool _remoteLoading = false;
  String? _remoteError;
  String? _remoteBusyId;
  String? _remoteBusyLabel;
  final Map<String, TrackAnalysis> _remoteMeta = {};
  final _cache = AnalysisCache.instance;
  final _search = TextEditingController();
  int _tab = 0;
  final PlaylistController _localPlaylists = PlaylistController();

  @override
  void initState() {
    super.initState();
    _loadClient();
    widget.library.playedCheck = widget.dj.playedRecently;
    widget.library.playsOf = widget.dj.playCountOf;
    widget.library.deckKey = (i) {
      final d = widget.dj.deck(i);
      return d.loaded ? d.key : -1;
    };
    widget.dj.loadPlayedHistory();
    widget.library.addListener(_onLib);
    widget.dj.addListener(_onLib);
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  Future<void> _loadClient() async {
    _client = await SubsonicClient.fromPrefs();
    if (!mounted) return;
    setState(() {});
    if (_client != null) await _loadPlaylists();
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLib);
    widget.dj.removeListener(_onLib);
    _search.dispose();
    _localPlaylists.dispose();
    super.dispose();
  }

  Future<void> _hydrateRemoteMeta(List<SubsonicTrack> tracks) async {
    for (final t in tracks) {
      final path = await _client?.cachedPathIfPresent(t);
      if (path == null) continue;
      try {
        final stat = await File(path).stat();
        final cached = await _cache.get(
          path,
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        );
        if (cached != null) {
          _remoteMeta[t.id] = cached;
        }
      } catch (_) {}
    }
  }

  Future<void> _loadPlaylists() async {
    if (_client == null) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = false;
      _openPlaylist = null;
      _remote = [];
    });
    try {
      final lists = await _client!.playlists();
      lists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() => _playlists = lists);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _openRemotePlaylist(SubsonicPlaylist playlist) async {
    if (_client == null) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = false;
      _openPlaylist = playlist;
      _remote = [];
    });
    try {
      final tracks = await _client!.playlistTracks(playlist.id);
      await _hydrateRemoteMeta(tracks);
      if (!mounted) return;
      setState(() => _remote = tracks);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _searchRemote(String q) async {
    if (_client == null) return;
    final query = q.trim();
    if (query.isEmpty) {
      await _loadPlaylists();
      return;
    }
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _searching = true;
      _openPlaylist = null;
    });
    try {
      final tracks = await _client!.search(query);
      await _hydrateRemoteMeta(tracks);
      if (!mounted) return;
      setState(() => _remote = tracks);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remoteError = e.toString());
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  Future<void> _duplicates(LibraryController lib) async {
    final extras = lib.duplicateTracks();
    if (extras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No duplicate tracks found')),
      );
      return;
    }
    var bytes = 0;
    for (final t in extras) {
      try {
        bytes += File(t.path).lengthSync();
      } catch (_) {}
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${extras.length} duplicate '
            '${extras.length == 1 ? 'file' : 'files'}?'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Frees about ${(bytes / 1048576).toStringAsFixed(0)} MB. '
                  'The best copy of each song is kept (analysed first, then the '
                  'largest). These are deleted from the phone:'),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in extras)
                      Text(t.path.split(RegExp(r'[\\/]')).last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await lib.deleteTracks(extras);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(n == extras.length
            ? 'Deleted $n duplicate ${n == 1 ? 'file' : 'files'}'
            : 'Deleted $n of ${extras.length}. The phone refused the rest.'),
      ),
    );
  }

  Future<void> _loadRemote(SubsonicTrack track, int deck) async {
    if (_client == null) return;
    setState(() {
      _remoteBusyId = track.id;
      _remoteBusyLabel = 'Downloading…';
    });
    try {
      final path = await _client!.cacheTrack(track);
      if (mounted) {
        setState(() => _remoteBusyLabel = 'Loading…');
      }
      final ok = await widget.dj.loadFile(
        deck,
        path,
        title: track.title,
        artist: track.artist,
      );
      if (ok) {
        widget.library.upsertAnalysis(
          path,
          bpm: widget.dj.deck(deck).bpm,
          key: widget.dj.deck(deck).key,
        );
        _remoteMeta[track.id] = TrackAnalysis(
          bpm: widget.dj.deck(deck).bpm,
          key: widget.dj.deck(deck).key,
          beatOffset: widget.dj.deck(deck).beatOffset,
        );
        if (mounted && !widget.embedded) Navigator.pop(context);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.dj.engineError ?? 'Load failed')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Load failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _remoteBusyId = null;
          _remoteBusyLabel = null;
        });
      }
    }
  }

  Future<void> _analyzeRemote(SubsonicTrack track) async {
    if (_client == null || _remoteBusyId != null) return;
    setState(() {
      _remoteBusyId = track.id;
      _remoteBusyLabel = 'Downloading…';
    });
    try {
      final path = await _client!.cacheTrack(track);
      if (mounted) setState(() => _remoteBusyLabel = 'Analyzing…');
      final result = await analyzeTrackFileOffUi(path);
      if (result == null) {
        throw Exception('Analyze failed');
      }
      try {
        final stat = await File(path).stat();
        await _cache.put(
          path: path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
          bpm: result.bpm,
          key: result.key,
          beatOffset: result.beatOffset,
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _remoteMeta[track.id] = result);
      await widget.dj.reloadIfLoaded(
        path,
        title: track.title,
        artist: track.artist,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Analyze failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _remoteBusyId = null;
          _remoteBusyLabel = null;
        });
      }
    }
  }

  Future<void> _analyzeLocal(LibraryTrack t) async {
    final analyzed = await widget.library.analyzePath(t.path);
    await _reloadAnalyzedDecks(analyzed);
  }

  Future<void> _reloadAnalyzedDecks(List<String> paths) async {
    for (final path in paths) {
      await widget.dj.reloadIfLoaded(path);
    }
  }

  Future<void> _loadLocal(LibraryTrack t, int deck) async {
    final ok = await widget.dj.loadFile(
      deck,
      t.path,
      title: t.title,
      artist: t.artist,
    );
    if (ok) {
      widget.library.upsertAnalysis(
        t.path,
        bpm: widget.dj.deck(deck).bpm,
        key: widget.dj.deck(deck).key,
      );
      if (mounted && !widget.embedded) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.library;
    final tracks = lib.organised;

    return Material(
      color: SideDeckTheme.panel,
      child: SafeArea(
        left: false,
        right: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Row(
                children: [
                  _tabBtn('Local', 0),
                  _tabBtn('Remote', 1),
                  _tabBtn('Playlists', 2),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _search,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: _tab == 0
                              ? 'Filter…'
                              : _tab == 2
                                  ? 'Playlists and automix'
                                  : 'Search server, or browse playlists',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          prefixIcon: const Icon(Icons.search, size: 18),
                          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onChanged: (v) {
                          if (_tab == 0) widget.library.setQuery(v);
                          if (_tab == 1 && v.trim().isEmpty && _searching) {
                            _loadPlaylists();
                          }
                        },
                        onSubmitted: (v) {
                          if (_tab == 1) _searchRemote(v);
                        },
                      ),
                    ),
                  ),
                  PopupMenuButton<TrackSort>(
                    tooltip: 'Sort',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.sort, size: 22),
                    onSelected: widget.library.setSort,
                    itemBuilder: (context) => [
                      _sortItem(TrackSort.name, 'Name'),
                      _sortItem(TrackSort.artist, 'Artist'),
                      _sortItem(TrackSort.bpm, 'BPM'),
                      _sortItem(TrackSort.key, 'Key'),
                      _sortItem(TrackSort.genre, 'Genre'),
                      _sortItem(TrackSort.year, 'Year'),
                      _sortItem(TrackSort.length, 'Length'),
                      _sortItem(TrackSort.added, 'Newest'),
                      _sortItem(TrackSort.plays, 'Most played'),
                    ],
                  ),
                  if (_tab == 0) ...[
                    IconButton(
                      tooltip: lib.sortDesc ? 'Descending' : 'Ascending',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => lib.setSortDesc(!lib.sortDesc),
                      icon: Icon(
                        lib.sortDesc ? Icons.arrow_downward : Icons.arrow_upward,
                        size: 20,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Filters',
                      visualDensity: VisualDensity.compact,
                      onPressed: _openFilters,
                      icon: Icon(
                        lib.hasFilters ? Icons.filter_alt : Icons.filter_alt_outlined,
                        size: 22,
                        color: lib.hasFilters ? SideDeckTheme.accentA : null,
                      ),
                    ),
                  ],
                  if (_tab == 0) ...[
                    if (lib.analyzing)
                      IconButton(
                        tooltip: 'Stop analysis',
                        visualDensity: VisualDensity.compact,
                        onPressed: lib.cancelAnalyze,
                        icon: const Icon(Icons.stop, size: 22),
                      )
                    else
                      PopupMenuButton<String>(
                        tooltip: 'Analyze BPM / grid',
                        enabled: lib.tracks.isNotEmpty,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.graphic_eq, size: 22),
                        onSelected: (v) async {
                          if (v == 'missing') {
                            await _reloadAnalyzedDecks(await lib.analyzeMissing());
                          } else if (v == 'all') {
                            await _reloadAnalyzedDecks(await lib.analyzeAll());
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'missing',
                            enabled: lib.unanalyzedCount > 0,
                            child: Text(
                              lib.unanalyzedCount > 0
                                  ? 'Analyze missing (${lib.unanalyzedCount})'
                                  : 'Analyze missing',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'all',
                            child: Text('Re-analyze all'),
                          ),
                        ],
                      ),
                    IconButton(
                      tooltip: 'Rescan folder',
                      visualDensity: VisualDensity.compact,
                      onPressed: lib.loading || lib.analyzing
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final n = await lib.refresh();
                              messenger.showSnackBar(SnackBar(
                                content: Text(n > 0
                                    ? 'Added $n new track${n == 1 ? '' : 's'}'
                                    : 'No new tracks'),
                              ));
                            },
                      icon: const Icon(Icons.refresh, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Song wish lists (from Spotify, Deezer and more)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WishListPage(library: lib),
                        ),
                      ),
                      icon: const Icon(Icons.playlist_add_check, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Find and delete duplicate tracks',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _duplicates(lib),
                      icon: const Icon(Icons.content_copy, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Suggest what mixes with the playing track',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              SuggestPage(dj: widget.dj, library: lib),
                        ),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Free music (Jamendo, Internet Archive)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FreeMusicPage(library: lib),
                        ),
                      ),
                      icon: const Icon(Icons.library_music, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Search Soulseek',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SoulseekPage(library: lib),
                        ),
                      ),
                      icon: const Icon(Icons.travel_explore, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Open Seeker (Soulseek)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await AppLauncher.openByName('Seeker');
                        if (!ok) {
                          messenger.showSnackBar(const SnackBar(
                            content: Text('Seeker is not installed on this phone'),
                          ));
                        }
                      },
                      icon: const Icon(Icons.cloud_download, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Add files (phone, Drive or other cloud)',
                      visualDensity: VisualDensity.compact,
                      onPressed: lib.loading || lib.analyzing ? null : lib.pickFiles,
                      icon: const Icon(Icons.audio_file, size: 22),
                    ),
                    IconButton(
                      tooltip: 'Pick folder',
                      visualDensity: VisualDensity.compact,
                      onPressed: lib.loading || lib.analyzing ? null : lib.pickFolder,
                      icon: const Icon(Icons.folder_open, size: 22),
                    ),
                  ],
                  if (!widget.embedded)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 22),
                    ),
                ],
              ),
            ),
            if (lib.analyzing || widget.dj.loadingDeck != null || lib.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: _statusLine(lib),
              ),
            if (_tab == 1 && _openPlaylist != null) _playlistHeader(),
            Expanded(
              child: _tab == 0
                  ? _localList(tracks)
                  : _tab == 2
                      ? PlaylistsPanel(
                          dj: widget.dj,
                          library: widget.library,
                          playlists: _localPlaylists,
                        )
                      : _remoteList(),
            ),
          ],
        ),
      ),
    );
  }

  void _openFilters() {
    final lib = widget.library;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SideDeckTheme.panel,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          var lo = lib.bpmMin ?? 60;
          var hi = lib.bpmMax ?? 200;
          lo = lo.clamp(60, 200).toDouble();
          hi = hi.clamp(60, 200).toDouble();
          final bpmOn = lib.bpmMin != null || lib.bpmMax != null;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Filters',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: lib.hasFilters
                            ? () {
                                lib.clearFilters();
                                setSheet(() {});
                              }
                            : null,
                        child: const Text('Clear all'),
                      ),
                    ],
                  ),
                  Text(
                    bpmOn ? 'Tempo ${lo.round()} to ${hi.round()} BPM' : 'Tempo: any',
                    style: const TextStyle(fontSize: 13),
                  ),
                  RangeSlider(
                    values: RangeValues(lo, hi),
                    min: 60,
                    max: 200,
                    divisions: 140,
                    labels: RangeLabels('${lo.round()}', '${hi.round()}'),
                    onChanged: (v) {
                      lib.setFilters(bpmMin: v.start, bpmMax: v.end);
                      setSheet(() {});
                    },
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final r in const [
                        ('House 118-128', 118.0, 128.0),
                        ('Breaks 128-140', 128.0, 140.0),
                        ('DnB 160-180', 160.0, 180.0),
                        ('Slow 60-100', 60.0, 100.0),
                      ])
                        ActionChip(
                          label: Text(r.$1, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            lib.setFilters(bpmMin: r.$2, bpmMax: r.$3);
                            setSheet(() {});
                          },
                        ),
                      if (bpmOn)
                        ActionChip(
                          label: const Text('Any tempo', style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            lib.setFilters(clearBpm: true);
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Decade', style: TextStyle(fontSize: 13)),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final d in const [1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020])
                        FilterChip(
                          label: Text('${d}s', style: const TextStyle(fontSize: 12)),
                          selected: lib.decades.contains(d),
                          onSelected: (_) {
                            lib.toggleDecade(d);
                            setSheet(() {});
                          },
                        ),
                      FilterChip(
                        label: const Text('Unknown', style: TextStyle(fontSize: 12)),
                        selected: lib.decades.contains(0),
                        onSelected: (_) {
                          lib.toggleDecade(0);
                          setSheet(() {});
                        },
                      ),
                    ],
                  ),
                  if (lib.genres.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Genre (from the file tags)', style: TextStyle(fontSize: 13)),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final g in lib.genres.take(24))
                          ChoiceChip(
                            label: Text('${g.$1} (${g.$2})', style: const TextStyle(fontSize: 12)),
                            selected: lib.genreFilter.toLowerCase() == g.$1.toLowerCase(),
                            onSelected: (_) {
                              lib.setGenre(g.$1);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text('Key', style: TextStyle(fontSize: 13)),
                  Wrap(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('Any', style: TextStyle(fontSize: 12)),
                        selected: lib.keyDeck < 0,
                        onSelected: (_) {
                          lib.setFilters(keyDeck: -1);
                          setSheet(() {});
                        },
                      ),
                      for (var i = 0; i < 2; i++)
                        ChoiceChip(
                          label: Text('Mixes with deck ${i + 1}',
                              style: const TextStyle(fontSize: 12)),
                          selected: lib.keyDeck == i,
                          onSelected: (_) {
                            lib.setFilters(keyDeck: i);
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Not analysed yet only'),
                    value: lib.onlyUnanalyzed,
                    onChanged: (v) {
                      lib.setFilters(onlyUnanalyzed: v);
                      setSheet(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Hide tracks played in the last 24 hours'),
                    value: lib.hidePlayed,
                    onChanged: (v) {
                      lib.setFilters(hidePlayed: v);
                      setSheet(() {});
                    },
                  ),
                  Text('${lib.organised.length} of ${lib.tracks.length} tracks shown',
                      style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Tap the genre: why it was fetched, what it is tagged as, and a list to
  /// change it.
  void _genreMenu(LibraryTrack t) {
    final asked = AutoFetch.instance.askedFor[t.path] ?? '';
    final typed = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) {
        Future<void> pick(String g) async {
          Navigator.pop(ctx);
          await widget.library.setGenre(t.path, g);
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text('Genre now: ${t.genre.isEmpty ? 'not set' : t.genre}',
                      style: const TextStyle(fontSize: 12)),
                  if (asked.isNotEmpty)
                    Text('Downloaded while looking for: $asked',
                        style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: typed,
                    decoration: const InputDecoration(
                        labelText: 'Type a genre and press enter', isDense: true),
                    onSubmitted: (v) => pick(v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      for (final grp in genreGroups)
                        for (final g in grp.$2)
                          ActionChip(
                            label: Text(g.name),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => pick(g.name),
                          ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => pick(''),
                    child: const Text('Back to the genre in the file'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Hold a track: a small sheet with Backup and Delete.
  void _trackMenu(LibraryTrack t) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SideDeckTheme.panel,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (t.artist.isNotEmpty)
                Text(t.artist, style: const TextStyle(fontSize: 12, color: SideDeckTheme.muted)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  widget.dj.automixDrop(t.path);
                  await BackupTracks.add(t.path);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Saved in the playlist "Backup tracks".')),
                  );
                },
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Backup: keep it and come back to it another time'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Keeps the file, puts it in the playlist "Backup tracks" and takes it out of automix for now.',
                style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                onPressed: () {
                  Navigator.pop(ctx);
                  _deleteTrack(t);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete and never play or search for it again'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Removes the file from this phone and your library. Automix will not pick it and auto-fetch will not look for it.',
                style: TextStyle(fontSize: 11, color: SideDeckTheme.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteTrack(LibraryTrack t) async {
    for (var i = 0; i < widget.dj.visibleDecks; i++) {
      final d = widget.dj.deck(i);
      if (d.loaded && d.path == t.path) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('It is loaded on deck ${i + 1}. Load something else first.')),
        );
        return;
      }
    }
    await Dislikes.instance.add(t.path);
    widget.dj.automixDrop(t.path);
    await widget.library.deleteTracks([t]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Deleted. It will not be picked or searched for again.')),
    );
  }

  CheckedPopupMenuItem<TrackSort> _sortItem(TrackSort value, String label) {
    return CheckedPopupMenuItem(
      value: value,
      checked: widget.library.sort == value,
      child: Text(label),
    );
  }

  List<T> _sorted<T>(
    List<T> src,
    ({String title, String artist, double? bpm, int? key}) Function(T) meta,
  ) {
    final list = List<T>.from(src);
    list.sort((a, b) {
      final x = meta(a);
      final y = meta(b);
      return compareTrackSort(
        widget.library.sort,
        x.title,
        x.artist,
        x.bpm,
        x.key,
        y.title,
        y.artist,
        y.bpm,
        y.key,
      );
    });
    return list;
  }

  Widget? _trackArtist(String artist, {String? status}) {
    final line = (status == null || status.isEmpty)
        ? artist
        : (artist.isEmpty ? status : '$artist · $status');
    if (line.isEmpty) return null;
    return Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
    );
  }

  Color? _compatibleKeyColor(int? key) {
    if (key == null || key < 0) return null;
    Color? color;
    for (var i = 0; i < 2; i++) {
      final d = widget.dj.deck(i);
      if (!d.loaded || d.key < 0 || !keysCompatible(d.key, key)) continue;
      final accent = i == 0 ? SideDeckTheme.accentA : SideDeckTheme.accentB;
      if (color != null && color != accent) return SideDeckTheme.text;
      color = accent;
    }
    return color;
  }

  Widget _trackMeta(double? bpm, int? key, double durationSec) {
    final hasBpm = bpm != null && bpm > 0;
    final hasKey = key != null && key >= 0;
    final keyColor = _compatibleKeyColor(key);
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            hasBpm ? bpm.toStringAsFixed(1) : '—',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: hasBpm ? SideDeckTheme.text : SideDeckTheme.muted,
            ),
          ),
          if (durationSec > 0 || hasKey)
            Text.rich(
              TextSpan(
                style: const TextStyle(color: SideDeckTheme.muted, fontSize: 11),
                children: [
                  if (durationSec > 0) TextSpan(text: formatDuration(durationSec)),
                  if (durationSec > 0 && hasKey) const TextSpan(text: '  '),
                  if (hasKey)
                    TextSpan(
                      text: formatKey(key),
                      style: keyColor == null
                          ? null
                          : TextStyle(color: keyColor, fontWeight: FontWeight.w700),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabBtn(String label, int i) {
    final on = _tab == i;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          foregroundColor: on ? Colors.white : SideDeckTheme.muted,
          backgroundColor: on ? SideDeckTheme.panelAlt : Colors.transparent,
        ),
        onPressed: () {
          setState(() => _tab = i);
          if (i == 1 && _client != null && !_searching && _openPlaylist == null && _playlists.isEmpty) {
            _loadPlaylists();
          }
        },
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: on ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _statusLine(LibraryController lib) {
    if (lib.error != null) {
      return Text(
        lib.error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
      );
    }
    if (lib.analyzing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            minHeight: 2,
            value: lib.analyzeTotal == 0 ? null : lib.analyzeDone / lib.analyzeTotal,
          ),
          const SizedBox(height: 2),
          Text(
            'Analyzing ${lib.analyzeDone + 1}/${lib.analyzeTotal}'
            '${lib.analyzingPath == null ? '' : ' — ${p.basename(lib.analyzingPath!)}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ],
      );
    }
    return Row(
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Loading ${widget.dj.loadingTitle ?? 'track'} → '
            '${widget.dj.loadingDeck == 0 ? 'A' : 'B'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: SideDeckTheme.muted),
          ),
        ),
      ],
    );
  }

  Widget _songRow({
    required bool busyThis,
    required String analyzeTooltip,
    required VoidCallback? onAnalyze,
    required String title,
    required String artist,
    String? status,
    required double? bpm,
    required int? key,
    required double durationSec,
    required List<Widget> actions,
    VoidCallback? onLongPress,
    String? genre,
    VoidCallback? onGenreTap,
  }) {
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: busyThis
                ? const Padding(
                    padding: EdgeInsets.all(6),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: analyzeTooltip,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                    onPressed: onAnalyze,
                    icon: const Icon(Icons.graphic_eq, size: 20),
                  ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    if (_trackArtist(artist, status: status) != null)
                      Flexible(child: _trackArtist(artist, status: status)!),
                    if (onGenreTap != null) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: onGenreTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: (genre ?? '').isEmpty ? SideDeckTheme.muted : const Color(0xFFFF9F1C)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text((genre ?? '').isEmpty ? 'set genre' : genre!,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: (genre ?? '').isEmpty
                                          ? SideDeckTheme.muted
                                          : const Color(0xFFFF9F1C))),
                              const Icon(Icons.arrow_drop_down, size: 14),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          _trackMeta(bpm, key, durationSec),
          const SizedBox(width: 6),
          ...actions,
        ],
      ),
      ),
    );
  }

  Widget _localList(List<LibraryTrack> tracks) {
    final lib = widget.library;
    if (lib.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tap the folder icon, choose your music folder.\n'
            'Then Analyze (waveform icon) for BPM/key, or tap A / B to load.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SideDeckTheme.muted),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final analyzingThis = lib.analyzingPath == t.path;
        final loadingThis = widget.dj.loadingPath == t.path;
        final busy = lib.analyzing || widget.dj.loadingDeck != null;
        return _songRow(
          busyThis: analyzingThis,
          analyzeTooltip: t.hasAnalysis
              ? 'Re-analyze BPM / grid'
              : 'Analyze BPM / key',
          onAnalyze: busy ? null : () => _analyzeLocal(t),
          onLongPress: () => _trackMenu(t),
          genre: t.genre,
          onGenreTap: () => _genreMenu(t),
          title: t.title,
          artist: t.artist,
          bpm: t.bpm,
          key: t.key,
          durationSec: t.durationMs / 1000.0,
          actions: [
            for (var k = 0; k < widget.dj.visibleDecks; k++) ...[
              if (k > 0) const SizedBox(width: 6),
              _deckBtn('ABCD'[k], busy ? null : () => _loadLocal(t, k),
                  loadingThis && widget.dj.loadingDeck == k),
            ],
          ],
        );
      },
    );
  }

  Widget _deckBtn(String label, VoidCallback? onPressed, [bool loading = false]) {
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size(36, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onPressed,
      child: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }

  Widget _playlistHeader() {
    final pl = _openPlaylist!;
    final count = pl.songCount > 0 ? '${pl.songCount}' : '${_remote.length}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Playlists',
            visualDensity: VisualDensity.compact,
            onPressed: _loadPlaylists,
            icon: const Icon(Icons.arrow_back, size: 20),
          ),
          Expanded(
            child: Text(
              pl.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '$count tracks',
            style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _playlistList() {
    if (_playlists.isEmpty) {
      return const Center(
        child: Text(
          'No playlists on this server yet.\n'
          'Search and press enter to find tracks.',
          textAlign: TextAlign.center,
          style: TextStyle(color: SideDeckTheme.muted),
        ),
      );
    }
    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (context, i) {
        final pl = _playlists[i];
        final subtitle = [
          if (pl.owner.isNotEmpty) pl.owner,
          if (pl.songCount > 0) '${pl.songCount} tracks',
          if (pl.duration > 0) formatDuration(pl.duration.toDouble()),
        ].join(' · ');
        return ListTile(
          dense: true,
          leading: const Icon(Icons.queue_music, size: 22),
          title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SideDeckTheme.muted, fontSize: 12),
                ),
          trailing: const Icon(Icons.chevron_right, size: 20, color: SideDeckTheme.muted),
          onTap: () => _openRemotePlaylist(pl),
        );
      },
    );
  }

  Widget _remoteList() {
    if (_client == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set up a Subsonic server in Settings first.',
              style: TextStyle(color: SideDeckTheme.muted),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: widget.onOpenSettings,
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    if (_remoteLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_remoteError != null) {
      return Center(
        child: Text(_remoteError!, style: const TextStyle(color: Colors.redAccent)),
      );
    }
    if (!_searching && _openPlaylist == null) {
      return _playlistList();
    }
    if (_remote.isEmpty) {
      return Center(
        child: Text(
          _searching
              ? 'No matching tracks.\nClear the box to go back to playlists.'
              : 'This playlist is empty.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: SideDeckTheme.muted),
        ),
      );
    }
    final remote = _sorted(
      _remote,
      (t) {
        final m = _remoteMeta[t.id];
        return (title: t.title, artist: t.artist, bpm: m?.bpm, key: m?.key);
      },
    );
    return ListView.builder(
      itemCount: remote.length,
      itemBuilder: (context, i) {
        final t = remote[i];
        final meta = _remoteMeta[t.id];
        final busyThis = _remoteBusyId == t.id;
        final busy = _remoteBusyId != null || widget.dj.loadingDeck != null;
        return _songRow(
          busyThis: busyThis,
          analyzeTooltip: meta == null
              ? 'Download & analyze'
              : 'Re-analyze BPM / grid',
          onAnalyze: busy ? null : () => _analyzeRemote(t),
          title: t.title,
          artist: t.artist,
          status: busyThis ? _remoteBusyLabel : null,
          bpm: meta?.bpm,
          key: meta?.key,
          durationSec: t.duration.toDouble(),
          actions: [
            for (var k = 0; k < widget.dj.visibleDecks; k++) ...[
              if (k > 0) const SizedBox(width: 6),
              _deckBtn('ABCD'[k], busy ? null : () => _loadRemote(t, k)),
            ],
          ],
        );
      },
    );
  }
}
