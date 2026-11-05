import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart' as plugin;

import 'package:downloader/features/downloads/data/plugin_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/platform_file_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'file_storage_test.dart' show InterruptedChannel;

class CopyBarrierChannel extends MethodChannel {
  CopyBarrierChannel() : super('downloader/file_storage');
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final value = await super.invokeMethod<T>(method, arguments);
    if (method == 'copy') {
      entered.complete();
      await release.future;
    }
    return value;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'execution v1 migration retains history and failed or unknown versions retain database',
    (_) async {
      final root = await (await getApplicationSupportDirectory()).createTemp(
        'release-migration-',
      );
      final store = AppStore(sqlite3.openInMemory());
      final path = '${root.path}/commands.sqlite';
      var db = sqlite3.open(path);
      db.execute(
        "CREATE TABLE commands(id TEXT PRIMARY KEY,payload TEXT NOT NULL,result TEXT); INSERT INTO commands VALUES('history','old',NULL); PRAGMA user_version=1;",
      );
      db.close();
      try {
        final engine = await PluginEngine.open(
          store: store,
          journalDirectory: root,
        );
        await engine.close();
        db = sqlite3.open(path);
        expect(db.userVersion, 2);
        expect(
          db.select('SELECT payload FROM commands').single['payload'],
          'old',
        );
        db.execute(
          'DROP TABLE complete_sources; CREATE TABLE complete_sources(sentinel TEXT); PRAGMA user_version=1;',
        );
        db.close();
        await expectLater(
          PluginEngine.open(store: store, journalDirectory: root),
          throwsA(isA<SqliteException>()),
        );
        db = sqlite3.open(path);
        expect(db.userVersion, 1);
        expect(
          db.select('SELECT payload FROM commands').single['payload'],
          'old',
        );
        db.execute('PRAGMA user_version=99');
        db.close();
        await expectLater(
          PluginEngine.open(store: store, journalDirectory: root),
          throwsA(isA<PluginEngineException>()),
        );
        db = sqlite3.open(path);
        expect(db.userVersion, 99);
        expect(
          db.select('SELECT payload FROM commands').single['payload'],
          'old',
        );
        db.close();
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'real HTTP engine authorizes complete source, publishes and replays receipt without another GET',
    (_) async {
      final root = await (await getApplicationSupportDirectory()).createTemp(
        'storage-engine-',
      );
      final store = AppStore(sqlite3.open('${root.path}/app.sqlite'));
      var engine = await PluginEngine.open(
        store: store,
        journalDirectory: Directory('${root.path}/execution'),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.generate(256 * 1024 + 9, (i) => i % 251);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      FileLocation? published;
      try {
        final directory = DirectoryLocation(
          platform: DownloadPlatform.macos,
          kind: DirectoryKind.systemDownloads,
          displayName: 'Downloader',
          subdirectory: 'integration-${DateTime.now().microsecondsSinceEpoch}',
        );
        final key = ExecutionKey(
          taskId: 'storage-engine-task',
          engineId: 'storage-engine-id',
          generation: 0,
        );
        final session = (await engine.inspect()).ownerSessionId;
        final now = DateTime.now().toUtc();
        final url = 'http://127.0.0.1:${server.port}/file';
        store.transaction(
          (tx) => tx.saveTask(
            DownloadTask(
              id: key.taskId,
              requestId: 'storage-engine-request',
              engineId: key.engineId,
              generation: 0,
              originalUrl: url,
              displayName: 'data',
              directory: directory,
              status: DownloadStatus.queued,
              downloadedBytes: 0,
              createdAt: now,
              updatedAt: now,
            ),
          ),
        );
        await engine.enqueue(
          EngineCommand(
            commandId: 'storage-enqueue',
            key: key,
            ownerSessionId: session,
            expectedReceiptVersion: 0,
          ),
          EngineTask(
            key: key,
            url: url,
            directory: directory,
            stagingLocation: '${root.path}/data.part',
          ),
        );
        EngineReceipt? complete;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline)) {
          final receipts =
              (await engine.inspect()).receipts
                  .where((r) => r.key == key)
                  .toList()
                ..sort((a, b) => a.receiptVersion.compareTo(b.receiptVersion));
          if (receipts.isNotEmpty &&
              receipts.last.state == DownloadStatus.publishing) {
            complete = receipts.last;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(complete, isNotNull);
        // Preserve a real retired recovery member through the existing execution history.
        final legacy = File('${root.path}/execution/retired.part')
          ..writeAsBytesSync([7, 8, 9]);
        final commands = sqlite3.open('${root.path}/execution/commands.sqlite');
        final pluginTask = plugin.DownloadTask.fromJson(
          jsonDecode(
            commands
                    .select('SELECT plugin_task FROM executions')
                    .single['plugin_task']
                as String,
          ),
        );
        await plugin.FileDownloader().recordExecution(pluginTask, {
          'ownedMaterials': [legacy.path],
        });
        complete = (await engine.inspect()).receipts
            .where((r) => r.key == key)
            .reduce((a, b) => a.receiptVersion > b.receiptVersion ? a : b);
        void commit(EngineReceipt receipt, ReceiptAck ack) {
          final current = store.readTask(key.taskId)!;
          final task = DownloadTask.fromJson({
            ...current.toJson(),
            'status': receipt.state.name,
            'downloadedBytes': receipt.downloadedBytes,
            'totalBytes': receipt.totalBytes,
            'engineReceipt': receipt.toJson(),
            'fileLocation': receipt.publishedLocation?.toJson(),
            'publishOperation': receipt.publishOperation?.toJson(),
          });
          expect(
            store.transaction((tx) => tx.commitReceipt(task, ack)),
            isTrue,
          );
        }

        final ordinary = ReceiptAck(
          key: key,
          receiptVersion: complete.receiptVersion,
        );
        commit(complete, ordinary);
        await engine.acknowledge(ordinary);
        expect(File(complete.stagingLocation!).existsSync(), isTrue);
        expect(legacy.existsSync(), isTrue);
        final operation = PublishOperation(
          operationId: 'engine-publication',
          key: key,
          sourceRef: complete.stagingLocation!,
          sourceLength: complete.downloadedBytes,
          directory: directory,
          temporaryName: '.engine-publication.pending',
          candidateName: '真实下载.bin',
          phase: PublishPhase.prepared,
        );
        var storage = platformFileStorage(journal: engine.publicationJournal);
        final forged = PublishOperation.fromJson({
          ...operation.toJson(),
          'sourceRef': '${root.path}/unrelated',
        });
        await expectLater(
          storage.publish(forged),
          throwsA(isA<FileStorageException>()),
        );
        final other = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        final barrier = CopyBarrierChannel();
        storage = NativeFileStorage(
          journal: engine.publicationJournal,
          channel: barrier,
        );
        final publishing = storage.publish(operation);
        await barrier.entered.future;
        final competing = expectLater(
          other.cancel(
            EngineCommand(
              commandId: 'competing-cancel',
              key: key,
              ownerSessionId: (await other.inspect()).ownerSessionId,
              expectedReceiptVersion: complete.receiptVersion,
            ),
          ),
          throwsA(
            isA<PluginEngineException>().having(
              (e) => e.failure.code,
              'failure',
              FailureCode.stateConflict,
            ),
          ),
        );
        // The second instance must wait for the first instance's publication.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          (await engine.inspect()).receipts
              .where((r) => r.key == key)
              .last
              .state,
          DownloadStatus.publishing,
        );
        barrier.release.complete();
        published = await publishing;
        await competing;
        await other.close();
        expect(File(published.locator).readAsBytesSync(), bytes);
        expect(File(operation.sourceRef).readAsBytesSync(), bytes);
        final receipt = (await engine.inspect()).receipts
            .where((r) => r.key == key)
            .reduce((a, b) => a.receiptVersion > b.receiptVersion ? a : b);
        expect(receipt.state, DownloadStatus.completed);
        expect(receipt.publishOperation!.phase, PublishPhase.published);
        expect(receipt.publishedLocation!.identity, published.identity);
        final release = ReceiptAck(
          key: key,
          receiptVersion: receipt.receiptVersion,
          releaseResumeRefs: [receipt.resumeRef!],
        );
        await expectLater(
          engine.acknowledge(release),
          throwsA(isA<PluginEngineException>()),
        );
        expect(File(operation.sourceRef).existsSync(), isTrue);
        commit(receipt, release);
        await expectLater(
          engine.acknowledge(
            ReceiptAck(
              key: key,
              receiptVersion: receipt.receiptVersion,
              releaseResumeRefs: [operation.sourceRef],
            ),
          ),
          throwsA(isA<PluginEngineException>()),
        );
        await expectLater(
          engine.acknowledge(ordinary),
          throwsA(isA<PluginEngineException>()),
        );
        expect(legacy.existsSync(), isTrue);
        // A late owned member replaced by a directory must reject the entire
        // set before the earlier complete source is deleted or intent is saved.
        legacy.deleteSync();
        final foreignDirectory = Directory(legacy.path)..createSync();
        await expectLater(
          engine.acknowledge(release),
          throwsA(isA<PluginEngineException>()),
        );
        expect(File(operation.sourceRef).readAsBytesSync(), bytes);
        expect(foreignDirectory.existsSync(), isTrue);
        expect(commands.select('SELECT * FROM material_releases'), isEmpty);
        foreignDirectory.deleteSync();
        legacy.writeAsBytesSync([7, 8, 9]);
        final completedBusiness = store.readTask(key.taskId)!;
        final racingRelease = engine.acknowledge(release);
        // This runs after the serialized ack starts, while its idle check yields.
        scheduleMicrotask(
          () => store.transaction(
            (tx) => tx.saveTask(
              DownloadTask.fromJson({
                ...completedBusiness.toJson(),
                'status': 'cancelling',
              }),
            ),
          ),
        );
        await expectLater(racingRelease, throwsA(isA<PluginEngineException>()));
        expect(store.readTask(key.taskId)!.status, DownloadStatus.cancelling);
        expect(File(operation.sourceRef).readAsBytesSync(), bytes);
        expect(legacy.existsSync(), isTrue);
        expect(commands.select('SELECT * FROM material_releases'), isEmpty);
        store.transaction((tx) => tx.saveTask(completedBusiness));
        // Crash equivalent: delete succeeds, per-member done commit fails.
        commands.execute(
          "CREATE TRIGGER fail_release BEFORE UPDATE OF done ON material_releases BEGIN SELECT RAISE(ABORT,'injected'); END",
        );
        await expectLater(
          engine.acknowledge(release),
          throwsA(isA<SqliteException>()),
        );
        expect(File(operation.sourceRef).existsSync(), isFalse);
        expect(legacy.existsSync(), isTrue);
        expect(
          commands.select('SELECT * FROM acknowledgements').single['payload'],
          jsonEncode(ordinary.toJson()),
        );
        commands.execute('DROP TRIGGER fail_release');
        commands.close();
        await engine.close();
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        storage = platformFileStorage(journal: engine.publicationJournal);
        final replay = await storage.publish(receipt.publishOperation!);
        expect(replay.identity, published.identity);
        final releaseDb = sqlite3.open(
          '${root.path}/execution/commands.sqlite',
        );
        releaseDb.execute(
          "CREATE TRIGGER fail_ack BEFORE INSERT ON acknowledgements BEGIN SELECT RAISE(ABORT,'injected ack'); END",
        );
        await expectLater(
          engine.acknowledge(release),
          throwsA(isA<SqliteException>()),
        );
        expect(File(operation.sourceRef).existsSync(), isFalse);
        expect(legacy.existsSync(), isFalse);
        expect(
          releaseDb.select('SELECT * FROM acknowledgements').single['payload'],
          jsonEncode(ordinary.toJson()),
        );
        expect(
          jsonDecode(
            releaseDb
                    .select('SELECT done FROM material_releases')
                    .single['done']
                as String,
          ),
          containsAll([operation.sourceRef, legacy.path]),
        );
        releaseDb.execute('DROP TRIGGER fail_ack');
        releaseDb.close();
        await engine.close();
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        storage = platformFileStorage(journal: engine.publicationJournal);
        await engine.acknowledge(release);
        expect(File(replay.locator).readAsBytesSync(), bytes);
        expect(requests, 1);
        await expectLater(
          cleanupPendingPublication(storage, receipt.publishOperation!),
          throwsA(isA<FileStorageException>()),
        );
        expect(File(replay.locator).readAsBytesSync(), bytes);
        await expectLater(
          storage.deleteOwned(replay),
          throwsA(isA<FileStorageException>()),
        );
        Directory(File(replay.locator).parent.path).deleteSync(recursive: true);
        published = null;
      } finally {
        if (published != null) {
          final file = File(published.locator);
          if (file.existsSync()) file.deleteSync();
          if (file.parent.existsSync()) file.parent.deleteSync(recursive: true);
        }
        await engine.close();
        await server.close(force: true);
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final fault in ['create', 'copy', 'none']) {
    testWidgets(
      'real engine cancel $fault: stop first, preserve source, replay original command after safe cleanup',
      (_) async {
        final root = await (await getApplicationSupportDirectory()).createTemp(
          'storage-cancel-',
        );
        final store = AppStore(sqlite3.open('${root.path}/app.sqlite'));
        final engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/execution'),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = List<int>.generate(65536, (i) => i % 251);
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        Directory? target;
        try {
          final key = ExecutionKey(
            taskId: 'cancel-$fault',
            engineId: 'cancel-$fault',
            generation: 0,
          );
          final directory = DirectoryLocation(
            platform: DownloadPlatform.macos,
            kind: DirectoryKind.systemDownloads,
            displayName: 'Downloader',
            subdirectory: 'cancel-${DateTime.now().microsecondsSinceEpoch}',
          );
          final url = 'http://127.0.0.1:${server.port}/file';
          final now = DateTime.now().toUtc();
          store.transaction(
            (tx) => tx.saveTask(
              DownloadTask(
                id: key.taskId,
                requestId: key.taskId,
                engineId: key.engineId,
                generation: 0,
                originalUrl: url,
                displayName: 'data',
                directory: directory,
                status: DownloadStatus.queued,
                downloadedBytes: 0,
                createdAt: now,
                updatedAt: now,
              ),
            ),
          );
          final session = (await engine.inspect()).ownerSessionId;
          await engine.enqueue(
            EngineCommand(
              commandId: 'enqueue-$fault',
              key: key,
              ownerSessionId: session,
              expectedReceiptVersion: 0,
            ),
            EngineTask(
              key: key,
              url: url,
              directory: directory,
              stagingLocation: '${root.path}/source',
            ),
          );
          Future<EngineReceipt> latest() async => (await engine.inspect())
              .receipts
              .where((r) => r.key == key)
              .reduce((a, b) => a.receiptVersion > b.receiptVersion ? a : b);
          var receipt = await latest();
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (receipt.state != DownloadStatus.publishing &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            receipt = await latest();
          }
          expect(receipt.state, DownloadStatus.publishing);
          final op = PublishOperation(
            operationId: 'publication-$fault',
            key: key,
            sourceRef: receipt.stagingLocation!,
            sourceLength: bytes.length,
            directory: directory,
            temporaryName: '.publication-$fault.pending',
            candidateName: 'cancel.bin',
            phase: PublishPhase.prepared,
          );
          var storage = NativeFileStorage(
            journal: engine.publicationJournal,
            channel: InterruptedChannel(fault),
          );
          if (fault != 'none') {
            await expectLater(
              storage.publish(op),
              throwsA(isA<FileStorageException>()),
            );
            final record = engine.publicationJournal.read(op.operationId)!;
            target = Directory(
              jsonObject(record['parent'])['locator'] as String,
            );
          }
          final command = EngineCommand(
            commandId: 'cancel-command-$fault',
            key: key,
            ownerSessionId: session,
            expectedReceiptVersion: (await latest()).receiptVersion,
          );
          if (fault == 'none') {
            expect(
              (await engine.cancel(command)).state,
              DownloadStatus.cancelling,
            );
          } else {
            final cleanupFailure = isA<PluginEngineException>().having(
              (e) => e.failure.code,
              'failure',
              FailureCode.cleanupFailure,
            );
            await expectLater(engine.cancel(command), throwsA(cleanupFailure));
            await expectLater(engine.cancel(command), throwsA(cleanupFailure));
            expect((await latest()).state, DownloadStatus.cancelling);
            expect(File(op.sourceRef).readAsBytesSync(), bytes);
            if (fault == 'create') {
              await expectLater(
                storage.cleanupPublication(op),
                throwsA(isA<FileStorageException>()),
              );
              expect(File(op.sourceRef).readAsBytesSync(), bytes);
            } else {
              storage = NativeFileStorage(journal: engine.publicationJournal);
              await expectLater(
                storage.cleanupPublication(op),
                throwsA(isA<FileStorageException>()),
              );
              expect(
                engine.publicationJournal.read(op.operationId)!['phase'],
                'cleaning',
              );
              expect(target!.listSync(), hasLength(1));
              await expectLater(
                engine.cancel(command),
                throwsA(cleanupFailure),
              );
            }
          }
          expect(requests, 1);
          expect(File('${root.path}/source').readAsBytesSync(), bytes);
        } finally {
          await engine.close();
          await server.close(force: true);
          store.close();
          if (target != null && target.existsSync()) {
            target.deleteSync(recursive: true);
          }
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}
