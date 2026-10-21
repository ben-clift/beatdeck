import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:sidedeck/debug/debug_log.dart';
import 'package:sidedeck/soulseek/ingest.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sidedeck/soulseek/protocol.dart';

/// One file offered by another Soulseek user.
class SlskResult {
  SlskResult({
    required this.user,
    required this.path,
    required this.size,
    required this.bitrate,
    required this.durationSec,
    required this.freeSlot,
    required this.speed,
    required this.queue,
  });

  final String user;
  final String path;
  final int size;
  final int bitrate;
  final int durationSec;
  final bool freeSlot;
  final int speed;
  final int queue;

  String get fileName {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  String get folder {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    if (i < 0) return '';
    final dir = path.substring(0, i);
    final j = dir.lastIndexOf(RegExp(r'[\\/]'));
    return j < 0 ? dir : dir.substring(j + 1);
  }

  String get ext {
    final i = fileName.lastIndexOf('.');
    return i < 0 ? '' : fileName.substring(i + 1).toLowerCase();
  }
}

enum DlState { connecting, queued, waiting, downloading, done, failed }

class SlskDownload {
  SlskDownload(this.result);

  final SlskResult result;
  DlState state = DlState.connecting;
  String message = '';
  int size = 0;
  int received = 0;
  int token = 0;
  String? savedPath;
  IOSink? sink;
  bool finishing = false;

  String get user => result.user;
  String get remotePath => result.path;
  double get progress => size > 0 ? received / size : 0;
}

enum SlskStatus { offline, connecting, online }

/// A small Soulseek client: sign in, search, and download into a folder.
///
/// Written from the public protocol description. It has not been tried on
/// the real network yet, so expect rough edges.
class SoulseekClient extends ChangeNotifier {
  SoulseekClient();

  static const _host = 'server.slsknet.org';
  static const _port = 2242;
  static const _audio = {
    'mp3', 'flac', 'wav', 'aif', 'aiff', 'm4a', 'ogg', 'opus', 'aac', 'wma',
  };

  SlskStatus status = SlskStatus.offline;
  String? error;
  String username = '';
  final List<SlskResult> results = [];
  final List<SlskDownload> downloads = [];
  bool searching = false;
  int resultUsers = 0;

  /// Folder that finished downloads are saved in.
  String Function()? downloadDir;

  /// Called after a file finishes so the library can pick it up.
  void Function(String path)? onFileSaved;

  /// Asked before each download starts: a reason to refuse, or null.
  Future<String?> Function(int size)? storageCheck;

  Socket? _server;
  ServerSocket? _listener;
  final FrameBuffer _serverBuf = FrameBuffer();
  Timer? _ping;
  Timer? _notifyTimer;
  Timer? _searchTimer;
  final math.Random _rng = math.Random();
  int _searchToken = 0;
  final Set<String> _usersSeen = {};
  final Map<String, _Peer> _peers = {};
  final Map<int, String> _pierceTokens = {};
  final Map<String, void Function(String ip, int port)> _addrWaiters = {};
  final Map<int, SlskDownload> _byToken = {};
  final List<_Peer> _anonymous = [];

  /// Set when the user signs out by hand, so auto-connect leaves it alone.
  bool manualDisconnect = false;

  bool get online => status == SlskStatus.online;

  int _newToken() => 1 + _rng.nextInt(0x7FFFFFFE);

  void _changed() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  // ---------------------------------------------------------------- server

  Future<void> connect(String user, String password) async {
    if (status != SlskStatus.offline) return;
    manualDisconnect = false;
    sweepPartials();
    username = user;
    status = SlskStatus.connecting;
    error = null;
    notifyListeners();
    try {
      _listener = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      _listener!.listen(_onIncoming, onError: (_) {});
      final s = await Socket.connect(
        _host,
        _port,
        timeout: const Duration(seconds: 15),
      );
      _server = s;
      s.setOption(SocketOption.tcpNoDelay, true);
      s.listen(
        _onServerData,
        onError: (Object e) => _serverLost('Connection lost'),
        onDone: () => _serverLost('Disconnected from the Soulseek server'),
        cancelOnError: true,
      );
      final hash = md5.convert(utf8.encode('$user$password')).toString();
      s.add(
        (MsgWriter()
              ..str(user)
              ..str(password)
              ..u32(160)
              ..str(hash)
              ..u32(1))
            .frame(1),
      );
    } catch (e) {
      _serverLost('Could not reach the Soulseek server ($e)');
    }
  }

  /// The server said this account signed in somewhere else (message 41).
  DateTime? kickedAt;
  DateTime? _onlineSince;

