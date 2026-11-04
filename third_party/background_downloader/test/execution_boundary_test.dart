import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:async/async.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/download_isolate.dart'
    as transfer;
import 'package:background_downloader/src/desktop/isolate.dart' as worker;
import 'package:crypto/crypto.dart';
import 'package:background_downloader/src/desktop/material_digest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late ReceivePort commands;
  late StreamQueue<dynamic> commandQueue;
  late ReceivePort updates;
  late StreamSubscription<dynamic> updateSubscription;
  late String behavior;
  late int zeroRequests;
  final body = List<int>.generate(96 * 1024, (i) => i % 251);

  setUp(() async {
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('plugin-boundary-');
    behavior = 'safe';
    zeroRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value('range');
      final start =
          range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (range == null) zeroRequests++;
      final response = request.response;
      response.headers.set('Accept-Ranges', 'bytes');
      if (behavior != 'noETag') {
        response.headers.set(
          'ETag',
          behavior == 'weak'
              ? 'W/"v1"'
              : behavior == 'changed'
              ? '"v2"'
              : '"v1"',
        );
      }
      if (behavior == '416') {
        response.statusCode = 416;
        await response.close();
        return;
      }
      var offset = start;
      final end =
          ['shortSuffix', 'changedTotal'].contains(behavior)
              ? body.length - 1025
              : body.length - 1;
      if (range != null && behavior != '200') {
        response.statusCode = 206;
        response.headers.set(
          'Content-Range',
          'bytes ${behavior == 'badRange' ? start + 1 : start}-${behavior == 'rangeLength' ? body.length - 2 : end}/${behavior == 'changedTotal' ? end + 1 : body.length}',
        );
      } else {
        offset = 0;
      }
      if (behavior != 'unknown') response.contentLength = end + 1 - offset;
      try {
        for (var i = offset; i <= end; i += 1024) {
          response.add(body.sublist(i, i + 1024));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await response.close();
      } catch (_) {
        // Expected when a resume is rejected before consuming the body.
      }
    });
    worker.isCanceled = false;
    worker.isPaused = false;
    worker.bytesTotal = 0;
    worker.startByte = 0;
    worker.taskException = null;
    worker.lastByteCheckpoint = -1000;
    transfer.taskRangeStartByte = 0;
    commands = ReceivePort();
    commandQueue = StreamQueue<dynamic>(commands);
    updates = ReceivePort();
    updateSubscription = updates.listen((_) {});
  });

  tearDown(() async {
    await commandQueue.cancel(immediate: true);
    commands.close();
    await updateSubscription.cancel();
    updates.close();
    await server.close(force: true);
    root.deleteSync(recursive: true);
  });

  DownloadTask task() => DownloadTask(
    taskId: 'execution',
    url: 'http://127.0.0.1:${server.port}/data',
    baseDirectory: BaseDirectory.root,
    directory: root.path,
    filename: 'staging',
    allowPause: true,
    retries: 0,
    updates: Updates.statusAndProgress,
    metaData: jsonEncode({'executionJournal': '${root.path}/journal'}),
  );

  Future<void> run(DownloadTask task, {ResumeData? resume}) =>
      transfer.doDownloadTask(
        task,
        resume,
        resume != null,
        const Duration(seconds: 5),
        root.path,
        updates.sendPort,
      );

  for (final format in ['legacy', 'chain']) {
    for (final mode in [
      'safe',
      '200',
      '416',
      'changed',
      'badRange',
      'badPrefix',
    ]) {
      test(
        'checkpoint8192 with uncommitted tail24576: $format $mode',
        () async {
          final input = task();
          final material = File('${root.path}/journal/original')
            ..createSync(recursive: true);
          material.writeAsBytesSync(body.sublist(0, 24576), flush: true);
          final resume = ResumeData(input, material.path, 8192, '"v1"');
          ExecutionJournal.record(input, {
            'status': 7,
            'downloadedBytes': 8192,
            'totalBytes': body.length,
            'resumeData': resume.toJson(),
            'materialHash':
                format == 'legacy'
                    ? sha256.convert(body.sublist(0, 8192)).toString()
                    : (MaterialDigest()..add(body.sublist(0, 8192))).snapshot(),
          });
          if (mode == 'badPrefix') {
            final file = material.openSync(mode: FileMode.writeOnlyAppend);
            file.setPositionSync(0);
            file.writeByteSync(99);
            file.closeSync();
          }
          final before = sha256.convert(material.readAsBytesSync()).toString();
          behavior = mode;
          await run(input, resume: resume);
          expect(material.lengthSync(), 24576);
          expect(sha256.convert(material.readAsBytesSync()).toString(), before);
          expect(zeroRequests, 0);
          if (mode == 'safe') {
            expect(worker.taskException, isNull);
            expect(File('${root.path}/staging').readAsBytesSync(), body);
            final raw =
                ExecutionJournal.latest(ExecutionJournal.directoryFor(input)!)!;
            expect(raw['ownedMaterials'], contains(material.path));
            expect(raw['recoveryOperation']['phase'], 'ready');
          } else {
            expect(worker.taskException, isA<TaskResumeException>());
            expect(File('${root.path}/staging').existsSync(), isFalse);
          }
        },
      );
    }
  }

  test(
    'interrupted prefix copy retains intent and retries without authenticating tail',
    () async {
      final input = task();
      final source = File('${root.path}/journal/original')
        ..createSync(recursive: true);
      source.writeAsBytesSync(body.sublist(0, 24576), flush: true);
      final originalHash = sha256.convert(source.readAsBytesSync()).toString();
      final resume = ResumeData(input, source.path, 8192, '"v1"');
      ExecutionJournal.record(input, {
        'status': 7,
        'downloadedBytes': 8192,
        'totalBytes': body.length,
        'resumeData': resume.toJson(),
        'materialHash': sha256.convert(body.sublist(0, 8192)).toString(),
      });
      final attempt = transfer.forkCheckpoint(input, source.path, 8192);
      final journal = ExecutionJournal.directoryFor(input)!;
      final copying = ExecutionJournal.latest(journal)!;
      expect(copying['recoveryOperation']['phase'], 'copying');
      final candidate = File(
        copying['recoveryOperation']['candidate'] as String,
      );
      expect(candidate.existsSync(), isTrue);
      // Filesystem fault at the first asynchronous copy boundary, not OS kill.
      candidate.deleteSync();
      final obstruction = Directory(candidate.path)..createSync();
      await expectLater(attempt, throwsA(anything));
      obstruction.deleteSync();
      final failed = ExecutionJournal.latest(journal)!;
      expect(failed['resumeData'], resume.toJson());
      expect(failed['downloadedBytes'], 8192);
      expect(failed['recoveryOperation']['phase'], 'copying');
      expect(failed['ownedMaterials'], contains(candidate.path));
      expect(source.lengthSync(), 24576);
      expect(sha256.convert(source.readAsBytesSync()).toString(), originalHash);
      await run(input, resume: resume);
      final complete = ExecutionJournal.latest(journal)!;
      expect(complete['ownedMaterials'], contains(candidate.path));
      expect(complete['recoveryOperation']['candidate'], isNot(candidate.path));
      expect(complete['recoveryOperation']['phase'], 'ready');
      expect(File('${root.path}/staging').readAsBytesSync(), body);
      expect(sha256.convert(source.readAsBytesSync()).toString(), originalHash);
    },
  );

  test('failed journal publication preserves pending evidence on retry', () {
    final input = task();
    ExecutionJournal.record(input, {'status': 1});
    final directory = ExecutionJournal.directoryFor(input)!;
    final blocked = Directory('${directory.path}/2.json')..createSync();
    expect(
      () => ExecutionJournal.record(input, {'downloadedBytes': 11}),
      throwsA(isA<FileSystemException>()),
    );
    final pending = directory.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.pending'),
    );
    final evidence = pending.readAsStringSync();
    expect(ExecutionJournal.latest(directory)!['receiptVersion'], 1);
    blocked.deleteSync();
    ExecutionJournal.record(input, {'downloadedBytes': 12});
    expect(pending.readAsStringSync(), evidence);
    expect(ExecutionJournal.latest(directory)!['downloadedBytes'], 12);
  });

  for (final rejected in [
    '200',
    '416',
    'badRange',
    'weak',
    'changed',
    'noETag',
    'rangeLength',
    'shortSuffix',
    'changedTotal',
    'corrupt',
    'missing',
  ]) {
    test(
      'actual resume GET rejects $rejected without modifying original material',
      () async {
        final input = task();
        final material = File('${root.path}/journal/partial')
          ..createSync(recursive: true);
        material.writeAsBytesSync(body.sublist(0, 4096), flush: true);
        final digest = sha256.convert(material.readAsBytesSync()).toString();
        final resume = ResumeData(input, material.path, 4096, '"v1"');
        ExecutionJournal.record(input, {
          'status': TaskStatus.paused.index,
          'downloadedBytes': 4096,
          'totalBytes': body.length,
          'resumeData': resume.toJson(),
          'materialHash': digest,
        });
        behavior = rejected;
        if (rejected == 'corrupt') {
          material.writeAsBytesSync(List.filled(4096, 42), flush: true);
        }
        if (rejected == 'missing') material.deleteSync();
        final before =
            material.existsSync()
                ? sha256.convert(material.readAsBytesSync()).toString()
                : null;
        await run(input, resume: resume);
        expect(worker.taskException, isA<TaskResumeException>());
        expect(
          material.existsSync()
              ? sha256.convert(material.readAsBytesSync()).toString()
              : null,
          before,
        );
        if (before != null) expect(material.lengthSync(), 4096);
        expect(zeroRequests, 0);
        final raw =
            ExecutionJournal.latest(ExecutionJournal.directoryFor(input)!)!;
        expect(raw['status'], TaskStatus.failed.index);
        expect(raw['resumeData'], isNotNull);
      },
    );
  }

  test('actual strong-validator 206 appends exact bytes', () async {
    final input = task();
    final material = File('${root.path}/journal/partial')
      ..createSync(recursive: true);
    material.writeAsBytesSync(body.sublist(0, 4096), flush: true);
    final resume = ResumeData(input, material.path, 4096, '"v1"');
    ExecutionJournal.record(input, {
      'status': 7,
      'resumeData': resume.toJson(),
      'downloadedBytes': 4096,
      'materialHash': sha256.convert(material.readAsBytesSync()).toString(),
    });
    await run(input, resume: resume);
    expect(worker.taskException, isNull);
    expect(File('${root.path}/staging').readAsBytesSync(), body);
    expect(zeroRequests, 0);
  });

  test(
    'unknown-length slow body checkpoints increasing actual bytes before EOF',
    () async {
      behavior = 'unknown';
      final input = task();
      final running = run(input);
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      final during =
          ExecutionJournal.latest(ExecutionJournal.directoryFor(input)!)!;
      expect(during['downloadedBytes'], greaterThan(0));
      expect(during['downloadedBytes'], lessThan(body.length));
      expect(during['totalBytes'], isNull);
      expect(during['sampleMonotonicMs'], greaterThan(0));
      await running;
      final records =
          ExecutionJournal.versions(
            ExecutionJournal.directoryFor(input)!,
          ).map((file) => jsonDecode(file.readAsStringSync()) as Map).toList();
      final samples =
          records.where((r) => r['sampleMonotonicMs'] != null).toList();
      expect(
        samples.map((r) => r['downloadedBytes']).toSet().length,
        greaterThan(1),
      );
      expect(File('${root.path}/staging').readAsBytesSync(), body);
    },
  );

  test(
    'actual pause stops writes, preserves material and resumes through guarded GET',
    () async {
      final input = task();
      final running = run(input);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      worker.isPaused = true;
      await running;
      final raw =
          ExecutionJournal.latest(ExecutionJournal.directoryFor(input)!)!;
      expect(raw['status'], TaskStatus.paused.index);
      final resume = ResumeData.fromJson(
        Map<String, dynamic>.from(raw['resumeData']),
      );
      final material = File(resume.data);
      final size = material.lengthSync();
      expect(size, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(material.lengthSync(), size);
      worker.isPaused = false;
      worker.bytesTotal = 0;
      worker.startByte = 0;
      worker.taskException = null;
      await run(input, resume: resume);
      expect(File('${root.path}/staging').readAsBytesSync(), body);
      expect(zeroRequests, 1);
    },
  );
}
