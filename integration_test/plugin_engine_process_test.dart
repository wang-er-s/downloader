import 'dart:io';

import 'package:downloader/features/downloads/data/plugin_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Run by integration_test/plugin_engine_process_check.py, which owns the external HTTP
// server and terminates the actual application process between the two phases.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = String.fromEnvironment('ENGINE_PROCESS_URL');
  const path = String.fromEnvironment('ENGINE_PROCESS_ROOT');
  const phase = String.fromEnvironment('ENGINE_PROCESS_PHASE');
  testWidgets('desktop process termination and inspect never auto-enqueue', (
    _,
  ) async {
    if (endpoint.isEmpty || path.isEmpty) return;
    final root = Directory(path)..createSync(recursive: true);
    final store = await AppStore.openPersistent(
      databasePath: () async => '${root.path}/business.sqlite',
    );
    final engine = await PluginEngine.open(
      store: store,
      journalDirectory: Directory('${root.path}/execution'),
    );
    if (phase == 'prepare') {
      final key = ExecutionKey(
        taskId: 'process',
        engineId: 'process',
        generation: 0,
      );
      final directory = DirectoryLocation(
        platform: DownloadPlatform.macos,
        kind: DirectoryKind.systemDownloads,
        displayName: 'Downloads',
      );
      final now = DateTime.now().toUtc();
      store.transaction(
        (tx) => tx.saveTask(
          DownloadTask(
            id: key.taskId,
            requestId: 'process',
            engineId: key.engineId,
            generation: 0,
            originalUrl: endpoint,
            displayName: 'process',
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
          commandId: 'process-enqueue',
          key: key,
          ownerSessionId: (await engine.inspect()).ownerSessionId,
          expectedReceiptVersion: 0,
        ),
        EngineTask(
          key: key,
          url: endpoint,
          directory: directory,
          stagingLocation: '${root.path}/staging/file',
        ),
      );
      for (var i = 0; i < 500; i++) {
        if ((await engine.inspect()).receipts.any(
          (r) => r.downloadedBytes > 0,
        )) {
          File('${root.path}/ready').writeAsStringSync('ready', flush: true);
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Deliberately no teardown: the host kills this actual process.
      await Future<void>.delayed(const Duration(minutes: 2));
      fail('Host did not terminate the transfer process');
    } else {
      final snapshot = await engine.inspect();
      final latest = snapshot.receipts.reduce(
        (a, b) => a.receiptVersion > b.receiptVersion ? a : b,
      );
      expect(latest.state, DownloadStatus.waitingRecovery);
      expect(latest.downloadedBytes, greaterThan(0));
      expect(latest.resumeRef, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        (await engine.inspect()).receipts.last.state,
        DownloadStatus.waitingRecovery,
      );
      final before = (await engine.inspect()).receipts.reduce(
        (a, b) => a.receiptVersion > b.receiptVersion ? a : b,
      );
      File(
        '${root.path}/manual-request',
      ).writeAsStringSync('user continue', flush: true);
      await engine.resume(
        EngineCommand(
          commandId: 'manual-resume',
          key: latest.key,
          ownerSessionId: snapshot.ownerSessionId,
          expectedReceiptVersion: before.receiptVersion,
        ),
      );
      EngineReceipt? complete;
      for (var i = 0; i < 1000; i++) {
        final current = (await engine.inspect()).receipts.reduce(
          (a, b) => a.receiptVersion > b.receiptVersion ? a : b,
        );
        if (current.state == DownloadStatus.failed) {
          fail('Manual resume failed: ${current.error}');
        }
        if (current.state == DownloadStatus.publishing) {
          complete = current;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(complete, isNotNull);
      final file = File(complete!.stagingLocation!);
      expect(file.lengthSync(), 1024 * 1024 * 2);
      final content = file.readAsBytesSync();
      for (var i = 0; i < content.length; i++) {
        if (content[i] != i % 251) fail('Incorrect resumed byte at $i');
      }
      File('${root.path}/verified').writeAsStringSync(
        'waitingRecovery; automatic requests=0; manual safe206 exact content',
        flush: true,
      );
      await engine.close();
      store.close();
    }
  });
}
