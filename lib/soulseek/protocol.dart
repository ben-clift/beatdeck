import 'dart:convert';
import 'dart:typed_data';

/// Builds Soulseek wire messages. All numbers are little endian.
class MsgWriter {
  final BytesBuilder _b = BytesBuilder();

  MsgWriter u8(int v) {
    _b.addByte(v & 0xFF);
    return this;
  }

  MsgWriter u32(int v) {
    final d = ByteData(4)..setUint32(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
    return this;
  }

  MsgWriter u64(int v) {
    final d = ByteData(8)
      ..setUint32(0, v & 0xFFFFFFFF, Endian.little)
      ..setUint32(4, (v >> 32) & 0xFFFFFFFF, Endian.little);
    _b.add(d.buffer.asUint8List());
    return this;
  }

  MsgWriter boolean(bool v) => u8(v ? 1 : 0);

  MsgWriter str(String s) {
    final bytes = utf8.encode(s);
    u32(bytes.length);
    _b.add(bytes);
    return this;
  }

  Uint8List get bytes => _b.toBytes();

  /// Server and peer messages: length, 32 bit code, payload.
  Uint8List frame(int code) {
    final body = bytes;
    final out = MsgWriter()
      ..u32(body.length + 4)
      ..u32(code);
    out._b.add(body);
    return out.bytes;
  }

  /// Connection set-up messages: length, 8 bit code, payload.
  Uint8List initFrame(int code) {
    final body = bytes;
    final out = MsgWriter()
      ..u32(body.length + 1)
      ..u8(code);
    out._b.add(body);
    return out.bytes;
  }
}

/// Reads fields from a received message body.
class MsgReader {
  MsgReader(this.data) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData _view;
  int pos = 0;

  int get remaining => data.length - pos;

  int u8() => data[pos++];

  int u32() {
    final v = _view.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    final lo = _view.getUint32(pos, Endian.little);
    final hi = _view.getUint32(pos + 4, Endian.little);
    pos += 8;
    return hi * 4294967296 + lo;
  }

  bool boolean() => u8() != 0;

  String str() {
    final n = u32();
    final s = utf8.decode(
      Uint8List.sublistView(data, pos, pos + n),
      allowMalformed: true,
    );
    pos += n;
    return s;
  }

  /// Soulseek sends an IPv4 address as four bytes in reverse order.
  String ip() {
    final a = data[pos + 3];
    final b = data[pos + 2];
    final c = data[pos + 1];
    final d = data[pos];
    pos += 4;
    return '$a.$b.$c.$d';
  }
}

/// Collects socket bytes and hands back complete length-prefixed frames.
class FrameBuffer {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  void add(List<int> chunk) {
    if (_pending.isEmpty) {
      _pending = Uint8List.fromList(chunk);
    } else {
      final merged = BytesBuilder()
        ..add(_pending)
        ..add(chunk);
      _pending = merged.toBytes();
    }
  }

  /// Bytes not yet consumed (used when a connection switches to raw data).
  Uint8List takeRest() {
    final r = _pending;
    _pending = Uint8List(0);
    return r;
  }

  /// Returns the next frame body (without the length), or null.
  Uint8List? next() {
    if (_pending.length < 4) return null;
    final len = ByteData.sublistView(_pending).getUint32(0, Endian.little);
    if (len > 64 * 1024 * 1024) {
      throw const FormatException('Frame too large');
    }
    if (_pending.length < 4 + len) return null;
    final body = Uint8List.sublistView(_pending, 4, 4 + len);
    _pending = Uint8List.sublistView(_pending, 4 + len);
    return Uint8List.fromList(body);
  }

  void clear() {
    _buf.clear();
    _pending = Uint8List(0);
  }
}
