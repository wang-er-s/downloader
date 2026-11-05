import '../features/downloads/presentation/providers.dart'
    show PresentationDependencies;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../features/downloads/data/android_engine.dart';
import '../features/downloads/data/download_engine.dart';
import '../features/downloads/data/download_repository.dart';
import '../features/downloads/data/plugin_engine.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/saved_downloads/data/saved_download_repository.dart';
import '../shared/data/app_store.dart';
import '../shared/platform/platform_file_storage.dart';

/// Owned by the application, never disposed when a page stops listening.
class AppDependencies {
  AppDependencies({
    required this.store,
    required this.engine,
    required this.storage,
    required this.downloads,
    required this.saved,
    required this.settings,
  });
  final AppStore store;
  final DownloadEngine engine;
  final FileStorage storage;
  final DownloadRepository downloads;
  final SavedDownloadRepository saved;
  final SettingsRepository settings;
  PresentationDependencies get presentation => (
    downloads: downloads,
    saved: saved,
    settings: settings,
    storage: storage,
  );

  static Future<AppDependencies> open() async {
    final store = await AppStore.openPersistent();
    DownloadEngine? engine;
    SettingsRepository? settings;
    try {
      engine = Platform.isAndroid
          ? await AndroidEngine.open(store: store)
          : await PluginEngine.open(store: store);
      final storage = platformFileStorage(
        journal: engine is PluginEngine ? engine.publicationJournal : null,
      );
      settings = SettingsRepository(
        store: store,
        defaultDirectory: defaultDownloadDirectory(),
      );
      final root = await getApplicationSupportDirectory();
      final staging = Directory('${root.path}/staging_v1');
      await staging.create(recursive: true);
      final downloads = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: staging.path,
      );
      return AppDependencies(
        store: store,
        engine: engine,
        storage: storage,
        downloads: downloads,
        saved: SavedDownloadRepository(store: store, downloads: downloads),
        settings: settings,
      );
    } catch (_) {
      // Cleanup must attempt every owned resource and preserve the open error.
      try {
        await settings?.close();
      } catch (_) {}
      try {
        if (engine is PluginEngine) await engine.close();
        if (engine is AndroidEngine) await engine.close();
      } catch (_) {}
      try {
        store.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> close() async {
    await downloads.close();
    await saved.close();
    await settings.close();
    final current = engine;
    if (current is PluginEngine) await current.close();
    if (current is AndroidEngine) await current.close();
    store.close();
  }
}
