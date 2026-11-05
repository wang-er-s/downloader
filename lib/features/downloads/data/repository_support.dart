import 'dart:async';
import '../domain/download_models.dart';

final class RepositoryException implements Exception {
  RepositoryException(this.failure);
  final DownloadFailure failure;
}

Never repositoryFailure(FailureCode code, String reason, {String? taskId}) =>
    throw RepositoryException(
      DownloadFailure(
        code: code,
        message: '操作未完成，请重试或检查任务状态',
        taskId: taskId,
        details: {'reason': reason},
      ),
    );

Stream<T> repositoryWatch<T>(T Function() read, Stream<void> changes) =>
    Stream<T>.multi((sink) {
      void emit() {
        try {
          sink.add(read());
        } catch (error, stack) {
          sink.addError(error, stack);
        }
      }

      final subscription = changes.listen(
        (_) => emit(),
        onError: sink.addError,
      );
      emit();
      sink.onCancel = subscription.cancel;
    });

T repositoryStore<T>(T Function() action) {
  try {
    return action();
  } on RepositoryException {
    rethrow;
  } on DownloadValidationException catch (error) {
    repositoryFailure(error.code, 'validation');
  } catch (_) {
    repositoryFailure(FailureCode.persistenceFailure, 'businessStore');
  }
}
