import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:downloader/app/app.dart';
import 'package:downloader/app/dependencies.dart';
import 'package:downloader/features/downloads/data/download_engine.dart';
import 'package:downloader/features/downloads/data/download_repository.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/downloads/presentation/providers.dart';
import 'package:downloader/features/downloads/presentation/download_form.dart';
import 'package:downloader/features/downloads/presentation/downloads_page.dart';
import 'package:downloader/features/saved_downloads/data/saved_download_repository.dart';
import 'package:downloader/features/saved_downloads/domain/saved_download.dart';
import 'package:downloader/features/settings/data/settings_repository.dart';
import 'package:downloader/features/settings/domain/app_settings.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/file_storage.dart';

final directory = DirectoryLocation(
  platform: DownloadPlatform.macos,
  kind: DirectoryKind.systemDownloads,
  displayName: 'Downloader',
);
DownloadTask task(String id, DownloadStatus status) => DownloadTask(
  id: id,
  requestId: id,
  engineId: id,
  generation: 0,
  originalUrl: 'https://example.com/$id.bin',
  displayName: '$id.bin',
  directory: directory,
  status: status,
  downloadedBytes: 8192,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

class TestEngine implements DownloadEngine {
  final eventsController = StreamController<EngineEvent>.broadcast();
  EngineTask? input;
  int cancels = 0, enqueues = 0;
  Completer<EngineReceipt>? pauseResult;
  @override
  Stream<EngineEvent> get events => eventsController.stream;
  @override
  Future<EngineSnapshot> inspect() async => EngineSnapshot(
    ownerSessionId: 'session',
    sequence: 0,
    receipts: const [],
  );
  @override
  Future<void> enqueue(EngineCommand command, EngineTask input) async {
    this.input = input;
    enqueues++;
  }

  @override
  Future<EngineReceipt> pause(EngineCommand command) => pauseResult!.future;
  @override
  Future<void> resume(EngineCommand command) async {}
  @override
  Future<EngineReceipt> cancel(EngineCommand command) async {
    cancels++;
    throw StateError('unexpected cancellation');
  }

  @override
  Future<void> acknowledge(ReceiptAck ack) async {}
}

class TestStorage implements FileStorage {
  DirectoryLocation? selection;
  int deletes = 0;
  @override
  Future<DirectoryLocation?> pickDirectory() async => selection;
  @override
  Future<FileLocation> publish(PublishOperation operation) async =>
      throw UnimplementedError();
  @override
  Future<PublishRecovery> recoverPublication(
    PublishOperation operation,
  ) async => throw UnimplementedError();
  @override
  Future<void> deleteOwned(FileLocation file) async {
    deletes++;
  }

  @override
  Future<void> open(FileLocation file) async {}
}

Future<AppDependencies> fixture(TestEngine engine, TestStorage storage) async {
  final store = AppStore(sqlite3.openInMemory());
  final settings = SettingsRepository(
    store: store,
    defaultDirectory: directory,
  );
  final downloads = await DownloadRepository.initialize(
    store: store,
    engine: engine,
    storage: storage,
    stagingDirectory: '/tmp/widget-staging',
  );
  return AppDependencies(
    store: store,
    engine: engine,
    storage: storage,
    downloads: downloads,
    saved: SavedDownloadRepository(store: store, downloads: downloads),
    settings: settings,
  );
}

Future<void> mount(WidgetTester tester, AppDependencies deps) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [dependenciesProvider.overrideWithValue(deps.presentation)],
      child: const DownloadApplication(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late TestEngine engine;
  late TestStorage storage;
  late AppDependencies deps;
  setUp(() async {
    engine = TestEngine();
    storage = TestStorage();
    deps = await fixture(engine, storage);
  });
  tearDown(() async {
    await deps.close();
    await engine.eventsController.close();
  });

  testWidgets(
    'completed rows sort newest first using completion time and legacy fallback',
    (tester) async {
      DownloadTask finished(String id, int day, {int? completionDay}) =>
          DownloadTask.fromJson({
            ...task(id, DownloadStatus.completed).toJson(),
            'updatedAt': DateTime.utc(2026, 11, day).millisecondsSinceEpoch,
            'completedAt': completionDay == null
                ? null
                : DateTime.utc(2026, 11, completionDay).millisecondsSinceEpoch,
          });
      final items = List<DownloadTask>.unmodifiable([
        finished('older', 10, completionDay: 1),
        task('paused-z', DownloadStatus.paused),
        finished('legacy', 3),
        finished('newest', 6, completionDay: 5),
        task('paused-a', DownloadStatus.paused),
      ]);
      for (final category in [1, 0]) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              dependenciesProvider.overrideWithValue(deps.presentation),
              tasksProvider.overrideWith((ref) => Stream.value(items)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: DownloadsPage(
                  category: category,
                  onCategoryChanged: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widgetList<DownloadCard>(find.byType(DownloadCard))
              .map((card) => card.task.id)
              .toList(),
          category == 1
              ? ['newest', 'legacy', 'older']
              : ['paused-z', 'paused-a'],
        );
        expect(tester.takeException(), isNull);
      }
      expect(items.first.id, 'older');
    },
  );

  testWidgets('compact download rows retain details and touch targets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const name = '很长的下载文件名用于检查紧凑列表仍能查看完整内容';
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dependenciesProvider.overrideWithValue(deps.presentation),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: ListView(
                  children: [
                    for (final status in [
                      DownloadStatus.running,
                      DownloadStatus.paused,
                      DownloadStatus.completed,
                    ])
                      DownloadCard(task: task('$name-${status.name}', status)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final element in find.byType(Card).evaluate()) {
        if (scale == 1) {
          expect(
            tester.getSize(find.byWidget(element.widget)).height,
            lessThanOrEqualTo(104),
          );
        }
      }
      expect(
        tester
            .getSize(find.widgetWithIcon(IconButton, Icons.open_in_new))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithIcon(IconButton, Icons.pause)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('$name-running.bin'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('下载详情'), findsOneWidget);
      expect(find.textContaining('$name-running.bin'), findsWidgets);
      expect(find.textContaining('速度未知'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump(const Duration(milliseconds: 400));
    }
  });

  testWidgets('compact cached rows keep full details accessible', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const name = '很长的缓存文件名用于检查紧凑列表.apk';
    const url = 'https://example.com/long/path/download.apk?version=12345';
    await deps.saved.save(
      SavedDownloadInput(
        id: 'compact-cache',
        url: url,
        fileName: name,
        directory: directory,
      ),
    );
    await mount(tester, deps);
    await tester.tap(find.byType(ChoiceChip).at(2));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Card)).height, lessThanOrEqualTo(88));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    expect(find.text('缓存详情'), findsOneWidget);
    expect(find.textContaining('$url\n保存目录：Downloader'), findsOneWidget);
  });

  testWidgets('completed rows show one size and local completion time', (
    tester,
  ) async {
    final finished = DateTime(2026, 11, 5, 8, 9);
    final legacy = DateTime(2026, 11, 4, 7, 6);
    final items = [
      DownloadTask.fromJson({
        ...task('new', DownloadStatus.completed).toJson(),
        'totalBytes': 8192,
        'completedAt': finished.toUtc().millisecondsSinceEpoch,
        'updatedAt': finished
            .add(const Duration(days: 1))
            .toUtc()
            .millisecondsSinceEpoch,
      }),
      DownloadTask.fromJson({
        ...task('legacy', DownloadStatus.completed).toJson(),
        'totalBytes': 8192,
        'updatedAt': legacy.toUtc().millisecondsSinceEpoch,
      }),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dependenciesProvider.overrideWithValue(deps.presentation)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [for (final item in items) DownloadCard(task: item)],
            ),
          ),
        ),
      ),
    );
    expect(find.text('8.0 KB'), findsNWidgets(2));
    expect(find.text('2026-11-05 08:09'), findsOneWidget);
    expect(find.text('2026-11-04 07:06'), findsOneWidget);
    expect(find.textContaining('8.0 KB / 8.0 KB'), findsNothing);
  });

  testWidgets(
    'clear completed action confirms and defaults to keeping local files',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dependenciesProvider.overrideWithValue(deps.presentation),
            tasksProvider.overrideWith(
              (ref) => Stream.value([task('done', DownloadStatus.completed)]),
            ),
          ],
          child: const DownloadApplication(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('清空已下载'), findsNothing);
      await tester.tap(find.byType(ChoiceChip).at(1));
      await tester.pumpAndSettle();
      expect(find.byTooltip('清空已下载'), findsOneWidget);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byTooltip('清空已下载'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          false,
        );
        expect(find.text('同时删除本地已下载文件'), findsOneWidget);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          true,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(storage.deletes, 0);
        expect(find.text('done.bin'), findsOneWidget);
      }
      await tester.tap(find.byType(ChoiceChip).at(2));
      await tester.pumpAndSettle();
      expect(find.byTooltip('清空已下载'), findsNothing);
    },
  );

  testWidgets('category switches keep chip bounds and add position stable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [320.0, 375.0, 430.0, 1024.0]) {
      tester.view.physicalSize = Size(width, 900);
      await mount(tester, deps);
      final chips = find.byType(ChoiceChip);
      final bounds = [for (var i = 0; i < 3; i++) tester.getRect(chips.at(i))];
      final addPosition = tester.getTopLeft(find.byIcon(Icons.add));
      final appBar = tester.getRect(find.byType(AppBar));
      expect(appBar.contains(tester.getCenter(find.byIcon(Icons.add))), isTrue);
      for (final index in [1, 2, 0, 2, 1, 0]) {
        await tester.tap(chips.at(index));
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          for (var i = 0; i < 3; i++) {
            expect(
              tester.getRect(chips.at(i)),
              bounds[i],
              reason: 'width=$width, category=$index, frame=$frame',
            );
          }
          expect(tester.getTopLeft(find.byIcon(Icons.add)), addPosition);
          expect(tester.takeException(), isNull);
        }
        expect(tester.widget<ChoiceChip>(chips.at(index)).selected, isTrue);
        expect(find.byTooltip(index == 2 ? '新增缓存' : '新建下载'), findsOneWidget);
      }
    }
  });

  testWidgets('settings hides the title bar add action', (tester) async {
    await mount(tester, deps);
    expect(find.byTooltip('新建下载'), findsOneWidget);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('下载'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建下载'), findsOneWidget);
  });

  test(
    'cancel bypasses task busy and disposed operations settle safely',
    () async {
      final created = await deps.downloads.create(
        CreateDownload(requestId: 'cancel-busy', url: 'https://example.com'),
      );
      final container = ProviderContainer(
        overrides: [dependenciesProvider.overrideWithValue(deps.presentation)],
      );
      final controller = container.read(downloadsControllerProvider.notifier);
      final pending = Completer<Object?>();
      final operation = controller.run(created.id, () => pending.future);
      expect(await controller.cancel(created.id), false);
      expect(
        engine.cancels,
        1,
        reason: 'cancel reaches repository while task is busy',
      );
      expect(container.read(downloadsControllerProvider).error, isNotNull);
      container.dispose();
      pending.complete(null);
      expect(await operation, true);
    },
  );

  testWidgets(
    'initialization failure is explicit and retries without an empty list',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        DownloaderApp(
          initialize: () async {
            attempts++;
            throw StateError('disk');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('应用初始化失败'), findsOneWidget);
      expect(find.textContaining('暂无'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
    },
  );

  testWidgets('new download validates and cancel creates no task', (
    tester,
  ) async {
    await mount(tester, deps);
    await tester.tap(find.byTooltip('新建下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入有效'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'ftp://bad');
    await tester.tap(find.widgetWithText(FilledButton, '下载'));
    await tester.pumpAndSettle();
    expect(engine.enqueues, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deps.store.readTasks(), isEmpty);
  });

  testWidgets('cache save does not enqueue; editing cancel retains original', (
    tester,
  ) async {
    await mount(tester, deps);
    await tester.tap(find.text('缓存 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增缓存'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://example.com/a',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(engine.enqueues, 0);
    expect(deps.store.readSavedDownloads(), hasLength(1));
    expect(deps.store.readSavedDownloads().single.fileName, isNull);
    expect(find.text('a'), findsOneWidget);
    await tester.tap(find.byTooltip('缓存操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改缓存'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://example.com/changed',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deps.store.readSavedDownloads().single.url, 'https://example.com/a');
  });

  testWidgets(
    'three counts derive from one stream and unknown total retains bytes',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dependenciesProvider.overrideWithValue(deps.presentation),
            tasksProvider.overrideWith(
              (ref) => Stream.value([
                task('active', DownloadStatus.running),
                task('done', DownloadStatus.completed),
              ]),
            ),
            savedProvider.overrideWith(
              (ref) => Stream.value([
                SavedDownload(
                  id: 'cache',
                  url: 'https://example.com',
                  createdAt: DateTime.utc(2026),
                  updatedAt: DateTime.utc(2026),
                ),
              ]),
            ),
          ],
          child: const DownloadApplication(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('下载中 1'), findsOneWidget);
      expect(find.text('已完成 1'), findsOneWidget);
      expect(find.text('缓存 1'), findsOneWidget);
      expect(find.textContaining('8.0 KB / 总大小未知'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, isNull);
      expect(progress.semanticsValue, '百分比未知');
      await tester.tap(find.text('已完成 1'));
      await tester.pumpAndSettle();
      expect(find.text('done.bin'), findsOneWidget);
    },
  );

  testWidgets('stream error is never rendered as empty', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dependenciesProvider.overrideWithValue(deps.presentation),
          tasksProvider.overrideWith(
            (ref) => Stream.error(StateError('read failed')),
          ),
        ],
        child: const DownloadApplication(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('暂无'), findsNothing);
  });

  testWidgets('title bar add icon has contrast in both themes', (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await mount(tester, deps);
      await tester.pumpAndSettle();
      final icon = find.byIcon(Icons.add);
      final foreground = IconTheme.of(tester.element(icon)).color!;
      final background = tester
          .element(icon)
          .findAncestorWidgetOfExactType<Material>()!
          .color!;
      final luminances = [
        foreground.computeLuminance(),
        background.computeLuminance(),
      ]..sort();
      final contrast = (luminances.last + 0.05) / (luminances.first + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5), reason: '$brightness');
    }
  });

  testWidgets(
    'theme persists and cancelled directory selection preserves old value',
    (tester) async {
      await mount(tester, deps);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(deps.store.readSettings()!.theme, AppTheme.dark);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await tester.tap(find.text('选择目录'));
      await tester.pumpAndSettle();
      expect(
        deps.store.readSettings()!.defaultDirectory.toJson(),
        directory.toJson(),
      );
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
    },
  );

  testWidgets('delete file is an explicit opt in, default keeps file', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<bool>(
                context: context,
                builder: (_) => const DeleteDownloadDialog(),
              );
            },
            child: const Text('show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(result, false);
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(result, true);
  });

  testWidgets('narrow large font form avoids keyboard and exposes semantics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dependenciesProvider.overrideWithValue(deps.presentation)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const DownloadForm(saved: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('下载链接')), findsWidgets);
    await tester.ensureVisible(find.text('保存'));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('cancel menu remains usable while pause is waiting', (
    tester,
  ) async {
    await deps.downloads.create(
      CreateDownload(
        requestId: 'menu-cancel',
        url: 'https://example.com/pending',
      ),
    );
    engine.pauseResult = Completer<EngineReceipt>();
    await mount(tester, deps);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    final menu = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    expect(menu.enabled, true);
    final items = menu.itemBuilder(tester.element(find.byType(DownloadCard)));
    expect(
      items.whereType<PopupMenuItem<String>>().map((item) => item.value),
      contains('cancel'),
    );
    engine.pauseResult!.completeError(StateError('pause interrupted'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pause waits, failure remains visible, page disposal does not cancel',
    (tester) async {
      await deps.downloads.create(
        CreateDownload(requestId: 'pause', url: 'https://example.com/pause'),
      );
      engine.pauseResult = Completer<EngineReceipt>();
      await mount(tester, deps);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(find.textContaining('正在处理'), findsOneWidget);
      expect(find.text('已暂停'), findsNothing);
      engine.pauseResult!.completeError(
        RepositoryException(
          DownloadFailure(code: FailureCode.persistenceFailure, message: '未保存'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('状态同步或保存失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(engine.cancels, 0);
      expect(engine.enqueues, 1);
    },
  );

  test(
    'provider disposal never cancels execution; exit lock prevents new enqueue',
    () async {
      final container = ProviderContainer(
        overrides: [dependenciesProvider.overrideWithValue(deps.presentation)],
      );
      final subscription = container.listen(tasksProvider, (_, _) {});
      await container.read(tasksProvider.future);
      subscription.close();
      final controller = container.read(downloadsControllerProvider.notifier);
      controller.lockExit(true);
      expect(
        await controller.create(
          CreateDownload(requestId: 'blocked', url: 'https://example.com'),
        ),
        false,
      );
      expect(engine.enqueues, 0);
      container.dispose();
      expect(engine.cancels, 0);
    },
  );

  testWidgets(
    'native lifecycle channel rejects exit when an operation is pending',
    (tester) async {
      await mount(tester, deps);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppShell)),
      );
      final pending = Completer<Object?>();
      final operation = container
          .read(downloadsControllerProvider.notifier)
          .run('pending', () => pending.future);
      ByteData? reply;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'downloader/app_lifecycle',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('requestExit'),
        ),
        (data) => reply = data,
      );
      await tester.pump();
      expect(const StandardMethodCodec().decodeEnvelope(reply!), false);
      pending.complete(null);
      await operation;
    },
  );
  testWidgets(
    'exit confirmation cancel retains transfer and failure refuses exit',
    (tester) async {
      await deps.downloads.create(
        CreateDownload(requestId: 'exit', url: 'https://example.com/exit'),
      );
      engine.pauseResult = Completer<EngineReceipt>();
      await mount(tester, deps);
      ByteData? reply;
      void request() {
        reply = null;
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'downloader/app_lifecycle',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('requestExit'),
          ),
          (data) => reply = data,
        );
      }

      request();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('停止下载并退出？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(const StandardMethodCodec().decodeEnvelope(reply!), false);
      expect(deps.store.readTasks().single.status, DownloadStatus.queued);
      request();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(reply, isNull, reason: 'exit must await actual pause persistence');
      engine.pauseResult!.completeError(
        RepositoryException(
          DownloadFailure(code: FailureCode.persistenceFailure, message: '失败'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(const StandardMethodCodec().decodeEnvelope(reply!), false);
      expect(find.textContaining('状态同步或保存失败'), findsOneWidget);
    },
  );

  testWidgets(
    'approved exit waits for receipt and locks new transfer submissions',
    (tester) async {
      await deps.downloads.create(
        CreateDownload(requestId: 'exit-ok', url: 'https://example.com/exit'),
      );
      engine.pauseResult = Completer<EngineReceipt>();
      await mount(tester, deps);
      ByteData? reply;
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'downloader/app_lifecycle',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('requestExit'),
        ),
        (data) => reply = data,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(reply, isNull);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppShell)),
      );
      expect(
        await container
            .read(downloadsControllerProvider.notifier)
            .create(
              CreateDownload(requestId: 'racing', url: 'https://example.com'),
            ),
        false,
      );
      engine.pauseResult!.complete(
        EngineReceipt(
          key: engine.input!.key,
          receiptVersion: 1,
          state: DownloadStatus.paused,
          downloadedBytes: 8192,
          resumeSupport: ResumeSupport.supported,
          resumeRef: 'resume',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(const StandardMethodCodec().decodeEnvelope(reply!), true);
      expect(deps.store.readTasks().single.status, DownloadStatus.paused);
      expect(
        container.read(downloadsControllerProvider).busy,
        contains('exit'),
      );
      expect(engine.enqueues, 1);
    },
  );
}
