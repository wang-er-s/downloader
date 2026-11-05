import 'dart:async';
import '../../../shared/data/app_store.dart';
import '../../downloads/data/download_repository.dart';
import '../../downloads/data/repository_support.dart';
import '../../downloads/domain/download_models.dart';
import '../domain/saved_download.dart';

final class SavedDownloadRepository {
  SavedDownloadRepository({required this.store, required this.downloads});
  final AppStore store;
  final DownloadRepository downloads;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<List<SavedDownload>> watchSavedDownloads() => repositoryWatch(
    () => repositoryStore(store.readSavedDownloads),
    _changes.stream,
  );
  Future<SavedDownload> save(SavedDownloadInput input) async {
    final saved = repositoryStore(
      () => store.transaction((tx) {
        final old = tx
            .readSavedDownloads()
            .where((item) => item.id == input.id)
            .firstOrNull;
        final now = DateTime.now().toUtc();
        final saved = SavedDownload(
          id: input.id,
          url: input.url,
          fileName: input.fileName,
          directory: input.directory,
          createdAt: old?.createdAt ?? now,
          updatedAt: now,
        );
        tx.saveSavedDownload(saved);
        return saved;
      }),
    );
    _changes.add(null);
    return saved;
  }

  Future<void> delete(String savedDownloadId) async {
    repositoryStore(
      () => store.transaction(
        (tx) => tx.deleteSavedDownload(nonEmpty(savedDownloadId)),
      ),
    );
    _changes.add(null);
  }

  Future<DownloadTask> start(String savedDownloadId, String requestId) async {
    final saved = repositoryStore(
      () => store
          .readSavedDownloads()
          .where((item) => item.id == nonEmpty(savedDownloadId))
          .firstOrNull,
    );
    if (saved == null) repositoryFailure(FailureCode.notFound, 'savedDownload');
    return downloads.create(
      CreateDownload(
        requestId: requestId,
        url: saved.url,
        fileName: saved.fileName,
        directory: saved.directory,
      ),
    );
  }

  Future<void> close() => _changes.close();
}
