import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Genre and release year read from a file's tags (MP3 ID3v2, FLAC).
class TrackTags {
  const TrackTags(this.genre, this.year, [this.label = '']);
  final String genre;
  final int year;

  /// Record label (ID3 TPUB, FLAC LABEL), empty when not tagged.
  final String label;
  static const empty = TrackTags('', 0);
}

const _id3v1Genres = [
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge',
  'Hip-Hop', 'Jazz', 'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B',
  'Rap', 'Reggae', 'Rock', 'Techno', 'Industrial', 'Alternative', 'Ska',
  'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno', 'Ambient', 'Trip-Hop',
  'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical', 'Instrumental',
  'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', 'Alt Rock', 'Bass',
  'Soul', 'Punk', 'Space', 'Meditative', 'Instrumental Pop',
  'Instrumental Rock', 'Ethnic', 'Gothic', 'Darkwave', 'Techno-Industrial',
  'Electronic', 'Pop-Folk', 'Eurodance', 'Dream', 'Southern Rock', 'Comedy',
  'Cult', 'Gangsta', 'Top 40', 'Christian Rap', 'Pop/Funk', 'Jungle',
  'Native American', 'Cabaret', 'New Wave', 'Psychadelic', 'Rave',
  'Showtunes', 'Trailer', 'Lo-Fi', 'Tribal', 'Acid Punk', 'Acid Jazz', 'Polka',
  'Retro', 'Musical', 'Rock & Roll', 'Hard Rock',
];

String _cleanGenre(String raw) {
  var g = raw.replaceAll('\u0000', ' ').trim();
  if (g.isEmpty) return '';
  // "(17)" or "(17)Rock" or just "17".
  final m = RegExp(r'^\((\d{1,3})\)\s*(.*)$').firstMatch(g);
  if (m != null) {
    final rest = (m.group(2) ?? '').trim();
    if (rest.isNotEmpty) return rest;
    final n = int.parse(m.group(1)!);
    return n < _id3v1Genres.length ? _id3v1Genres[n] : '';
  }
  if (RegExp(r'^\d{1,3}$').hasMatch(g)) {
    final n = int.parse(g);
    return n < _id3v1Genres.length ? _id3v1Genres[n] : '';
  }
  // Several genres: keep the first.
  g = g.split(RegExp(r'[;/\u0000]')).first.trim();
  return g;
}

int _yearOf(String s) {
  final m = RegExp(r'(19|20)\d{2}').firstMatch(s);
  return m == null ? 0 : int.parse(m.group(0)!);
}

String _decode(Uint8List b) {
  if (b.isEmpty) return '';
  final enc = b[0];
  final body = b.sublist(1);
  try {
    switch (enc) {
      case 1:
      case 2:
        var bigEndian = enc == 2;
        var start = 0;
        if (body.length >= 2) {
          if (body[0] == 0xFE && body[1] == 0xFF) {
            bigEndian = true;
            start = 2;
          } else if (body[0] == 0xFF && body[1] == 0xFE) {
            bigEndian = false;
            start = 2;
          }
        }
        final units = <int>[];
        for (var i = start; i + 1 < body.length; i += 2) {
          units.add(bigEndian ? (body[i] << 8) | body[i + 1] : (body[i + 1] << 8) | body[i]);
        }
        return String.fromCharCodes(units);
      case 3:
        return utf8.decode(body, allowMalformed: true);
      default:
        return latin1.decode(body);
    }
  } catch (_) {
    return '';
  }
}

/// Reads the genre and year from the start of the file. Never throws.
Future<TrackTags> readTrackTags(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    final head = await f.read(10);
    if (head.length >= 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      return await _id3(f, head);
    }
    if (head.length >= 4 && head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
      return await _flac(f);
    }
  } catch (_) {
  } finally {
    await f?.close();
  }
  return TrackTags.empty;
}

