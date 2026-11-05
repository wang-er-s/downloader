import 'dart:ui' show ImageByteFormat;
import 'package:flutter/rendering.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:downloader/app/app.dart';
import 'package:downloader/app/dependencies.dart';
import 'package:downloader/features/downloads/data/plugin_engine.dart';
import 'package:downloader/features/downloads/data/download_repository.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/downloads/presentation/providers.dart';
import 'package:downloader/features/settings/data/settings_repository.dart';
import 'package:downloader/features/saved_downloads/data/saved_download_repository.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/platform_file_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'UI creates and pauses through real controller repository engine and SQLite',
    (tester) async {
      final root = await (await getApplicationSupportDirectory()).createTemp(
        'download-ui-smoke-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var gets = 0;
      final serving = server.listen((request) async {
        if (request.method == 'GET') gets++;
        request.response.contentLength = 32768 * 1024;
        request.response.headers.set('etag', '"ui-smoke-v1"');
        try {
          for (var i = 0; i < 1024; i++) {
            request.response.add(List<int>.generate(32768, (i) => i % 251));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await request.response.close();
        } on SocketException {
          /* Client paused. */
        } on HttpException {
          /* Client paused. */
        }
      });
      final store = await AppStore.openPersistent(
        databasePath: () async => '${root.path}/business.sqlite',
      );
      final engine = await PluginEngine.open(
        store: store,
        journalDirectory: Directory('${root.path}/engine'),
      );
      final storage = platformFileStorage(journal: engine.publicationJournal);
      final settings = SettingsRepository(
        store: store,
        defaultDirectory: defaultDownloadDirectory(),
      );
      final downloads = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '${root.path}/staging',
      );
      final deps = AppDependencies(
        store: store,
        engine: engine,
        storage: storage,
        downloads: downloads,
        saved: SavedDownloadRepository(store: store, downloads: downloads),
        settings: settings,
      );
      try {
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: ProviderScope(
              overrides: [
                dependenciesProvider.overrideWithValue(deps.presentation),
              ],
              child: const DownloadApplication(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('新建下载'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).first,
          'http://127.0.0.1:${server.port}/slow.bin',
        );
        await tester.tap(find.widgetWithText(FilledButton, '下载'));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (store.readTasks().any((t) => t.downloadedBytes > 0)) break;
        }
        expect(store.readTasks().single.downloadedBytes, greaterThan(0));
        // Close form settles after the actual create acceptance, not a fake state.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byTooltip('暂停'));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (store.readTasks().single.status == DownloadStatus.paused) break;
        }
        final saved = store.readTasks().single;
        expect(saved.status, DownloadStatus.paused);
        expect(saved.engineReceipt!.state, DownloadStatus.paused);
        expect(saved.downloadedBytes, greaterThan(0));
        expect(gets, 1);
        expect(find.text('已暂停'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(store.readTasks().single.downloadedBytes, saved.downloadedBytes);
        debugPrint(
          'DOWNLOAD_UI_REAL_SMOKE GET=$gets bytes=${saved.downloadedBytes} status=${saved.status.name} root=${root.path}',
        );
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ImageByteFormat.png);
        await File(
          '${root.path}/actual-ui.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        debugPrint('DOWNLOAD_UI_SCREENSHOT ${root.path}/actual-ui.png');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await deps.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );
}
