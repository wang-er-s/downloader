import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../saved_downloads/data/saved_download_repository.dart';
import '../../settings/data/settings_repository.dart';
import '../data/download_repository.dart';
import '../domain/download_models.dart';
import '../../saved_downloads/domain/saved_download.dart';
import '../../settings/domain/app_settings.dart';
import '../../../shared/platform/platform_file_storage.dart';

typedef PresentationDependencies = ({
  DownloadRepository downloads,
  SavedDownloadRepository saved,
  SettingsRepository settings,
  FileStorage storage,
});
final dependenciesProvider = Provider<PresentationDependencies>(
  (ref) => throw StateError('应用尚未初始化'),
);
final tasksProvider = StreamProvider<List<DownloadTask>>(
  (ref) => ref.watch(dependenciesProvider).downloads.watchTasks(),
);
final savedProvider = StreamProvider<List<SavedDownload>>(
  (ref) => ref.watch(dependenciesProvider).saved.watchSavedDownloads(),
);
final settingsProvider = StreamProvider<AppSettings>(
  (ref) => ref.watch(dependenciesProvider).settings.watchSettings(),
);
String submissionId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

String errorMessage(Object error) {
  final failure = switch (error) {
    RepositoryException e => e.failure,
    FileStorageException e => e.failure,
    _ => null,
  };
  if (failure == null) return '操作未完成，请检查存储和系统权限后重试。';
  if (failure.details?['reason'] == 'restartUnsupported') {
    return '当前引擎尚不支持从零重新开始，原下载数据已保留。';
  }
  return switch (failure.code) {
    FailureCode.restartRequired => '无法安全续传。原下载数据已保留，当前版本尚不支持从零重启。',
    FailureCode.publicationUncertain => '保存结果待核实。请检查目标目录后重试保存，不会重复创建文件。',
    FailureCode.cleanupFailure => '文件清理未完成，记录已保留。部分平台暂不支持安全删除现存文件，请核实后重试。',
    FailureCode.permissionDenied => '缺少目录或通知权限。请在系统设置中授权，或重新选择目录后重试。',
    FailureCode.installPermissionRequired => '请在系统页面允许下载器安装未知应用，返回后再次点击打开。',
    FailureCode.noHandler => '未找到能打开此文件的应用，请安装相应应用后重试。',
    FailureCode.persistenceFailure => '状态同步或保存失败，请重试。请勿假定操作已完整保存。',
    FailureCode.backgroundRestricted => '系统限制了后台下载，请回到前台并检查系统权限后重试。',
    FailureCode.invalidInput => '链接或文件名无效，请检查后重试。',
    _ => failure.message,
  };
}

class OperationState {
  const OperationState({this.busy = const {}, this.error});
  final Set<String> busy;
  final String? error;
}

final downloadsControllerProvider =
    NotifierProvider<DownloadsController, OperationState>(
      DownloadsController.new,
    );

class DownloadsController extends Notifier<OperationState> {
  @override
  OperationState build() => const OperationState();
  PresentationDependencies get dependencies => ref.read(dependenciesProvider);
  Future<bool> run(
    String id,
    Future<Object?> Function() action, {
    bool duringExit = false,
  }) async {
    if (state.busy.contains(id) ||
        (state.busy.contains('exit') && !duringExit)) {
      return false;
    }
    state = OperationState(busy: {...state.busy, id});
    try {
      await action();
      if (ref.mounted) {
        state = OperationState(
          busy: {...state.busy}..remove(id),
          error: state.error,
        );
      }
      return true;
    } catch (error) {
      if (ref.mounted) {
        state = OperationState(
          busy: {...state.busy}..remove(id),
          error: errorMessage(error),
        );
      }
      return false;
    }
  }

  void clearError() => state = OperationState(busy: state.busy);
  void lockExit(bool value) => state = OperationState(
    busy: value ? {...state.busy, 'exit'} : ({...state.busy}..remove('exit')),
    error: state.error,
  );
  Future<bool> pause(String id) =>
      run(id, () => dependencies.downloads.pause(id), duringExit: true);
  Future<bool> resume(String id) =>
      run(id, () => dependencies.downloads.resume(id));
  Future<bool> cancel(String id) => run(
    'cancel:$id',
    () => dependencies.downloads.cancel(id),
    duringExit: true,
  );
  Future<bool> retryPublication(String id) =>
      run(id, () => dependencies.downloads.retryPublication(id));
  Future<bool> open(String id) =>
      run(id, () => dependencies.downloads.open(id));
  Future<bool> redownload(String id) {
    final request = submissionId();
    return run(id, () => dependencies.downloads.redownload(id, request));
  }

  Future<bool> deleteCompleted(String id, bool file) => run(
    id,
    () => dependencies.downloads.deleteCompleted(id, deleteFile: file),
  );
  Future<bool> clearCompleted(List<String> ids, bool deleteFile) {
    if (state.busy.isNotEmpty) return Future.value(false);
    final downloads = dependencies.downloads;
    return run('clearCompleted', () async {
      for (final id in ids) {
        await downloads.deleteCompleted(id, deleteFile: deleteFile);
      }
      return null;
    });
  }

  Future<bool> create(CreateDownload input) =>
      run('create', () => dependencies.downloads.create(input));
  Future<bool> save(SavedDownloadInput input) =>
      run('save', () => dependencies.saved.save(input));
  Future<bool> startSaved(String id) {
    final request = submissionId();
    return run(id, () => dependencies.saved.start(id, request));
  }

  Future<bool> deleteSaved(String id) =>
      run(id, () => dependencies.saved.delete(id));
  Future<bool> theme(AppTheme theme) =>
      run('settings', () => dependencies.settings.setTheme(theme));
  Future<DirectoryLocation?> pickDirectory() async {
    try {
      return await dependencies.storage.pickDirectory();
    } catch (error) {
      if (ref.mounted) {
        state = OperationState(busy: state.busy, error: errorMessage(error));
      }
      return null;
    }
  }

  Future<bool> chooseDefaultDirectory() => run('settings', () async {
    final selected = await dependencies.storage.pickDirectory();
    if (selected != null) {
      await dependencies.settings.setDefaultDirectory(selected);
    }
    return null;
  });
  Future<bool> synchronize() =>
      run('sync', () => dependencies.downloads.synchronize());
}
