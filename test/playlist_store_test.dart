import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/state/playlist_store.dart';

void main() {
  test('create trims the name and falls back to a default', () {
    final s = PlaylistStore();
    expect(s.create('  Warm up  ').name, 'Warm up');
    expect(s.create('   ').name, 'Playlist');
    expect(s.playlists.length, 2);
  });

  test('ids are unique', () {
    final s = PlaylistStore();
    final ids = {for (var i = 0; i < 50; i++) s.create('x').id};
    expect(ids.length, 50);
  });

  test('add ignores duplicates and empty paths', () {
    final s = PlaylistStore();
    final p = s.create('a');
    expect(s.add(p.id, '/m/one.mp3'), isTrue);
    expect(s.add(p.id, '/m/one.mp3'), isFalse);
    expect(s.add(p.id, ''), isFalse);
    expect(s.add('nope', '/m/two.mp3'), isFalse);
    expect(p.paths, ['/m/one.mp3']);
  });

  test('move reorders and rejects bad indexes', () {
    final s = PlaylistStore();
    final p = s.create('a');
    for (final t in ['1', '2', '3', '4']) {
      s.add(p.id, t);
    }
    expect(s.move(p.id, 0, 2), isTrue);
    expect(p.paths, ['2', '3', '1', '4']);
    expect(s.move(p.id, 3, 0), isTrue);
    expect(p.paths, ['4', '2', '3', '1']);
    expect(s.move(p.id, 0, 9), isFalse);
    expect(s.move(p.id, -1, 0), isFalse);
    expect(p.paths, ['4', '2', '3', '1']);
  });

  test('removeAt, rename and delete', () {
    final s = PlaylistStore();
    final p = s.create('a');
    s.add(p.id, '1');
    s.add(p.id, '2');
    expect(s.removeAt(p.id, 0), isTrue);
    expect(s.removeAt(p.id, 5), isFalse);
    expect(p.paths, ['2']);
    expect(s.rename(p.id, ' Peak '), isTrue);
    expect(p.name, 'Peak');
    expect(s.rename(p.id, '  '), isFalse);
    expect(s.delete(p.id), isTrue);
    expect(s.delete(p.id), isFalse);
  });

  test('pruneMissing removes paths that are gone', () {
    final s = PlaylistStore();
    final p = s.create('a');
    s.add(p.id, '/keep.mp3');
    s.add(p.id, '/gone.mp3');
    expect(s.pruneMissing((path) => path == '/keep.mp3'), 1);
    expect(p.paths, ['/keep.mp3']);
  });

  test('encode and decode round trip', () {
    final s = PlaylistStore();
    final p = s.create('Night');
    s.add(p.id, '/a.mp3');
    s.add(p.id, '/b.mp3');
    final back = PlaylistStore.decode(s.encode());
    expect(back.playlists.length, 1);
    expect(back.playlists.first.id, p.id);
    expect(back.playlists.first.name, 'Night');
    expect(back.playlists.first.paths, ['/a.mp3', '/b.mp3']);
  });

  test('decode survives bad data', () {
    expect(PlaylistStore.decode(null).playlists, isEmpty);
    expect(PlaylistStore.decode('').playlists, isEmpty);
    expect(PlaylistStore.decode('not json').playlists, isEmpty);
    expect(PlaylistStore.decode('{"a":1}').playlists, isEmpty);
    final mixed = PlaylistStore.decode(
        '[1, {"id":"x","name":"ok","paths":["/a",2,"/b"]}, {"id":3}]');
    expect(mixed.playlists.length, 1);
    expect(mixed.playlists.first.paths, ['/a', '/b']);
  });
}
