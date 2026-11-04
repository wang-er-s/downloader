import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/material_digest.dart';
import 'package:background_downloader/src/desktop/isolate.dart' as worker;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v1 known vectors independently generated with Python hashlib', () {
    const vectors = <int, String>{
      0: '1adb379c9e15a18e3b106821eaef2c79e3dea7622a143bdbb3b6fa1a53b54244',
      1: '5aabecac2eb5cb95b09fb1208dba946a6fdd39b12ce76dc8c2c5da2f6d0a44af',
      1048575:
          'caad181731771d6dae3fbd5ebf2c71de3188ce2985c0ff63a7e3b039b6545d22',
      1048576:
          '563d155b857b85d04727f38db24ba1629a1a99322012681c226a2e83c8e995d1',
      1048577:
          'b34eb0e7c24b92d5ba3d08f1f6ee56db5b400cdffabd62664b068bde0ee62a6c',
      3145745:
          'b9481711aeac36a3b3a7b674f645768568ee451eec8b793ed21c2b335f2cf84b',
    };
    for (final vector in vectors.entries) {
      final state =
          MaterialDigest()..add(
            Uint8List.fromList(List.generate(vector.key, (i) => i % 251)),
          );
      expect(state.length, vector.key);
      expect(state.snapshot(), '${MaterialDigest.prefix}${vector.value}');
    }
  });

  test(
    'fixed blocks, network slicing, repeated snapshots and continuing state',
    () {
      for (final length in [
        0,
        1,
        MaterialDigest.blockSize - 1,
        MaterialDigest.blockSize,
        MaterialDigest.blockSize + 1,
        3 * MaterialDigest.blockSize + 17,
      ]) {
        final bytes = Uint8List.fromList(List.generate(length, (i) => i % 251));
        final whole = MaterialDigest()..add(bytes);
        final sliced = MaterialDigest();
        for (var i = 0; i < bytes.length; i += 7919) {
          sliced.add(
            Uint8List.sublistView(
              bytes,
              i,
              i + 7919 < length ? i + 7919 : length,
            ),
          );
          final before = sliced.snapshot();
          expect(sliced.snapshot(), before);
        }
        expect(sliced.snapshot(), whole.snapshot());
        sliced.add([9, 8, 7]);
        whole.add([9, 8, 7]);
        expect(sliced.snapshot(), whole.snapshot());
      }
    },
  );

  test(
    'legacy/new prefix verification, tail exclusion, tampering and unknown formats',
    () async {
      final root = Directory.systemTemp.createTempSync('material-digest-');
      try {
        final data = Uint8List.fromList(
          List.generate(MaterialDigest.blockSize + 17, (i) => i % 251),
        );
        final file = File('${root.path}/data')
          ..writeAsBytesSync([...data, 88, 99]);
        final state = MaterialDigest()..add(data);
        final old = sha256.convert(data).toString();
        expect(
          (await MaterialDigest.verify(file, data.length, old))!.snapshot(),
          state.snapshot(),
        );
        expect(
          (await MaterialDigest.verify(
            file,
            data.length,
            state.snapshot(),
          ))!.snapshot(),
          state.snapshot(),
        );
        expect(
          await MaterialDigest.verify(
            file,
            data.length,
            'bd-chain-sha256-v2:bad',
          ),
          isNull,
        );
        final handle = file.openSync(mode: FileMode.writeOnlyAppend)
          ..setPositionSync(4);
        handle.writeByteSync(99);
        handle.closeSync();
        expect(await MaterialDigest.verify(file, data.length, old), isNull);
        expect(
          await MaterialDigest.verify(file, data.length, state.snapshot()),
          isNull,
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'production checkpoint requires only flush/stat, never historical reads',
    () async {
      final root = Directory.systemTemp.createTempSync('material-no-read-');
      try {
        final task = DownloadTask(
          taskId: 'no-read',
          url: 'https://example.org/data',
          metaData: jsonEncode({'executionJournal': root.path}),
        );
        final state = MaterialDigest()..add([1, 2, 3]);
        worker.downloadDigest = state;
        worker.downloadMaterial = _StatOnlyFile(3);
        worker.downloadCheckpointFailed = false;
        worker.bytesTotal = 3;
        worker.startByte = 0;
        await worker.checkpointDownload(_FlushOnlySink(), task);
        final first = ExecutionJournal.latest(root)!;
        expect(first['materialHash'], state.snapshot());
        expect(first['downloadedBytes'], 3);
        expect(worker.downloadCheckpointFailed, isFalse);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'flush or length failure preserves prior authenticated checkpoint',
    () async {
      final root = Directory.systemTemp.createTempSync('material-write-fault-');
      final port = ReceivePort();
      try {
        final file = File('${root.path}/material')..writeAsBytesSync([1, 2, 3]);
        final task = DownloadTask(
          taskId: 'write-fault',
          url: 'https://example.org/data',
          metaData: jsonEncode({'executionJournal': root.path}),
        );
        ExecutionJournal.record(task, {
          'downloadedBytes': 0,
          'materialHash': (MaterialDigest()).snapshot(),
        });
        worker.downloadDigest = MaterialDigest()..add([1, 2, 3]);
        worker.downloadMaterial = file;
        worker.bytesTotal = 3;
        worker.startByte = 0;
        final sink = file.openWrite(mode: FileMode.append);
        await expectLater(
          worker.checkpointDownload(_BrokenFlush(sink), task),
          throwsStateError,
        );
        expect(ExecutionJournal.latest(root)!['downloadedBytes'], 0);
        await sink.close();
        worker.downloadDigest = MaterialDigest()..add([1, 2, 3, 4]);
        final other = file.openWrite(mode: FileMode.append);
        await expectLater(
          worker.checkpointDownload(other, task),
          throwsA(isA<FileSystemException>()),
        );
        expect(ExecutionJournal.latest(root)!['downloadedBytes'], 0);
        await other.close();
      } finally {
        port.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}

final class _BrokenFlush implements IOSink {
  _BrokenFlush(this.delegate);
  final IOSink delegate;
  @override
  Future<void> flush() async => throw StateError('injected flush failure');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StatOnlyFile implements File {
  _StatOnlyFile(this.size);
  final int size;
  @override
  int lengthSync() => size;
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      throw StateError('historical read forbidden');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FlushOnlySink implements IOSink {
  @override
  Future<void> flush() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
