import 'dart:async';
import '../../../shared/data/app_store.dart';
import '../../downloads/data/repository_support.dart';
import '../../downloads/domain/download_models.dart';
import '../domain/app_settings.dart';

final class SettingsRepository {
  SettingsRepository({
    required this.store,
    required DirectoryLocation defaultDirectory,
  }) {
    repositoryStore(
      () => store.transaction((tx) {
        if (tx.readSettings() == null) {
          tx.saveSettings(
            AppSettings(
              theme: AppTheme.system,
              defaultDirectory: defaultDirectory,
            ),
          );
        }
      }),
    );
  }
  final AppStore store;
  final _changes = StreamController<void>.broadcast(sync: true);
  AppSettings get current => repositoryStore(() => store.readSettings()!);
  Stream<AppSettings> watchSettings() =>
      repositoryWatch(() => current, _changes.stream);
  Future<void> setTheme(AppTheme theme) async {
    repositoryStore(
      () => store.transaction((tx) {
        final old = tx.readSettings()!;
        tx.saveSettings(
          AppSettings(theme: theme, defaultDirectory: old.defaultDirectory),
        );
      }),
    );
    _changes.add(null);
  }

  Future<void> setDefaultDirectory(DirectoryLocation directory) async {
    repositoryStore(
      () => store.transaction((tx) {
        final old = tx.readSettings()!;
        if (old.defaultDirectory.platform != directory.platform) {
          repositoryFailure(FailureCode.invalidInput, 'directoryPlatform');
        }
        tx.saveSettings(
          AppSettings(theme: old.theme, defaultDirectory: directory),
        );
      }),
    );
    _changes.add(null);
  }

  Future<void> close() => _changes.close();
}
