/// Groups genre names (from file tags or Deezer) into families so that
/// "Deep House", "Tech House" and "Disco" count as similar, while "Drum &
/// Bass" does not mix into them.
const _families = <String, List<String>>{
  'house': ['house', 'disco', 'garage', 'balearic', 'afro', 'soulful', 'funk', 'amapiano'],
  'techno': ['techno', 'minimal', 'acid', 'industrial', 'schranz', 'tech'],
  'trance': ['trance', 'progressive', 'psy', 'goa'],
  'breaks': ['breaks', 'breakbeat', 'electro', 'big beat', 'bass', 'dubstep', 'grime', 'uk funky'],
  'dnb': ['drum', 'dnb', 'd&b', 'jungle', 'liquid', 'neurofunk', 'hardcore'],
  'dub': ['dub', 'reggae', 'dancehall', 'roots'],
  'ambient': ['ambient', 'downtempo', 'chill', 'electronica', 'idm', 'new age', 'trip'],
  'hiphop': ['hip', 'rap', 'trap', 'r&b', 'rnb', 'soul'],
  'pop': ['pop', 'rock', 'indie', 'alternative', 'singer'],
};

/// Families that sit next to each other and mix well.
const _near = <String, Set<String>>{
  'house': {'techno', 'breaks'},
  'techno': {'house', 'trance', 'breaks'},
  'trance': {'techno'},
  'breaks': {'house', 'techno', 'dnb'},
  'dnb': {'breaks'},
  'dub': {'ambient'},
  'ambient': {'dub'},
  'hiphop': {'breaks'},
  'pop': {},
};

/// The family of [genre], or null when unknown or empty.
String? genreFamily(String genre) {
  final g = genre.toLowerCase();
  if (g.trim().isEmpty) return null;
  // "tech house" is house-family first, "dub techno" is techno-family first,
  // so test the most specific wording before the single words.
  if (g.contains('dub techno')) return 'techno';
  if (g.contains('tech house') || g.contains('deep house')) return 'house';
  if (g.contains('drum') && g.contains('bass')) return 'dnb';
  for (final e in _families.entries) {
    for (final k in e.value) {
      if (g.contains(k)) return e.key;
    }
  }
  return null;
}

/// True when two genres are the same family or neighbours. Unknown genres
/// count as a match (the tempo decides).
bool genresSimilar(String a, String b) {
  final fa = genreFamily(a);
  final fb = genreFamily(b);
  if (fa == null || fb == null) return true;
  return fa == fb || (_near[fa]?.contains(fb) ?? false);
}