Future<TrackTags> _id3(RandomAccessFile f, Uint8List head) async {
  final ver = head[3];
  final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
  final end = 10 + size;
  var pos = 10;
  if (head[5] & 0x40 != 0) {
    // Extended header: skip it.
    await f.setPosition(pos);
    final eh = await f.read(4);
    if (eh.length == 4) {
      final n = ver == 4
          ? (eh[0] << 21) | (eh[1] << 14) | (eh[2] << 7) | eh[3]
          : (eh[0] << 24) | (eh[1] << 16) | (eh[2] << 8) | eh[3];
      pos += ver == 4 ? n : n + 4;
    }
  }
  var genre = '';
  var year = 0;
  var recording = 0;
  var label = '';
  final idLen = ver == 2 ? 3 : 4;
  final hdrLen = ver == 2 ? 6 : 10;
  while (pos + hdrLen < end) {
    await f.setPosition(pos);
    final h = await f.read(hdrLen);
    if (h.length < hdrLen || h[0] == 0) break;
    final id = String.fromCharCodes(h.sublist(0, idLen));
    int n;
    if (ver == 2) {
      n = (h[3] << 16) | (h[4] << 8) | h[5];
    } else if (ver == 4) {
      n = (h[4] << 21) | (h[5] << 14) | (h[6] << 7) | h[7];
    } else {
      n = (h[4] << 24) | (h[5] << 16) | (h[6] << 8) | h[7];
    }
    if (n <= 0 || pos + hdrLen + n > end + 1) break;
    final wanted = const {'TCON', 'TCO', 'TYER', 'TYE', 'TDRC', 'TORY', 'TDOR', 'TDRL', 'TPUB', 'TPB'};
    if (wanted.contains(id) && n < 4096) {
      final data = await f.read(n);
      final text = _decode(data);
      if (id == 'TCON' || id == 'TCO') genre = _cleanGenre(text);
      if (id == 'TYER' || id == 'TYE' || id == 'TDRC' || id == 'TDRL') year = year == 0 ? _yearOf(text) : year;
      if (id == 'TORY' || id == 'TDOR') recording = _yearOf(text);
      if (id == 'TPUB' || id == 'TPB') label = text.trim();
    }
    pos += hdrLen + n;
  }
  // The original release year is the better one for a reissue.
  return TrackTags(genre, recording > 0 ? recording : year, label);
}

Future<TrackTags> _flac(RandomAccessFile f) async {
  var pos = 4;
  for (var i = 0; i < 64; i++) {
    await f.setPosition(pos);
    final h = await f.read(4);
    if (h.length < 4) break;
    final last = h[0] & 0x80 != 0;
    final type = h[0] & 0x7F;
    final len = (h[1] << 16) | (h[2] << 8) | h[3];
    if (type == 4 && len < 262144) {
      final data = await f.read(len);
      final bd = ByteData.sublistView(data);
      var o = 0;
      if (len < 8) break;
      final vendor = bd.getUint32(o, Endian.little);
      o += 4 + vendor;
      if (o + 4 > len) break;
      final count = bd.getUint32(o, Endian.little);
      o += 4;
      var genre = '';
      var year = 0;
      var original = 0;
      var label = '';
      for (var c = 0; c < count && o + 4 <= len; c++) {
        final l = bd.getUint32(o, Endian.little);
        o += 4;
        if (o + l > len) break;
        final entry = utf8.decode(data.sublist(o, o + l), allowMalformed: true);
        o += l;
        final eq = entry.indexOf('=');
        if (eq <= 0) continue;
        final k = entry.substring(0, eq).toUpperCase();
        final v = entry.substring(eq + 1);
        if (k == 'GENRE' && genre.isEmpty) genre = _cleanGenre(v);
        if ((k == 'DATE' || k == 'YEAR') && year == 0) year = _yearOf(v);
        if (k == 'ORIGINALDATE' || k == 'ORIGINALYEAR') original = _yearOf(v);
        if ((k == 'LABEL' || k == 'ORGANIZATION' || k == 'PUBLISHER') && label.isEmpty) label = v.trim();
      }
      return TrackTags(genre, original > 0 ? original : year, label);
    }
    if (last) break;
    pos += 4 + len;
  }
  return TrackTags.empty;
}
