import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as plugin;
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:downloader/features/downloads/data/plugin_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real desktop engine, SQLite commit faults, replay and explicit acknowledgement',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('plugin-engine-real-');
      final db = sqlite3.open('${root.path}/business.sqlite');
      final store = AppStore(db);
      var engine = await PluginEngine.open(
        store: store,
        journalDirectory: Directory('${root.path}/execution'),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var mode = 'unknown';
      var zeroRequests = 0;
      var requests = 0;
      final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
      server.listen((request) async {
        requests++;
        final range = request.headers.value('range');
        final offset = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (range == null) zeroRequests++;
        final response = request.response;
        response.headers.set('Accept-Ranges', 'bytes');
        response.headers.set('ETag', '"stable"');
        if (range != null && mode != '200') {
          response.statusCode = 206;
          response.headers.set(
            'Content-Range',
            'bytes $offset-${bytes.length - 1}/${bytes.length}',
          );
        }
        final start = mode == '200' ? 0 : offset;
        if (mode != 'unknown') response.contentLength = bytes.length - start;
        try {
          for (var i = start; i < bytes.length; i += 8192) {
            response.add(bytes.sublist(i, i + 8192));
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await response.close();
        } catch (_) {}
      });
      final events = <EngineEvent>[];
      StreamSubscription<EngineEvent>? subscription = engine.events.listen(
        events.add,
      );
      try {
        final empty = await engine.inspect();
        expect(empty.receipts, isEmpty);
        expect(empty.ownerSessionId, isNotEmpty);
        final key = ExecutionKey(
          taskId: 'task',
          engineId: 'engine',
          generation: 0,
        );
        final directory = DirectoryLocation(
          platform: DownloadPlatform.macos,
          kind: DirectoryKind.systemDownloads,
          displayName: 'Downloads',
        );
        final now = DateTime.now().toUtc();
        final initial = DownloadTask(
          id: key.taskId,
          requestId: 'request',
          engineId: key.engineId,
          generation: 0,
          originalUrl: 'http://127.0.0.1:${server.port}/data',
          displayName: 'file',
          directory: directory,
          status: DownloadStatus.queued,
          downloadedBytes: 0,
          createdAt: now,
          updatedAt: now,
        );
        store.transaction((tx) => tx.saveTask(initial));
        final input = EngineTask(
          key: key,
          url: initial.originalUrl,
          directory: directory,
          stagingLocation: '${root.path}/staging/file',
        );
        final enqueue = EngineCommand(
          commandId: 'enqueue',
          key: key,
          ownerSessionId: empty.ownerSessionId,
          expectedReceiptVersion: 0,
        );
        await engine.enqueue(enqueue, input);
        await engine.enqueue(enqueue, input);
        Future<EngineReceipt> latest() async => (await engine.inspect())
            .receipts
            .where((r) => r.key == key)
            .reduce((a, b) => a.receiptVersion > b.receiptVersion ? a : b);
        Future<EngineReceipt> until(
          bool Function(EngineReceipt) predicate,
        ) async {
          for (var i = 0; i < 500; i++) {
            final current = await latest();
            if (predicate(current)) return current;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          throw TimeoutException('No expected durable receipt');
        }

        await until((r) => r.downloadedBytes > 8192);
        expect(zeroRequests, 1);
        final beforePause = await latest();
        expect(beforePause.totalBytes, isNull);
        final pauseCommand = EngineCommand(
          commandId: 'pause',
          key: key,
          ownerSessionId: empty.ownerSessionId,
          expectedReceiptVersion: beforePause.receiptVersion,
        );
        final paused = await engine.pause(pauseCommand);
        expect(paused.state, DownloadStatus.paused);
        expect(paused.resumeRef, isNotNull);
        expect((await engine.pause(pauseCommand)).toJson(), paused.toJson());
        final id = base64Url
            .encode(utf8.encode(jsonEncode(key.toJson())))
            .replaceAll('=', '');
        final journal = Directory('${root.path}/execution/$id');
        final raw = plugin.ExecutionJournal.latest(journal)!;
        final material = File(raw['resumeData']['data'] as String);
        final contents = material.readAsBytesSync();
        expect(contents.length, paused.downloadedBytes);
        expect(
          events.any(
            (event) => event.downloadedBytes > 0 && event.totalBytes == null,
          ),
          isTrue,
        );

        // Fault 1: durable execution, no business commit or acknowledgement.
        await subscription.cancel();
        subscription = null;
        await engine.close();
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        expect((await latest()).toJson(), paused.toJson());
        final replayedEvents = <EngineEvent>[];
        subscription = engine.events.listen(replayedEvents.add);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          replayedEvents,
          isEmpty,
          reason: 'Old samples cannot become fresh samples in a new clock',
        );
        await subscription.cancel();
        subscription = null;
        // Fault 2: read, then restart before business commit.
        await engine.inspect();
        await engine.close();
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        expect((await latest()).toJson(), paused.toJson());
        final ack = ReceiptAck(key: key, receiptVersion: paused.receiptVersion);
        await expectLater(
          engine.acknowledge(ack),
          throwsA(isA<PluginEngineException>()),
        );
        final aligned = DownloadTask.fromJson({
          ...initial.toJson(),
          'status': paused.state.name,
          'downloadedBytes': paused.downloadedBytes,
          'engineReceipt': paused.toJson(),
        });
        db.execute(
          "CREATE TRIGGER commit_failure BEFORE INSERT ON engine_receipt_acks BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
        expect(
          () => store.transaction((tx) => tx.commitReceipt(aligned, ack)),
          throwsA(isA<SqliteException>()),
        );
        expect(store.readAcknowledgements(), isEmpty);
        await expectLater(
          engine.acknowledge(ack),
          throwsA(isA<PluginEngineException>()),
        );
        db.execute('DROP TRIGGER commit_failure');
        expect(
          store.transaction((tx) => tx.commitReceipt(aligned, ack)),
          isTrue,
        );
        // Fault 3: AppStore committed, restart before acknowledge.
        await engine.close();
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        expect((await latest()).toJson(), paused.toJson());
        final acknowledgedFile = plugin.ExecutionJournal.versions(journal).last;
        final acknowledgedOriginal = acknowledgedFile.readAsStringSync();
        try {
          final changed =
              jsonDecode(acknowledgedOriginal) as Map<String, dynamic>;
          changed['downloadedBytes'] = paused.downloadedBytes + 1;
          acknowledgedFile.writeAsStringSync(jsonEncode(changed), flush: true);
          await expectLater(
            engine.acknowledge(ack),
            throwsA(isA<PluginEngineException>()),
          );
        } finally {
          acknowledgedFile.writeAsStringSync(acknowledgedOriginal, flush: true);
        }
        await engine.acknowledge(store.readAcknowledgements().single);
        await engine.acknowledge(ack);
        expect(material.readAsBytesSync(), contents);
        final requestCount = requests;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(requests, requestCount);
        await engine.enqueue(
          enqueue,
          input,
        ); // persisted idempotent replay, old session
        expect(requests, requestCount);
        final session = (await engine.inspect()).ownerSessionId;
        await expectLater(
          engine.resume(
            EngineCommand(
              commandId: 'stale-session',
              key: key,
              ownerSessionId: empty.ownerSessionId,
              expectedReceiptVersion: paused.receiptVersion,
            ),
          ),
          throwsA(isA<PluginEngineException>()),
        );
        await expectLater(
          engine.resume(
            EngineCommand(
              commandId: 'stale-receipt',
              key: key,
              ownerSessionId: session,
              expectedReceiptVersion: 0,
            ),
          ),
          throwsA(isA<PluginEngineException>()),
        );
        await expectLater(
          engine.enqueue(
            EngineCommand(
              commandId: 'enqueue',
              key: key,
              ownerSessionId: session,
              expectedReceiptVersion: 0,
            ),
            input,
          ),
          throwsA(isA<PluginEngineException>()),
        );
        final wrongGeneration = ExecutionKey(
          taskId: key.taskId,
          engineId: key.engineId,
          generation: 1,
        );
        await expectLater(
          engine.resume(
            EngineCommand(
              commandId: 'wrong-generation',
              key: wrongGeneration,
              ownerSessionId: session,
              expectedReceiptVersion: 0,
            ),
          ),
          throwsA(isA<PluginEngineException>()),
        );
        mode = '200';
        await engine.resume(
          EngineCommand(
            commandId: 'resume',
            key: key,
            ownerSessionId: session,
            expectedReceiptVersion: paused.receiptVersion,
          ),
        );
        final failed = await until((r) => r.state == DownloadStatus.failed);
        expect(failed.error?.code, FailureCode.restartRequired);
        expect(material.readAsBytesSync(), contents);
        expect(zeroRequests, 1);
        await engine.acknowledge(
          ack,
        ); // old ack cannot remove newer failure/material
        expect(material.readAsBytesSync(), contents);
        expect((await latest()).receiptVersion, failed.receiptVersion);
        expect(failed.resumeRef, isNotNull);
        final failedAck = ReceiptAck(
          key: key,
          receiptVersion: failed.receiptVersion,
        );
        store.transaction(
          (tx) => tx.commitReceipt(
            DownloadTask.fromJson({
              ...aligned.toJson(),
              'status': failed.state.name,
              'engineReceipt': failed.toJson(),
            }),
            failedAck,
          ),
        );
        await engine.acknowledge(failedAck);
        expect(material.readAsBytesSync(), contents);
        // Recovery attempts register retained originals/copy candidates as one
        // owned execution material set; explicit release must reclaim the set.
        final retained = File('${journal.path}/retained-tail')
          ..writeAsBytesSync(contents, flush: true);
        final failedRaw = plugin.ExecutionJournal.latest(journal)!;
        plugin.ExecutionJournal.record(
          plugin.DownloadTask.fromJson(
            Map<String, dynamic>.from(failedRaw['task']),
          ),
          {
            'ownedMaterials': [
              retained.path,
              '${journal.path}/interrupted-copy',
            ],
          },
        );
        final releaseVersion = (await latest()).receiptVersion;
        final cancelled = await engine.cancel(
          EngineCommand(
            commandId: 'cancel',
            key: key,
            ownerSessionId: session,
            expectedReceiptVersion: releaseVersion,
          ),
        );
        final release = ReceiptAck(
          key: key,
          receiptVersion: cancelled.receiptVersion,
          releaseResumeRefs: [cancelled.resumeRef!],
        );
        store.transaction(
          (tx) => tx.commitReceipt(
            DownloadTask.fromJson({
              ...aligned.toJson(),
              'status': cancelled.state.name,
              'engineReceipt': cancelled.toJson(),
            }),
            release,
          ),
        );
        // A persisted locator must not authorize traversal or symlink deletion.
        final currentFile = plugin.ExecutionJournal.versions(journal).last;
        final original = currentFile.readAsStringSync();
        final victim = File('${journal.parent.path}/foreign')
          ..writeAsStringSync('foreign', flush: true);
        final alias = Link('${journal.path}/alias')..createSync(victim.path);
        final parentAlias = Link('${journal.path}/external')
          ..createSync(journal.parent.path);
        try {
          for (final locator in [
            '${journal.path}/../foreign',
            alias.path,
            '${parentAlias.path}/foreign',
          ]) {
            final tampered = jsonDecode(original) as Map<String, dynamic>;
            tampered['resumeData']['data'] = locator;
            currentFile.writeAsStringSync(jsonEncode(tampered), flush: true);
            await expectLater(
              engine.acknowledge(release),
              throwsA(isA<PluginEngineException>()),
            );
            expect(victim.readAsStringSync(), 'foreign');
            expect(material.existsSync(), isTrue);
            expect(retained.existsSync(), isTrue);
          }
          // A bad final member must not delete earlier valid members.
          final badSet = jsonDecode(original) as Map<String, dynamic>;
          badSet['ownedMaterials'] = [retained.path, victim.path];
          currentFile.writeAsStringSync(jsonEncode(badSet), flush: true);
          await expectLater(
            engine.acknowledge(release),
            throwsA(isA<PluginEngineException>()),
          );
          expect(material.existsSync(), isTrue);
          expect(retained.existsSync(), isTrue);
          expect(victim.readAsStringSync(), 'foreign');
        } finally {
          currentFile.writeAsStringSync(original, flush: true);
          alias.deleteSync();
          parentAlias.deleteSync();
          victim.deleteSync();
        }
        await engine.acknowledge(release);
        await engine.acknowledge(release);
        expect(material.existsSync(), isFalse);
        expect(retained.existsSync(), isFalse);
        expect(File(input.stagingLocation).existsSync(), isFalse);

        // Force a real plugin queue entry: cancellation must persist a receipt
        // without starting a worker or leaving an entry that later downloads.
        final desktop = DesktopDownloader();
        final previousLimit = desktop.maxConcurrent;
        final queuedKey = ExecutionKey(
          taskId: 'queued',
          engineId: 'queued',
          generation: 0,
        );
        final queueInput = EngineTask(
          key: queuedKey,
          url: initial.originalUrl,
          directory: directory,
          stagingLocation: '${root.path}/staging/queued',
        );
        final requestsBeforeQueue = requests;
        desktop.maxConcurrent = 0;
        try {
          final queueCommand = EngineCommand(
            commandId: 'enqueue-queued',
            key: queuedKey,
            ownerSessionId: session,
            expectedReceiptVersion: 0,
          );
          final executionDb = sqlite3.open(
            '${root.path}/execution/commands.sqlite',
          );
          try {
            executionDb.execute(
              "CREATE TRIGGER command_failure BEFORE INSERT ON commands "
              "BEGIN SELECT RAISE(ABORT,'injected'); END",
            );
            await expectLater(
              engine.enqueue(queueCommand, queueInput),
              throwsA(isA<SqliteException>()),
            );
            expect(executionDb.select('SELECT * FROM executions').length, 1);
            executionDb.execute('DROP TRIGGER command_failure');
          } finally {
            executionDb.close();
          }
          await engine.enqueue(queueCommand, queueInput);
          final queued = (await engine.inspect()).receipts
              .where((r) => r.key == queuedKey)
              .reduce((a, b) => a.receiptVersion > b.receiptVersion ? a : b);
          final stopped = await engine.cancel(
            EngineCommand(
              commandId: 'cancel-queued',
              key: queuedKey,
              ownerSessionId: session,
              expectedReceiptVersion: queued.receiptVersion,
            ),
          );
          expect(stopped.state, DownloadStatus.cancelling);
          expect(requests, requestsBeforeQueue);
          expect(
            (await plugin.FileDownloader().allTasks(allGroups: true)).any(
              (task) =>
                  task.taskId ==
                  base64Url
                      .encode(utf8.encode(jsonEncode(queuedKey.toJson())))
                      .replaceAll('=', ''),
            ),
            isFalse,
          );
        } finally {
          desktop.maxConcurrent = previousLimit;
        }
      } finally {
        await subscription?.cancel();
        await engine.close();
        await server.close(force: true);
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
