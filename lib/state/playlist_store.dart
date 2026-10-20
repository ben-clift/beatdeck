import 'dart:convert';

/// A named, ordered list of local track paths.
class Playlist {
  Playlist({required this.id, required this.name, List<String>? paths})
      : paths = paths ?? <String>[];

  final String id;
  String name;
  final List<String> paths;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'paths': paths};

  static Playlist? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String) return null;
    final paths = raw['paths'];
    return Playlist(
      id: id,
      name: name,
      paths: [
        if (paths is List)
          for (final p in paths)
            if (p is String) p,
      ],
    );
  }
}

/// Plain Dart playlist logic with no Flutter or storage code, so it can be
/// unit tested. [PlaylistController] saves it on the phone.
class PlaylistStore {
  PlaylistStore([Iterable<Playlist> initial = const []])
      : playlists = List<Playlist>.of(initial);

  final List<Playlist> playlists;
  int _counter = 0;

  Playlist? byId(String id) {
    for (final p in playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  String _newId() {
    String id;
    do {
      id = 'pl${DateTime.now().microsecondsSinceEpoch}_${_counter++}';
    } while (byId(id) != null);
    return id;
  }

  Playlist create(String name) {
    final trimmed = name.trim();
    final p = Playlist(id: _newId(), name: trimmed.isEmpty ? 'Playlist' : trimmed);
    playlists.add(p);
    return p;
  }

  bool rename(String id, String name) {
    final p = byId(id);
    final trimmed = name.trim();
    if (p == null || trimmed.isEmpty) return false;
    p.name = trimmed;
    return true;
  }

  bool delete(String id) {
    final before = playlists.length;
    playlists.removeWhere((p) => p.id == id);
    return playlists.length != before;
  }

  /// Adds [path] to the end. A track can only be in a playlist once.
  bool add(String id, String path) {
    final p = byId(id);
    if (p == null || path.isEmpty || p.paths.contains(path)) return false;
    p.paths.add(path);
    return true;
  }

  bool removeAt(String id, int index) {
    final p = byId(id);
    if (p == null || index < 0 || index >= p.paths.length) return false;
    p.paths.removeAt(index);
    return true;
  }

  /// Moves a track from [from] to [to] (indexes before the move).
  bool move(String id, int from, int to) {
    final p = byId(id);
    if (p == null) return false;
    final n = p.paths.length;
    if (from < 0 || from >= n || to < 0 || to >= n) return false;
    final item = p.paths.removeAt(from);
    p.paths.insert(to, item);
    return true;
  }

  /// Drops paths that no longer exist, e.g. after files were deleted.
  int pruneMissing(bool Function(String path) exists) {
    var removed = 0;
    for (final p in playlists) {
      final before = p.paths.length;
      p.paths.removeWhere((path) => !exists(path));
      removed += before - p.paths.length;
    }
    return removed;
  }

  String encode() => jsonEncode([for (final p in playlists) p.toJson()]);

  /// Reads what [encode] wrote. Bad or old data gives an empty store rather
  /// than an error, so a corrupt save can never stop the app opening.
  static PlaylistStore decode(String? source) {
    if (source == null || source.isEmpty) return PlaylistStore();
    try {
      final raw = jsonDecode(source);
      if (raw is! List) return PlaylistStore();
      return PlaylistStore([
        for (final item in raw)
          if (Playlist.fromJson(item) case final p?) p,
      ]);
    } catch (_) {
      return PlaylistStore();
    }
  }
}
