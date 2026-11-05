import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../../../shared/data/app_store.dart';
import '../../../shared/platform/platform_file_storage.dart';
import '../domain/download_models.dart';
import 'download_engine.dart';
import 'android_engine.dart';
import 'plugin_engine.dart';
import 'repository_support.dart';

export 'repository_support.dart' show RepositoryException;

/// Application-owned coordinator. Closing a view never closes this repository.
final class DownloadRepository {
  DownloadRepository._(
    this.store,
    this.engine,
    this.storage,
    this.stagingDirectory,
  );
  static Future<DownloadRepository> initialize({
    required AppStore store,
    required DownloadEngine engine,
    required FileStorage storage,
    required String stagingDirectory,
  }) async {
    final result = DownloadRepository._(
      store,
      engine,
      storage,
      stagingDirectory,
    );
    result._subscription = engine.events.listen(
      result._event,
      onError: result._streamError,
    );
    try {
      await result.synchronize();
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    }
  }

  final AppStore store;
  final DownloadEngine engine;
  final FileStorage storage;
  final String stagingDirectory;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _visible = <String, DownloadTask>{};
  final _buffer = <EngineEvent>[];
  final _cancelRequested = <String>{};
  late StreamSubscription<EngineEvent> _subscription;
  Future<void> _tail = Future.value();
  final _operations = <String, Future<void>>{};
  Future<T> _operation<T>(String key, Future<T> Function() action) {
    final next = (_operations[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_operations[key], settled)) _operations.remove(key);
      }),
    );
    return next;
  }

  String? _session;
  int _sequence = 0;
  bool _inspecting = false;
  bool _closed = false;
  String _id() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Stream<List<DownloadTask>> watchTasks() => repositoryWatch(
    () => List.unmodifiable(_visible.values),
    _changes.stream,
  );
  void _emit() {
    if (!_closed) _changes.add(null);
  }

  void _streamError(Object error, [StackTrace? stack]) {
    if (!_closed) _changes.addError(_map(error), stack);
  }

  RepositoryException _map(Object error) {
    if (error is RepositoryException) return error;
    final failure = switch (error) {
      PluginEngineException e => e.failure,
      AndroidEngineException e => e.failure,
      FileStorageException e => e.failure,
      DownloadValidationException e => DownloadFailure(
        code: e.code,
        message: '任务状态或输入无效',
      ),
      _ => DownloadFailure(
        code: FailureCode.persistenceFailure,
        message: '任务同步或保存失败，请重试',
      ),
    };
    return RepositoryException(failure);
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      throw _map(error);
    }
  }

  DownloadTask _task(String id) {
    nonEmpty(id);
    final task = _visible[id];
    if (task == null) {
      repositoryFailure(FailureCode.notFound, 'task', taskId: id);
    }
    return task;
  }

  DownloadTask _copy(DownloadTask task, Map<String, Object?> changes) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return DownloadTask.fromJson({
      ...task.toJson(),
      ...changes,
      'updatedAt': now,
      'completedAt':
          task.completedAt?.millisecondsSinceEpoch ??
          (task.status == DownloadStatus.completed
              ? task.updatedAt.millisecondsSinceEpoch
              : changes['status'] == 'completed'
              ? now
              : null),
    });
  }

  void _save(DownloadTask task) {
    repositoryStore(
      () => store.transaction((tx) {
        final current = tx.readTask(task.id);
        if (current != null &&
            ((current.status == DownloadStatus.cancelling &&
                    task.status != DownloadStatus.cancelling) ||
                (current.status == DownloadStatus.deleting &&
                    task.status != DownloadStatus.deleting))) {
          repositoryFailure(FailureCode.stateConflict, 'intentChanged');
        }
        final receipt = task.engineReceipt;
        if (receipt != null) {
          final committed = tx.readTask(task.id)?.engineReceipt;
          final ack = tx.readAcknowledgement(task.key);
          if (committed == null ||
              jsonEncode(committed.toJson()) != jsonEncode(receipt.toJson()) ||
              ack?.receiptVersion != receipt.receiptVersion) {
            repositoryFailure(
              FailureCode.persistenceFailure,
              'uncommittedReceipt',
              taskId: task.id,
            );
          }
        }
        tx.saveTask(task);
      }),
    );
    _visible[task.id] = task;
    _emit();
  }

  EngineCommand _command(DownloadTask task, String kind) {
    final pending = task.pendingCommand;
    if (pending != null &&
        pending.commandId.startsWith('$kind:') &&
        (task.engineReceipt?.receiptVersion ?? 0) <=
            pending.expectedReceiptVersion) {
      return pending;
    }
    return EngineCommand(
      commandId: '$kind:${_id()}',
      key: task.key,
      ownerSessionId: _session!,
      expectedReceiptVersion: task.engineReceipt?.receiptVersion ?? 0,
    );
  }

  String _displayName(CreateDownload input, String id) =>
      input.fileName ?? downloadFileName(input.url, 'download_$id');

  void _event(EngineEvent event) {
    if (_inspecting || _session == null) {
      _buffer.add(event);
      return;
    }
    unawaited(
      _serial(() async {
        if (event.ownerSessionId != _session ||
            event.sequence > _sequence + 1) {
          await _synchronize();
          return;
        }
        if (event.sequence <= _sequence) return;
        _sequence = event.sequence;
        if (event.receipt != null) {
          await _receipt(event.receipt!, allowPublish: true);
        } else {
          final task = _visible[event.key.taskId];
          if (task != null &&
              task.key == event.key &&
              !_cancelRequested.contains(task.id) &&
              [
                DownloadStatus.queued,
                DownloadStatus.running,
              ].contains(task.status) &&
              event.downloadedBytes >= task.downloadedBytes) {
            _visible[task.id] = _copy(task, {
              'status': 'running',
              'downloadedBytes': event.downloadedBytes,
              'totalBytes': event.totalBytes,
            });
            _emit();
          }
        }
      }).catchError((Object error, StackTrace stack) {
        _streamError(error, stack);
      }),
    );
  }

  Future<void> synchronize() => _serial(() => _guard(_synchronize));
  Future<void> _synchronize() async {
    _inspecting = true;
    try {
      final tasks = repositoryStore(store.readTasks);
      for (final task in tasks) {
        _visible.putIfAbsent(task.id, () => task);
      }
      final snapshot = await engine.inspect();
      _session = snapshot.ownerSessionId;
      _sequence = snapshot.sequence;
      for (final receipt in snapshot.receipts) {
        await _receipt(receipt, allowPublish: false);
      }
      for (final ack in repositoryStore(store.readAcknowledgements)) {
        await _ack(ack);
      }
      for (final task in List<DownloadTask>.of(_visible.values)) {
        if (task.directory.platform != DownloadPlatform.ios &&
            task.pendingCommand?.ownerSessionId != _session &&
            [
              DownloadStatus.queued,
              DownloadStatus.running,
            ].contains(task.status)) {
          _save(_copy(task, {'status': 'waitingRecovery'}));
        }
        if (task.publishOperation != null &&
            task.status == DownloadStatus.publishing) {
          final recovery = await storage.recoverPublication(
            task.publishOperation!,
          );
          if (recovery.disposition == PublishDisposition.uncertain) {
            _save(
              _copy(task, {
                'lastError': DownloadFailure(
                  code: FailureCode.publicationUncertain,
                  message: '发布结果待核实，请保留文件并检查目标目录',
                ).toJson(),
              }),
            );
          }
        }
      }
      _emit();
    } finally {
      _inspecting = false;
      final pending = List<EngineEvent>.of(_buffer);
      _buffer.clear();
      for (final event in pending) {
        _event(event);
      }
    }
  }

  Future<void> _ack(ReceiptAck ack) async {
    try {
      if (ack.releaseResumeRefs.isNotEmpty) {
        final task = store.readTask(ack.key.taskId);
        if (task?.key != ack.key || task?.status != DownloadStatus.completed) {
          repositoryFailure(FailureCode.cleanupFailure, 'releaseIntentChanged');
        }
      }
      await engine.acknowledge(ack);
    } catch (_) {
      repositoryFailure(
        FailureCode.persistenceFailure,
        'acknowledgement',
        taskId: ack.key.taskId,
      );
    }
  }

  Future<void> _receipt(
    EngineReceipt receipt, {
    required bool allowPublish,
  }) async {
    final persisted = store.readTask(receipt.key.taskId);
    if (persisted == null) return;
    final task =
        persisted.status == DownloadStatus.cancelling ||
            persisted.status == DownloadStatus.deleting
        ? persisted
        : _visible[receipt.key.taskId];
    if (task == null || task.key != receipt.key) return;
    final oldVersion = task.engineReceipt?.receiptVersion ?? 0;
    if (receipt.receiptVersion < oldVersion) return;
    if (receipt.receiptVersion == oldVersion) {
      if (jsonEncode(receipt.toJson()) !=
          jsonEncode(task.engineReceipt!.toJson())) {
        repositoryFailure(FailureCode.stateConflict, 'receiptPayload');
      }
      final ack = store.transaction(
        (tx) => tx.readAcknowledgement(receipt.key),
      );
      if (ack != null && ack.receiptVersion == receipt.receiptVersion) {
        await _ack(ack);
        return;
      }
    }
    final cancelling =
        task.status == DownloadStatus.cancelling ||
        _cancelRequested.contains(task.id);
    if (receipt.state == DownloadStatus.completed &&
        (receipt.publishedLocation == null ||
            receipt.publishOperation?.phase != PublishPhase.published)) {
      repositoryFailure(FailureCode.stateConflict, 'incompletePublication');
    }
    final updated = _copy(task, {
      'status': cancelling ? 'cancelling' : receipt.state.name,
      'downloadedBytes': receipt.downloadedBytes,
      'totalBytes': receipt.totalBytes,
      'engineReceipt': receipt.toJson(),
      'stagingRef': receipt.stagingLocation ?? task.stagingRef,
      'publishOperation':
          receipt.publishOperation?.toJson() ?? task.publishOperation?.toJson(),
      'fileLocation':
          receipt.publishedLocation?.toJson() ?? task.fileLocation?.toJson(),
      'targetRef': receipt.publishedLocation?.locator ?? task.targetRef,
      'lastError': receipt.error?.toJson(),
    });
    final ack = ReceiptAck(
      key: receipt.key,
      receiptVersion: receipt.receiptVersion,
      releaseResumeRefs:
          !cancelling &&
              receipt.state == DownloadStatus.completed &&
              receipt.resumeRef != null
          ? [receipt.resumeRef!]
          : [],
    );
    late bool committed;
    try {
      committed = repositoryStore(
        () => store.transaction((tx) => tx.commitReceipt(updated, ack)),
      );
    } catch (_) {
      // Expose the stopped execution even if the atomic business write failed.
      _visible[task.id] = updated;
      _emit();
      rethrow;
    }
    _visible[task.id] = updated;
    _emit();
    final savedAck = committed
        ? ack
        : store.transaction((tx) => tx.readAcknowledgement(receipt.key));
    if (savedAck != null) await _ack(savedAck);
    if (allowPublish &&
        !cancelling &&
        receipt.state == DownloadStatus.publishing &&
        receipt.stagingLocation != null) {
      unawaited(
        _publish(updated).catchError((Object error, StackTrace stack) {
          _streamError(error, stack);
        }),
      );
    }
  }

  Future<void> _publish(DownloadTask task) =>
      _operation('publish:${task.id}', () => _publishWork(task));
  Future<void> _publishWork(DownloadTask task) async {
    final current = store.readTask(task.id);
    if (current?.key != task.key ||
        current?.status != DownloadStatus.publishing) {
      repositoryFailure(FailureCode.stateConflict, 'publicationIntentChanged');
    }
    final operationId = _id();
    final operation =
        task.publishOperation ??
        PublishOperation(
          operationId: operationId,
          key: task.key,
          sourceRef: task.engineReceipt!.stagingLocation!,
          sourceLength: task.downloadedBytes,
          directory: task.directory,
          temporaryName: '.$operationId.part',
          candidateName: task.displayName,
          phase: PublishPhase.prepared,
        );
    _save(_copy(task, {'publishOperation': operation.toJson()}));
    await storage.publish(operation);
    final snapshot = await engine.inspect();
    for (final receipt in snapshot.receipts.where((r) => r.key == task.key)) {
      await _receipt(receipt, allowPublish: false);
    }
  }

  Future<void> retryPublication(String taskId) => _operation(
    taskId,
    () => _guard(() async {
      final task = _task(taskId);
      if (task.status != DownloadStatus.publishing ||
          task.publishOperation == null) {
        repositoryFailure(FailureCode.stateConflict, 'publicationState');
      }
      final recovery = await storage.recoverPublication(task.publishOperation!);
      if (recovery.disposition == PublishDisposition.uncertain) {
        repositoryFailure(
          FailureCode.publicationUncertain,
          'publicationUncertain',
        );
      }
      await _publish(task);
    }),
  );
  Future<DownloadTask> create(CreateDownload input) => _operation(
    'create:${input.requestId}',
    () => _guard(() async {
      final previous = store
          .readTasks()
          .where((task) => task.requestId == input.requestId)
          .firstOrNull;
      if (previous != null) {
        final original = store.transaction(
          (tx) => tx.readCreateInput(input.requestId),
        );
        if (original == null) {
          repositoryFailure(FailureCode.stateConflict, 'createInputUnknown');
        }
        if (jsonEncode(original.toJson()) != jsonEncode(input.toJson())) {
          repositoryFailure(FailureCode.stateConflict, 'createInputConflict');
        }
        return _visible[previous.id] ?? previous;
      }
      final directory =
          input.directory ?? store.readSettings()?.defaultDirectory;
      if (directory == null) {
        repositoryFailure(FailureCode.directoryUnavailable, 'defaultDirectory');
      }
      final id = _id();
      final now = DateTime.now().toUtc();
      final task = DownloadTask(
        id: id,
        requestId: input.requestId,
        engineId: _id(),
        generation: 0,
        originalUrl: input.url,
        requestedFileName: input.fileName,
        displayName: _displayName(input, id),
        directory: directory,
        status: DownloadStatus.queued,
        downloadedBytes: 0,
        createdAt: now,
        updatedAt: now,
        stagingRef: '$stagingDirectory/$id.part',
      );
      final command = _command(task, 'enqueue');
      final saved = _copy(task, {'pendingCommand': command.toJson()});
      repositoryStore(
        () => store.transaction((tx) => tx.createTask(saved, input)),
      );
      _visible[id] = saved;
      final enqueue = _operation(
        id,
        () => engine.enqueue(
          command,
          EngineTask(
            key: task.key,
            url: task.originalUrl,
            requestedFileName: task.requestedFileName,
            directory: directory,
            stagingLocation: task.stagingRef!,
          ),
        ),
      );
      _emit();
      try {
        await enqueue;
      } catch (error) {
        final failure = _map(error);
        final current = store.readTask(id);
        if (current != null && current.status != DownloadStatus.cancelling) {
          _save(
            _copy(current, {
              'status': 'failed',
              'lastError': failure.failure.toJson(),
            }),
          );
        }
        rethrow;
      }
      return _visible[id] ?? store.readTask(id) ?? saved;
    }),
  );
  Future<void> pause(String taskId) => _operation(
    taskId,
    () => _guard(() async {
      final task = _task(taskId);
      if (task.status == DownloadStatus.paused) {
        if (task.engineReceipt != null) {
          await _receipt(task.engineReceipt!, allowPublish: false);
        }
        return;
      }
      if (![
        DownloadStatus.queued,
        DownloadStatus.running,
      ].contains(task.status)) {
        repositoryFailure(FailureCode.stateConflict, 'pauseState');
      }
      final command = _command(task, 'pause');
      _save(_copy(task, {'pendingCommand': command.toJson()}));
      final receipt = await engine.pause(command);
      await _receipt(receipt, allowPublish: false);
      if (receipt.state != DownloadStatus.paused) {
        repositoryFailure(FailureCode.stateConflict, 'pauseNotStopped');
      }
    }),
  );
  Future<void> resume(String taskId, {bool restartFromZero = false}) =>
      _operation(
        taskId,
        () => _guard(() async {
          final task = _task(taskId);
          if (restartFromZero) {
            repositoryFailure(
              FailureCode.restartRequired,
              'restartUnsupported',
            );
          }
          if (![
            DownloadStatus.paused,
            DownloadStatus.failed,
            DownloadStatus.waitingRecovery,
          ].contains(task.status)) {
            repositoryFailure(FailureCode.stateConflict, 'resumeState');
          }
          final command = _command(task, 'resume');
          _save(_copy(task, {'pendingCommand': command.toJson()}));
          await engine.resume(command);
        }),
      );
  Future<void> cancel(String taskId) => _guard(() async {
    // Persist the priority intent before any asynchronous engine/file work,
    // using the committed receipt so saveTask cannot bypass commitReceipt.
    nonEmpty(taskId);
    final task = store.readTask(taskId);
    if (task == null) repositoryFailure(FailureCode.notFound, 'task');
    if ([
      DownloadStatus.completed,
      DownloadStatus.deleting,
    ].contains(task.status)) {
      repositoryFailure(FailureCode.stateConflict, 'cancelState');
    }
    final command =
        task.status == DownloadStatus.cancelling &&
            task.pendingCommand?.commandId.startsWith('cancel:') == true
        ? task.pendingCommand!
        : _command(task, 'cancel');
    _save(
      _copy(task, {'status': 'cancelling', 'pendingCommand': command.toJson()}),
    );
    _cancelRequested.add(taskId);
    await _operation('cancel:$taskId', () async {
      await (_operations['publish:$taskId'] ?? Future<void>.value());
      // The engine owns publication serialization. A completed fact already
      // observed here must never be treated as disposable unfinished work.
      final before = store.readTask(taskId);
      if (before == null) return;
      if (before.engineReceipt?.state == DownloadStatus.completed ||
          before.publishOperation?.phase == PublishPhase.published) {
        repositoryFailure(FailureCode.cleanupFailure, 'alreadyPublished');
      }
      EngineReceipt receipt;
      try {
        receipt = await engine.cancel(command);
      } catch (error) {
        final failure = _map(error).failure;
        if (failure.code == FailureCode.stateConflict &&
            [
              'staleSession',
              'staleReceipt',
            ].contains(failure.details?['reason'])) {
          // These typed rejections precede engine command acceptance. Keep
          // cancelling, but let a later explicit attempt capture a new
          // command after synchronization; never rebind the rejected command.
          final current = store.readTask(taskId);
          if (current != null &&
              current.pendingCommand?.commandId == command.commandId) {
            _save(_copy(current, {'pendingCommand': null}));
          }
        }
        final operation = _task(taskId).publishOperation;
        if (failure.code != FailureCode.cleanupFailure || operation == null) {
          rethrow;
        }
        await cleanupPendingPublication(storage, operation);
        receipt = await engine.cancel(command);
      }
      await _receipt(receipt, allowPublish: false);
      if (receipt.state != DownloadStatus.cancelling || receipt.error != null) {
        repositoryFailure(FailureCode.cleanupFailure, 'cancelIncomplete');
      }
      final current = store.readTask(taskId);
      if (current?.engineReceipt?.state == DownloadStatus.completed ||
          current?.publishOperation?.phase == PublishPhase.published) {
        repositoryFailure(FailureCode.cleanupFailure, 'alreadyPublished');
      }
      repositoryStore(() => store.transaction((tx) => tx.deleteTask(taskId)));
      _visible.remove(taskId);
      _cancelRequested.remove(taskId);
      _emit();
    });
  });

  Future<void> deleteCompleted(
    String taskId, {
    required bool deleteFile,
  }) => _operation(
    taskId,
    () => _guard(() async {
      final task = _task(taskId);
      if (![
        DownloadStatus.completed,
        DownloadStatus.deleting,
      ].contains(task.status)) {
        repositoryFailure(FailureCode.stateConflict, 'deleteState');
      }
      final ack = store.transaction((tx) => tx.readAcknowledgement(task.key));
      if (task.status == DownloadStatus.completed) {
        final ref = task.engineReceipt?.resumeRef;
        if (ack == null ||
            ack.receiptVersion != task.engineReceipt?.receiptVersion ||
            (ref != null &&
                ref.startsWith('complete:') &&
                !ack.releaseResumeRefs.contains(ref))) {
          repositoryFailure(
            FailureCode.persistenceFailure,
            'missingCompletedAck',
          );
        }
        await _ack(ack);
      }
      if (deleteFile) {
        _save(_copy(task, {'status': 'deleting'}));
        try {
          await storage.deleteOwned(task.fileLocation!);
        } catch (error) {
          if (_map(error).failure.code != FailureCode.fileMissing) rethrow;
        }
      }
      repositoryStore(() => store.transaction((tx) => tx.deleteTask(taskId)));
      _visible.remove(taskId);
      _emit();
    }),
  );
  Future<DownloadTask> redownload(String taskId, String requestId) async {
    final task = _task(taskId);
    if (task.status != DownloadStatus.completed) {
      repositoryFailure(FailureCode.stateConflict, 'redownloadState');
    }
    return create(
      CreateDownload(
        requestId: requestId,
        url: task.originalUrl,
        fileName: task.requestedFileName,
        directory: task.directory,
      ),
    );
  }

  Future<void> open(String taskId) => _guard(() async {
    final task = _task(taskId);
    if (task.status != DownloadStatus.completed || task.fileLocation == null) {
      repositoryFailure(FailureCode.stateConflict, 'openState');
    }
    await storage.open(task.fileLocation!);
  });
  Future<void> close() async {
    _closed = true;
    await _subscription.cancel();
    await _tail;
    await Future.wait(List<Future<void>>.of(_operations.values));
    await _changes.close();
  }
}