  void _serverLost(String why) {
    if (status == SlskStatus.offline && error != null) return;
    final up = _onlineSince == null ? null : DateTime.now().difference(_onlineSince!).inSeconds;
    DebugLog.add('soulseek',
        'connection ended: ${why.isEmpty ? 'signed out' : why}${up == null ? ' (never signed in)' : ' after $up s online'}');
    _onlineSince = null;
    _ping?.cancel();
    _server?.destroy();
    _server = null;
    _listener?.close();
    _listener = null;
    for (final peer in List.of(_peers.values)) {
      peer.close();
    }
    _peers.clear();
    status = SlskStatus.offline;
    error = why;
    searching = false;
    notifyListeners();
  }

  void disconnect() {
    manualDisconnect = true;
    error = null;
    _serverLost('');
    error = null;
    notifyListeners();
  }

  void _send(Uint8List frame) {
    try {
      _server?.add(frame);
    } catch (_) {}
  }

  void _onServerData(Uint8List data) {
    _serverBuf.add(data);
    try {
      Uint8List? body;
      while ((body = _serverBuf.next()) != null) {
        // One message the app cannot read must not end the connection.
        try {
          _onServerMessage(body!);
        } catch (e) {
          DebugLog.add('soulseek', 'a server message could not be read, ignored: $e');
        }
      }
    } catch (e) {
      _serverLost('Unexpected reply from the server ($e)');
    }
  }

  void _onServerMessage(Uint8List body) {
    final r = MsgReader(body);
    final code = r.u32();
    switch (code) {
      case 1: // login
        final ok = r.boolean();
        final text = r.str();
        if (!ok) {
          _serverLost('Sign in failed: $text');
          return;
        }
        status = SlskStatus.online;
        _onlineSince = DateTime.now();
        error = null;
        _send((MsgWriter()..u32(_listener?.port ?? 0)).frame(2)); // wait port
        _send((MsgWriter()..u32(2)).frame(28)); // online
        _send((MsgWriter()..u32(0)..u32(0)).frame(35)); // shared counts
        _send((MsgWriter()..boolean(true)).frame(71)); // no parent
        _ping = Timer.periodic(
          const Duration(minutes: 2),
          (_) => _send(MsgWriter().frame(32)),
        );
        notifyListeners();
      case 3: // peer address
        final user = r.str();
        final ip = r.ip();
        final port = r.u32();
        final cb = _addrWaiters.remove(user);
        cb?.call(ip, port);
      case 41: // signed in somewhere else
        kickedAt = DateTime.now();
        DebugLog.fail('soulseek', 'the server says this account signed in somewhere else');
        _serverLost('This Soulseek account is signed in on another device or app');
      case 18: // server asks us to connect to a peer
        final user = r.str();
        final type = r.str();
        final ip = r.ip();
        final port = r.u32();
        final token = r.u32();
        _connectOut(user, type, ip, port, token, pierce: true);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- search

  void search(String query) {
    if (!online || query.trim().isEmpty) {
      DebugLog.fail('search', 'search ignored (${online ? 'empty query' : 'not signed in'})');
      return;
    }
    DebugLog.add('search', 'searching: $query');
    results.clear();
    _usersSeen.clear();
    resultUsers = 0;
    searching = true;
    _searchToken = _newToken();
    _send(
      (MsgWriter()
            ..u32(_searchToken)
            ..str(query.trim()))
          .frame(26),
    );
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(seconds: 25), () {
      searching = false;
      notifyListeners();
    });
    notifyListeners();
  }

  void _onSearchReply(Uint8List compressed) {
    final raw = Uint8List.fromList(zlib.decode(compressed));
    final r = MsgReader(raw);
    final user = r.str();
    final token = r.u32();
    if (token != _searchToken) return;
    final n = r.u32();
    final files = <List<Object>>[];
    for (var i = 0; i < n; i++) {
      r.u8();
      final name = r.str();
      final size = r.u64();
      r.str(); // extension
      final attrCount = r.u32();
      var bitrate = 0;
      var duration = 0;
      for (var a = 0; a < attrCount; a++) {
        final t = r.u32();
        final v = r.u32();
        if (t == 0) bitrate = v;
        if (t == 1) duration = v;
      }
      files.add([name, size, bitrate, duration]);
    }
    var free = false;
    var speed = 0;
    var queue = 0;
    if (r.remaining >= 9) {
      free = r.boolean();
      speed = r.u32();
      queue = r.u32();
    }
    var added = false;
    for (final f in files) {
      final res = SlskResult(
        user: user,
        path: f[0] as String,
        size: f[1] as int,
        bitrate: f[2] as int,
        durationSec: f[3] as int,
        freeSlot: free,
        speed: speed,
        queue: queue,
      );
      if (_audio.contains(res.ext) && results.length < 1500) {
        results.add(res);
        added = true;
      }
    }
    if (added && _usersSeen.add(user)) resultUsers++;
    if (added) _changed();
  }

  // ------------------------------------------------------------- downloads

  void download(SlskResult r) {
    for (final d in downloads) {
      if (d.user == r.user &&
          d.remotePath == r.path &&
          d.state != DlState.failed) {
        return;
      }
    }
    final d = SlskDownload(r)..size = r.size;
    downloads.insert(0, d);
    final check = storageCheck;
    if (check == null) {
      _beginDownload(d);
    } else {
      d.message = 'Checking space';
      check(r.size).then((reason) {
        if (reason != null) {
          d.state = DlState.failed;
          d.message = reason;
          _changed();
        } else if (downloads.contains(d)) {
          _beginDownload(d);
        }
      });
    }
    notifyListeners();
  }

  /// A download that did not finish leaves half a file behind: delete it so
  /// it never turns up in the library or on a deck.
  void _discardPartial(SlskDownload d) {
    final path = d.savedPath;
    if (path == null || d.state == DlState.done) return;
    final sink = d.sink;
    d.sink = null;
    Future<void>(() async {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
        DebugLog.add('download', 'deleted the unfinished file $path');
      } catch (_) {}
      await _Partials.remove(path);
    });
  }

