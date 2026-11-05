import 'dart:io';

import 'package:downloader/features/downloads/data/android_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/downloads/presentation/providers.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/platform_file_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android MediaStore publishes, replays and requests APK install access',
    (tester) async {
      final store = AppStore(sqlite3.openInMemory());
      final engine = await AndroidEngine.open(store: store);
      final storage = AndroidFileStorage();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.generate(65536, (i) => i % 251);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      FileLocation? published;
      try {
        final id = 'publication-${DateTime.now().microsecondsSinceEpoch}';
        final key = ExecutionKey(taskId: id, engineId: id, generation: 0);
        final directory = defaultDownloadDirectory();
        final session = (await engine.inspect()).ownerSessionId;
        await engine.enqueue(
          EngineCommand(
            commandId: 'enqueue-$id',
            key: key,
            ownerSessionId: session,
            expectedReceiptVersion: 0,
          ),
          EngineTask(
            key: key,
            url: 'http://127.0.0.1:${server.port}/file',
            requestedFileName: '$id.apk',
            directory: directory,
            stagingLocation: '/unused-native-owned-staging',
          ),
        );
        EngineReceipt? complete;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline)) {
          final receipts = (await engine.inspect()).receipts.where(
            (r) => r.key == key,
          );
          if (receipts.isNotEmpty) {
            final latest = receipts.reduce(
              (a, b) => a.receiptVersion > b.receiptVersion ? a : b,
            );
            if (latest.state == DownloadStatus.publishing) {
              complete = latest;
              break;
            }
            expect(latest.error, isNull);
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(complete, isNotNull);
        final source = File(complete!.stagingLocation!);
        expect(await source.readAsBytes(), bytes);
        final operation = PublishOperation(
          operationId: id,
          key: key,
          sourceRef: source.path,
          sourceLength: bytes.length,
          directory: directory,
          temporaryName: '.$id.pending',
          candidateName: '$id.apk',
          phase: PublishPhase.prepared,
        );
        for (final change in [
          {'sourceLength': bytes.length + 1},
          {
            'directory': {...directory.toJson(), 'subdirectory': 'different'},
          },
        ]) {
          await expectLater(
            storage.publish(
              PublishOperation.fromJson({...operation.toJson(), ...change}),
            ),
            throwsA(
              isA<FileStorageException>().having(
                (error) => error.failure.code,
                'code',
                FailureCode.stateConflict,
              ),
            ),
          );
        }
        published = await storage.publish(operation);
        expect(
          (await storage.recoverPublication(operation)).disposition,
          PublishDisposition.published,
        );
        expect((await storage.publish(operation)).toJson(), published.toJson());
        expect(await source.readAsBytes(), bytes);
        final receipt = (await engine.inspect()).receipts
            .where((r) => r.key == key && r.state == DownloadStatus.completed)
            .last;
        expect(receipt.publishedLocation!.toJson(), published.toJson());
        expect(requests, 1);
        await expectLater(
          storage.open(published),
          throwsA(
            isA<FileStorageException>()
                .having(
                  (error) => error.failure.code,
                  'code',
                  FailureCode.installPermissionRequired,
                )
                .having(errorMessage, 'message', contains('安装未知应用')),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(await source.readAsBytes(), bytes);
        expect(
          (await storage.recoverPublication(operation)).disposition,
          PublishDisposition.published,
        );
      } finally {
        if (published != null) await storage.deleteOwned(published);
        await server.close(force: true);
        await engine.close();
        store.close();
      }
    },
    skip: !Platform.isAndroid,
  );
}
