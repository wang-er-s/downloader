import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Bounded incremental authentication for private download material.
/// Chain blocks and the final tail have distinct domains; snapshot never closes
/// or consumes the running state. No proof array grows with the file.
final class MaterialDigest {
  static const blockSize = 1024 * 1024;
  static const prefix = 'bd-chain-sha256-v1:';
  final Uint8List _tail = Uint8List(blockSize);
  List<int> _chain = sha256.convert(utf8.encode('bd-material-v1:seed')).bytes;
  int _used = 0;
  int length = 0;

  void add(List<int> bytes) {
    var position = 0;
    while (position < bytes.length) {
      final available = blockSize - _used;
      final count =
          bytes.length - position < available
              ? bytes.length - position
              : available;
      _tail.setRange(_used, _used + count, bytes, position);
      _used += count;
      position += count;
      length += count;
      if (_used == blockSize) {
        _chain =
            _hash([utf8.encode('bd-material-v1:block'), _chain, _tail]).bytes;
        _used = 0;
      }
    }
  }

  String snapshot() {
    final size = ByteData(8)..setUint64(0, length, Endian.big);
    return '$prefix${_hash([utf8.encode('bd-material-v1:end'), _chain, size.buffer.asUint8List(), Uint8List.sublistView(_tail, 0, _used)])}';
  }

  static Digest _hash(List<List<int>> parts) {
    final result = _DigestResult();
    final sink = sha256.startChunkedConversion(result);
    for (final part in parts) {
      sink.add(part);
    }
    sink.close();
    return result.value!;
  }

  /// Rebuild from actual disk bytes. Legacy hashes are verified in the same
  /// pass as the new state; an unknown format never becomes trusted material.
  static Future<MaterialDigest?> verify(
    File file,
    int offset,
    String expected,
  ) async {
    final legacy = RegExp(r'^[0-9a-f]{64}$').hasMatch(expected);
    if (!legacy && !expected.startsWith(prefix)) return null;
    if (offset < 0 || !file.existsSync() || file.lengthSync() < offset) {
      return null;
    }
    final state = MaterialDigest();
    final result = _DigestResult();
    final old = legacy ? sha256.startChunkedConversion(result) : null;
    await for (final bytes in file.openRead(0, offset)) {
      state.add(bytes);
      old?.add(bytes);
    }
    old?.close();
    if (state.length != offset) return null;
    return (legacy
            ? result.value.toString() == expected
            : state.snapshot() == expected)
        ? state
        : null;
  }
}

final class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