  /// Once per start: delete half-downloaded files left by a crash or a
  /// closed app.
  static bool _swept = false;
  Future<void> sweepPartials() async {
    if (_swept) return;
    _swept = true;
    for (final path in await _Partials.all()) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
          DebugLog.add('download', 'deleted a half-downloaded file left from before: $path');
        }
      } catch (_) {}
      await _Partials.remove(path);
    }
  }

  void removeDownload(SlskDownload d) {
    _discardPartial(d);
    d.sink?.close();
    _byToken.remove(d.token);
    downloads.remove(d);
    notifyListeners();
  }

  void _beginDownload(SlskDownload d) {
    d.state = DlState.connecting;
    d.message = 'Finding ${d.user}';
    final existing = _peers[d.user];
    if (existing != null && existing.type == 'P') {
      _queueOn(existing, d);
      return;
    }
    _addrWaiters[d.user] = (ip, port) {
      if (port == 0) {
        _fallbackRequest(d);
        return;
      }
      _connectOut(d.user, 'P', ip, port, _newToken(), pierce: false);
    };
    _send((MsgWriter()..str(d.user)).frame(3));
    Timer(const Duration(seconds: 12), () {
      if (d.state == DlState.connecting && _peers[d.user] == null) {
        _fallbackRequest(d);
      }
    });
  }

  void _fallbackRequest(SlskDownload d) {
    if (d.state != DlState.connecting) return;
    final token = _newToken();
    _pierceTokens[token] = d.user;
    d.message = 'Asking ${d.user} to connect to us';
    _send(
      (MsgWriter()
            ..u32(token)
            ..str(d.user)
            ..str('P'))
          .frame(18),
    );
    Timer(const Duration(seconds: 40), () {
      if (d.state == DlState.connecting) {
        d.state = DlState.failed;
        d.message = 'Could not connect to ${d.user}';
        _changed();
      }
    });
    _changed();
  }

  void _queueOn(_Peer peer, SlskDownload d) {
    peer.send((MsgWriter()..str(d.remotePath)).frame(43));
    d.state = DlState.queued;
    d.message = 'Waiting in ${d.user}\'s queue';
    _changed();
  }

  void _peerReady(_Peer peer) {
    if (peer.type != 'P' || peer.user.isEmpty) return;
    _peers[peer.user] = peer;
    for (final d in downloads) {
      if (d.user == peer.user && d.state == DlState.connecting) {
        _queueOn(peer, d);
      }
    }
  }

  void _onTransferRequest(_Peer peer, MsgReader r) {
    final direction = r.u32();
    final token = r.u32();
    final file = r.str();
    if (direction == 1) {
      final size = r.u64();
      SlskDownload? match;
      for (final d in downloads) {
        if (d.user == peer.user &&
            (d.remotePath == file ||
                d.result.fileName == file.split(RegExp(r'[\\/]')).last) &&
            (d.state == DlState.queued || d.state == DlState.connecting)) {
          match = d;
          break;
        }
      }
      if (match == null) {
        peer.send(
          (MsgWriter()
                ..u32(token)
                ..boolean(false)
                ..str('Cancelled'))
              .frame(41),
        );
        return;
      }
      match.token = token;
      match.size = size;
      match.state = DlState.waiting;
      match.message = 'Starting';
      _byToken[token] = match;
      peer.send(
        (MsgWriter()
              ..u32(token)
              ..boolean(true))
            .frame(41),
      );
      _changed();
    } else {
      peer.send(
        (MsgWriter()
              ..u32(token)
              ..boolean(false)
              ..str('File not shared.'))
            .frame(41),
      );
    }
  }

  // ----------------------------------------------------------------- peers

  Future<void> _connectOut(
    String user,
    String type,
    String ip,
    int port,
    int token, {
    required bool pierce,
  }) async {
    try {
      final s = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 8),
      );
      final peer = _Peer(s)
        ..user = user
        ..type = type;
      _attach(peer);
      if (pierce) {
        peer.send((MsgWriter()..u32(token)).initFrame(0));
      } else {
        peer.send(
          (MsgWriter()
                ..str(username)
                ..str(type)
                ..u32(token))
              .initFrame(1),
        );
      }
      if (type == 'F') {
        peer.raw = true;
      } else {
        _peerReady(peer);
      }
    } catch (_) {
      if (!pierce && type == 'P') {
        for (final d in downloads) {
          if (d.user == user && d.state == DlState.connecting) {
            _fallbackRequest(d);
          }
        }
      }
    }
  }

  void _onIncoming(Socket s) {
    final peer = _Peer(s);
    _anonymous.add(peer);
    _attach(peer);
  }

  void _attach(_Peer peer) {
    peer.socket.setOption(SocketOption.tcpNoDelay, true);
    peer.socket.listen(
      (data) => _onPeerData(peer, data),
      onError: (Object e) => _peerClosed(peer),
      onDone: () => _peerClosed(peer),
      cancelOnError: true,
    );
  }

  void _peerClosed(_Peer peer) {
    _anonymous.remove(peer);
    if (_peers[peer.user] == peer) _peers.remove(peer.user);
    final d = peer.download;
    if (d != null && d.state == DlState.downloading) {
      if (d.received > 0 && (d.size <= 0 || d.received >= d.size * 0.999)) {
        _finish(d);
      } else {
        DebugLog.add('download',
            'interrupted: received ${d.received} of ${d.size} from ${d.user}');
        d.state = DlState.failed;
        _discardPartial(d);
        d.message = 'Transfer interrupted';
        _changed();
      }
    }
    peer.close();
  }

  void _onPeerData(_Peer peer, Uint8List data) {
    try {
      if (peer.raw) {
        _onRaw(peer, data);
        return;
      }
      peer.buf.add(data);
      Uint8List? body;
      while ((body = peer.buf.next()) != null) {
        _onPeerFrame(peer, body!);
        if (peer.raw) {
          final rest = peer.buf.takeRest();
          if (rest.isNotEmpty) _onRaw(peer, rest);
          return;
        }
      }
    } catch (_) {
      peer.close();
    }
  }

  void _onPeerFrame(_Peer peer, Uint8List body) {
    final r = MsgReader(body);
    if (peer.type.isEmpty) {
      final code = r.u8();
      if (code == 0) {
        final token = r.u32();
        peer.user = _pierceTokens[token] ?? '';
        peer.type = 'P';
        _anonymous.remove(peer);
        _peerReady(peer);
      } else if (code == 1) {
        peer.user = r.str();
        peer.type = r.str();
        r.u32();
        _anonymous.remove(peer);
        if (peer.type == 'F') {
          peer.raw = true;
        } else {
          _peerReady(peer);
        }
      }
      return;
    }
    final code = r.u32();
    switch (code) {
      case 9: // search reply
        _onSearchReply(Uint8List.sublistView(body, 4));
      case 40:
        _onTransferRequest(peer, r);
      case 44: // place in queue
        final file = r.str();
        final place = r.u32();
        for (final d in downloads) {
          if (d.user == peer.user &&
              d.remotePath == file &&
              d.state == DlState.queued) {
            d.message = 'Queued, place $place';
          }
        }
        _changed();
      case 46: // upload failed
        final file = r.str();
        _failFor(peer.user, file, 'The other user could not send it');
      case 50: // upload denied
        final file = r.str();
        final why = r.remaining > 4 ? r.str() : 'Denied';
        _failFor(peer.user, file, why);
      default:
        break;
    }
  }

  void _failFor(String user, String file, String why) {
    for (final d in downloads) {
      if (d.user == user &&
          d.remotePath == file &&
          d.state != DlState.done &&
          d.state != DlState.downloading) {
        d.state = DlState.failed;
        d.message = why;
      }
    }
    _changed();
  }

  // ------------------------------------------------------- file connection

  /// Raw file connection: we read the transfer token, answer with the offset
  /// we want to start from, then everything that follows is file data.
  void _onRaw(_Peer peer, Uint8List data) {
    var chunk = data;
    if (peer.rawStage == 0) {
      peer.rawHead.add(data);
      final head = peer.rawHead.toBytes();
      if (head.length < 4) return;
      final token = ByteData.sublistView(head).getUint32(0, Endian.little);
      final d = _byToken[token];
      if (d == null) {
        peer.close();
        return;
      }
      if (!_startFile(peer, d)) return;
      peer.rawStage = 1;
      peer.send((MsgWriter()..u64(0)).bytes);
      chunk = Uint8List.sublistView(head, 4);
      if (chunk.isEmpty) return;
    }
    final d = peer.download;
    if (d == null || d.sink == null) return;
    d.sink!.add(chunk);
    d.received += chunk.length;
    _changed();
    if (d.size > 0 && d.received >= d.size) {
      _finish(d);
      peer.close();
    }
  }

  bool _startFile(_Peer peer, SlskDownload d) {
    final dir = downloadDir?.call();
    if (dir == null || dir.isEmpty) {
      d.state = DlState.failed;
      d.message = 'No download folder chosen';
      peer.close();
      _changed();
      return false;
    }
    final name = d.result.fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    var file = File(p.join(dir, name));
    var n = 1;
    while (file.existsSync()) {
      file = File(p.join(
        dir,
        '${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}',
      ));
      n++;
    }
    d.savedPath = file.path;
    d.sink = file.openWrite();
    _Partials.add(file.path);
    DebugLog.add('download', 'start ${file.path} (expect ${d.size} bytes) from ${d.user}');
    d.state = DlState.downloading;
    d.message = '';
    peer.download = d;
    return true;
  }

  Future<void> _finish(SlskDownload d) async {
    if (d.state == DlState.done || d.finishing) return;
    d.finishing = true;
    // Wait until every byte is on disk before anything tries to play it.
    final sink = d.sink;
    d.sink = null;
    try {
      await sink?.flush().timeout(const Duration(seconds: 6));
      await sink?.close().timeout(const Duration(seconds: 6));
    } catch (_) {}
    final saved = d.savedPath;
    if (saved != null) {
      final bad = await verifyDownload(saved, d.size);
      if (bad != null) {
        DebugLog.flow('Download to library', false, bad);
        DebugLog.add('download', 'REJECTED $saved: $bad');
        try {
          await File(saved).delete();
        } catch (_) {}
        d.state = DlState.failed;
        d.message = bad;
        _changed();
        return;
      }
    }
    d.state = DlState.done;
    d.message = 'Saved';
    if (saved != null) _Partials.remove(saved);
    DebugLog.flow('Download to library', true);
    _changed();
    if (saved != null) {
      DebugLog.add('download',
          'done: received ${d.received} of ${d.size}. On disk: ${await DebugLog.describeFile(saved)}');
      onFileSaved?.call(saved);
    }
  }

  @override
  void dispose() {
    _ping?.cancel();
    _notifyTimer?.cancel();
    _searchTimer?.cancel();
    _serverLost('');
    super.dispose();
  }
}

/// Paths of downloads still in progress, kept so a crash cannot leave a
/// half file in the library.
class _Partials {
  static const _key = 'slsk_partials';
  static Future<List<String>> all() async {
    try {
      return (await SharedPreferences.getInstance()).getStringList(_key) ?? [];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(String path) async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(_key) ?? [];
      if (!l.contains(path)) await p.setStringList(_key, [...l, path]);
    } catch (_) {}
  }

  static Future<void> remove(String path) async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(_key) ?? [];
      if (l.remove(path)) await p.setStringList(_key, l);
    } catch (_) {}
  }
}

class _Peer {
  _Peer(this.socket);

  final Socket socket;
  final FrameBuffer buf = FrameBuffer();
  String user = '';
  String type = '';
  bool raw = false;
  SlskDownload? download;
  int rawStage = 0; // 0 waiting for token, 1 receiving data
  final BytesBuilder rawHead = BytesBuilder();

  void send(Uint8List bytes) {
    try {
      socket.add(bytes);
    } catch (_) {}
  }

  void close() {
    try {
      socket.destroy();
    } catch (_) {}
  }
}

/// One client for the whole app, so a sign-in and downloads survive closing
/// the Soulseek screen.
final SoulseekClient soulseek = SoulseekClient();
