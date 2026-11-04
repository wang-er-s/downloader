// Explicit opt-in production HTTP/file test (>4GiB); not part of app test/.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/download_isolate.dart'
    as transfer;
import 'package:background_downloader/src/desktop/isolate.dart' as worker;
import 'package:background_downloader/src/desktop/material_digest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real >4GiB HTTP transfer, bounded checkpoints and stopped file authentication',
    () async {
      HttpOverrides.global = null;
      final root = Directory.systemTemp.createTempSync('download-real-4gib-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final updates = ReceivePort();
      const threshold = 4294967296 + 8 * 1024 * 1024;
      const total = threshold + 128 * 1024 * 1024;
      final block = Uint8List.fromList(
        List.generate(64 * 1024, (i) => i % 256),
      );
      final expectedBlockHash = sha256.convert(block).toString();
      var requestedPause = false;
      final stopClock = Stopwatch();
      final subscription = updates.listen((message) {
        if (message is (String, int, int?, int) &&
            message.$1 == 'bytesUpdate' &&
            message.$2 >= threshold) {
          if (!requestedPause) {
            requestedPause = true;
            stopClock.start();
            worker.isPaused = true;
          }
        }
      });
      var served = 0;
      final serverSub = server.listen((request) async {
        request.response.contentLength = total;
        request.response.headers.set('ETag', '"large-v1"');
        request.response.headers.set('Accept-Ranges', 'bytes');
        try {
          while (served < total) {
            request.response.add(block);
            served += block.length;
            await request.response.flush();
            if (served >= threshold) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          }
          await request.response.close();
        } catch (_) {}
      });
      final task = DownloadTask(
        taskId: 'large',
        url: 'http://127.0.0.1:${server.port}/large',
        directory: root.path,
        filename: 'staging',
        baseDirectory: BaseDirectory.root,
        retries: 0,
        allowPause: true,
        updates: Updates.statusAndProgress,
        metaData: jsonEncode({'executionJournal': '${root.path}/journal'}),
      );
      worker.bytesTotal = 0;
      worker.startByte = 0;
      worker.isPaused = false;
      worker.isCanceled = false;
      worker.taskException = null;
      worker.lastByteCheckpoint = -1000;
      final elapsed = Stopwatch()..start();
      try {
        await transfer.doDownloadTask(
          task,
          null,
          false,
          const Duration(seconds: 60),
          root.path,
          updates.sendPort,
        );
        elapsed.stop();
        stopClock.stop();
        final directory = ExecutionJournal.directoryFor(task)!;
        final raw = ExecutionJournal.latest(directory)!;
        expect(raw['status'], TaskStatus.paused.index);
        final offset = raw['downloadedBytes'] as int;
        expect(offset, greaterThan(4294967296));
        final material = File(raw['resumeData']['data'] as String);
        expect(material.lengthSync(), offset);
        expect(worker.downloadDigest!.length, offset);
        final checkpointClock = Stopwatch()..start();
        final output = material.openWrite(mode: FileMode.append);
        await worker.checkpointDownload(output, task);
        await output.close();
        checkpointClock.stop();
        // Actual complete disk read with content validation, bounded at 64KiB.
        var verified = 0;
        await for (final bytes in material.openRead()) {
          expect(bytes.length, block.length);
          expect(sha256.convert(bytes).toString(), expectedBlockHash);
          verified += bytes.length;
        }
        expect(verified, offset);
        expect(raw['materialHash'], startsWith(MaterialDigest.prefix));
        // No periodic/final historical reads are needed: the live state agrees
        // with an independent rebuild of the authenticated disk prefix.
        final verifyClock = Stopwatch()..start();
        expect(
          await MaterialDigest.verify(
            material,
            offset,
            raw['materialHash'] as String,
          ),
          isNotNull,
        );
        verifyClock.stop();
        // ignore: avoid_print
        print(
          'LARGE_HTTP bytes=$offset served=$served transferMs=${elapsed.elapsedMilliseconds} '
          'pauseMs=${stopClock.elapsedMilliseconds} checkpointMicros=${checkpointClock.elapsedMicroseconds} '
          'diskRebuildMs=${verifyClock.elapsedMilliseconds} rss=${ProcessInfo.currentRss} peakRss=${ProcessInfo.maxRss} '
          'digestBufferBytes=${MaterialDigest.blockSize} contentVerified=$verified root=${root.path}',
        );
      } finally {
        await subscription.cancel();
        updates.close();
        await server.close(force: true);
        await serverSub.cancel();
        root.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
