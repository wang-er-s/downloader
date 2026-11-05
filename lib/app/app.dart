import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'dart:ui' show AppExitResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dependencies.dart';
import '../features/downloads/domain/download_models.dart';
import '../features/downloads/presentation/providers.dart';
import '../features/downloads/presentation/downloads_page.dart';
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_page.dart';

class DownloaderApp extends StatefulWidget {
  const DownloaderApp({super.key, this.initialize = AppDependencies.open});
  final Future<AppDependencies> Function() initialize;
  @override
  State<DownloaderApp> createState() => _DownloaderAppState();
}

class _DownloaderAppState extends State<DownloaderApp> {
  late Future<AppDependencies> opening = initialize();
  Future<AppDependencies> initialize() {
    final next = Future<AppDependencies>.sync(widget.initialize);
    // Retry can fail before FutureBuilder's next frame attaches its listener.
    next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppDependencies>(
    future: opening,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return ProviderScope(
          overrides: [
            dependenciesProvider.overrideWithValue(snapshot.data!.presentation),
          ],
          child: const DownloadApplication(),
        );
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: snapshot.hasError
              ? ErrorPanel(
                  message: '应用初始化失败。请检查存储和系统权限，原记录会保留。',
                  retry: () {
                    final next = initialize();
                    setState(() {
                      opening = next;
                    });
                  },
                )
              : const Center(
                  child: CircularProgressIndicator(semanticsLabel: '正在读取下载记录'),
                ),
        ),
      );
    },
  );
}

ThemeData appTheme(Brightness brightness) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff67627e),
    brightness: brightness,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
  ),
  cardTheme: const CardThemeData(elevation: 0),
);

class DownloadApplication extends ConsumerWidget {
  const DownloadApplication({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme =
        ref.watch(settingsProvider).asData?.value.theme ?? AppTheme.system;
    return MaterialApp(
      title: '下载管理器',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: switch (theme) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      },
      home: const AppShell(),
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int page = 0;
  bool exiting = false;
  bool exitApproved = false;
  late final AppLifecycleListener lifecycle;
  static const exitChannel = MethodChannel('downloader/app_lifecycle');
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: requestExit,
      onResume: () {
        ref.read(downloadsControllerProvider.notifier).synchronize();
      },
    );
    exitChannel.setMethodCallHandler((call) async {
      if (call.method != 'requestExit' || !mounted) return false;
      return await requestExit() == AppExitResponse.exit;
    });
  }

  Future<AppExitResponse> requestExit() async {
    if (exitApproved) return AppExitResponse.exit;
    if (exiting || ref.read(downloadsControllerProvider).busy.isNotEmpty) {
      return AppExitResponse.cancel;
    }
    exiting = true;
    final controller = ref.read(downloadsControllerProvider.notifier);
    controller.lockExit(true);
    var approved = false;
    try {
      final tasks = await ref
          .read(dependenciesProvider)
          .downloads
          .watchTasks()
          .first;
      final active = tasks
          .where(
            (t) => [
              DownloadStatus.running,
              DownloadStatus.queued,
              DownloadStatus.publishing,
              DownloadStatus.cancelling,
              DownloadStatus.deleting,
            ].contains(t.status),
          )
          .toList();
      if (active.isNotEmpty) {
        if (!mounted) return AppExitResponse.cancel;
        if (!await confirmAction(
          context,
          '停止下载并退出？',
          '退出后下载将停止。确认后会等待实际暂停和状态保存，失败时保留窗口。',
        )) {
          return AppExitResponse.cancel;
        }
        if (!mounted) return AppExitResponse.cancel;
        for (final task in active) {
          if (![
            DownloadStatus.running,
            DownloadStatus.queued,
          ].contains(task.status)) {
            if (mounted) {
              await confirmAction(context, '暂时无法退出', '仍有文件保存或清理操作，请处理完成后再退出。');
            }
            return AppExitResponse.cancel;
          }
          if (!await ref
              .read(downloadsControllerProvider.notifier)
              .pause(task.id)) {
            return AppExitResponse.cancel;
          }
        }
      }
      final finalTasks = await ref
          .read(dependenciesProvider)
          .downloads
          .watchTasks()
          .first;
      if (!mounted ||
          ref
              .read(downloadsControllerProvider)
              .busy
              .any((id) => id != 'exit') ||
          finalTasks.any(
            (t) => [
              DownloadStatus.running,
              DownloadStatus.queued,
              DownloadStatus.publishing,
              DownloadStatus.cancelling,
              DownloadStatus.deleting,
            ].contains(t.status),
          )) {
        return AppExitResponse.cancel;
      }
      approved = true;
      exitApproved = true;
      return AppExitResponse.exit;
    } catch (_) {
      return AppExitResponse.cancel;
    } finally {
      exiting = false;
      if (mounted && !approved) controller.lockExit(false);
    }
  }

  @override
  void dispose() {
    exitChannel.setMethodCallHandler(null);
    lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(downloadsControllerProvider);
    final body = Column(
      children: [
        if (operation.error != null)
          MaterialBanner(
            content: Text(operation.error!),
            actions: [
              TextButton(
                onPressed: ref
                    .read(downloadsControllerProvider.notifier)
                    .clearError,
                child: const Text('知道了'),
              ),
            ],
          ),
        Expanded(
          child: page == 0 ? const DownloadsPage() : const SettingsPage(),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 800;
        return Scaffold(
          appBar: AppBar(title: Text(page == 0 ? '下载' : '设置')),
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: page,
                        onDestinationSelected: (value) =>
                            setState(() => page = value),
                        labelType: NavigationRailLabelType.all,
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.download_outlined),
                            label: Text('下载'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.settings_outlined),
                            label: Text('设置'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1040),
                            child: body,
                          ),
                        ),
                      ),
                    ],
                  )
                : body,
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: page,
                  onDestinationSelected: (value) =>
                      setState(() => page = value),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.download_outlined),
                      label: '下载',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      label: '设置',
                    ),
                  ],
                ),
        );
      },
    );
  }
}
