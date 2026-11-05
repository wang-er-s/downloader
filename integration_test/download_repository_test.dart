import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:downloader/features/downloads/data/download_repository.dart';
import 'package:downloader/features/downloads/data/plugin_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/settings/data/settings_repository.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/platform_file_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'production repository publishes, explicitly releases source and reopens with zero GET',
    (_) async {
      final root = await (await getApplicationSupportDirectory()).createTemp(
        'repository-smoke-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var gets = 0;
      final bytes = List<int>.generate(32768, (i) => i % 251);
      final serving = server.listen((request) async {
        if (request.method == 'GET') gets++;
        final slow = request.uri.path == '/slow.bin';
        request.response.contentLength = slow
            ? bytes.length * 128
            : bytes.length;
        request.response.headers.set('etag', '"repository-smoke"');
        if (slow) {
          try {
            for (var i = 0; i < 128; i++) {
              request.response.add(bytes);
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            await request.response.close();
          } on SocketException {
            /* Expected when the user pauses this transfer. */
          } on HttpException {
            /* Response is closed by the paused client. */
          }
        } else {
          request.response.add(bytes);
          await request.response.close();
        }
      });
      var store = AppStore(sqlite3.open('${root.path}/business.sqlite'));
      var settings = SettingsRepository(
        store: store,
        defaultDirectory: defaultDownloadDirectory(),
      );
      var engine = await PluginEngine.open(
        store: store,
        journalDirectory: Directory('${root.path}/engine'),
      );
      var repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: platformFileStorage(journal: engine.publicationJournal),
        stagingDirectory: '${root.path}/staging',
      );
      try {
        final task = await repository.create(
          CreateDownload(
            requestId: 'smoke',
            url: 'http://127.0.0.1:${server.port}/file.bin',
            fileName: 'repository_${DateTime.now().microsecondsSinceEpoch}.bin',
          ),
        );
        final completed = await repository
            .watchTasks()
            .map(
              (tasks) => tasks
                  .where(
                    (t) =>
                        t.id == task.id && t.status == DownloadStatus.completed,
                  )
                  .firstOrNull,
            )
            .firstWhere((t) => t != null)
            .timeout(const Duration(seconds: 40));
        // The stream exposes actual state before persistence/ack errors, so wait
        // for the coordinator to finish the release transaction as well.
        await repository.synchronize();
        final saved = store.readTask(task.id)!;
        expect(saved.status, DownloadStatus.completed);
        expect(saved.engineReceipt!.publishedLocation, isNotNull);
        expect(saved.publishOperation!.phase, PublishPhase.published);
        expect(store.readAcknowledgements().single.releaseResumeRefs, [
          saved.engineReceipt!.resumeRef,
        ]);
        expect(saved.engineReceipt!.resumeRef, startsWith('complete:'));
        expect(File(task.stagingRef!).existsSync(), isFalse);
        final location = completed!.fileLocation!;
        expect(await File(location.locator).readAsBytes(), bytes);
        expect(gets, 1);
        final unfinished = await repository.create(
          CreateDownload(
            requestId: 'unfinished',
            url: 'http://127.0.0.1:${server.port}/slow.bin',
            fileName: 'unfinished.bin',
          ),
        );
        await repository
            .watchTasks()
            .firstWhere(
              (tasks) => tasks.any(
                (t) => t.id == unfinished.id && t.downloadedBytes > 0,
              ),
            )
            .timeout(const Duration(seconds: 15));
        await repository.pause(unfinished.id);
        expect(store.readTask(unfinished.id)!.status, DownloadStatus.paused);
        expect(gets, 2);
        await repository.close();
        await settings.close();
        await engine.close();
        store.close();
        store = AppStore(sqlite3.open('${root.path}/business.sqlite'));
        settings = SettingsRepository(
          store: store,
          defaultDirectory: defaultDownloadDirectory(),
        );
        engine = await PluginEngine.open(
          store: store,
          journalDirectory: Directory('${root.path}/engine'),
        );
        repository = await DownloadRepository.initialize(
          store: store,
          engine: engine,
          storage: platformFileStorage(journal: engine.publicationJournal),
          stagingDirectory: '${root.path}/staging',
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        await repository.synchronize();
        expect(
          gets,
          2,
          reason:
              'reopening completed and unfinished tasks must produce zero additional HTTP GET',
        );
        expect(store.readTask(unfinished.id)!.status, DownloadStatus.paused);
        expect(await File(location.locator).readAsBytes(), bytes);
        // Test-owned final file only; production deleteOwned limitations remain.
        await File(location.locator).delete();
      } finally {
        await repository.close();
        await settings.close();
        await engine.close();
        store.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );
}
