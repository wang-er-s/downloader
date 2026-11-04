import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../shared/data/app_store.dart';
import '../domain/download_models.dart';
import 'download_engine.dart';

/// Application-owned bridge. Inspecting or reconnecting never starts transfers.
final class AndroidEngine implements DownloadEngine {
  AndroidEngine._(this._store) {
    _events.onListen = () {
      _hasListened = true;
      for (final deliver in _initialEvents) {
        deliver();
      }
      _initialEvents.clear();
    };
    _subscription = const EventChannel('downloader/android_engine/events')
        .receiveBroadcastStream(const {'protocolVersion': 1})
        .listen(
          _event,
          onError: (Object error, StackTrace stack) {
            _emit(() => _events.addError(_failure(error), stack));
          },
        );
  }

  static Future<AndroidEngine> open({
    required AppStore store,
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid)) {
      throw AndroidEngineException(
        DownloadFailure(
          code: FailureCode.protocolMismatch,
          message: '此执行引擎仅支持 Android',
        ),
      );
    }
    return AndroidEngine._(store);
  }

  static const _methods = MethodChannel('downloader/android_engine');
  final AppStore _store;
  final _events = StreamController<EngineEvent>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  bool _closed = false;
  String? _eventSession;
  int _eventSequence = -1;
  int _inspection = 0;
  bool _hasListened = false;
  final _initialEvents = <void Function()>[];

  void _emit(void Function() deliver) {
    if (_closed) return;
    if (!_hasListened) {
      _initialEvents.add(deliver);
    } else {
      deliver();
    }
  }

  @override
  Stream<EngineEvent> get events => _events.stream;

  static AndroidEngineException _failure(Object error) {
    if (error is AndroidEngineException) return error;
    var code = FailureCode.protocolMismatch;
    String? reason;
    if (error is PlatformException) {
      code = switch (error.code) {
        'stateConflict' => FailureCode.stateConflict,
        'persistenceFailure' => FailureCode.persistenceFailure,
        'protocolMismatch' => FailureCode.protocolMismatch,
        _ => FailureCode.protocolMismatch,
      };
      final details = error.details;
      final value = details is Map ? details['reason'] : null;
      // Only stable protocol reasons may cross this boundary, never diagnostics.
      if (value is String && _reasons.contains(value)) reason = value;
    }
    return AndroidEngineException(
      DownloadFailure(
        code: code,
        message: code == FailureCode.persistenceFailure
            ? '执行记录读取或保存失败'
            : code == FailureCode.stateConflict
            ? '执行状态已变化，请同步后重试'
            : 'Android 执行协议不可用或载荷无效',
        details: reason == null ? null : {'reason': reason},
      ),
    );
  }

  static const _reasons = {
    'staleSession',
    'staleExecution',
    'staleReceipt',
    'transferUnavailable',
    'materialReleaseUnavailable',
    'commandPayloadChanged',
    'commandOutcomeUnknown',
    'receiptVersionExhausted',
    'invalidPayload',
    'unknownMethod',
  };

  Never _conflict(String reason) => throw AndroidEngineException(
    DownloadFailure(
      code: FailureCode.stateConflict,
      message: '执行状态已变化，请同步后重试',
      details: {'reason': reason},
    ),
  );

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      if (_closed) _conflict('closed');
      return await action();
    } catch (error) {
      throw _failure(error);
    }
  }

  void _event(dynamic raw) {
    if (_closed) return;
    try {
      final event = EngineEvent.fromJson(jsonObject(raw));
      if (_eventSession != null && _eventSession != event.ownerSessionId) {
        _conflict('staleSession');
      }
      if (event.sequence <= _eventSequence) _conflict('eventSequence');
      _eventSession = event.ownerSessionId;
      _eventSequence = event.sequence;
      _emit(() => _events.add(event));
    } catch (error, stack) {
      _emit(() => _events.addError(_failure(error), stack));
    }
  }

  @override
  Future<EngineSnapshot> inspect() => _guard(() async {
    final inspection = ++_inspection;
    final raw = await _methods.invokeMethod<Object?>('inspect', {
      'protocolVersion': 1,
    });
    final snapshot = EngineSnapshot.fromJson(jsonObject(raw));
    if (_closed) _conflict('closed');
    // Only explicit inspection authorizes a session change. A late response
    // from an older inspection must not undo a newer synchronization.
    if (inspection == _inspection) {
      if (_eventSession != snapshot.ownerSessionId) {
        _eventSession = snapshot.ownerSessionId;
        _eventSequence = snapshot.sequence;
      } else if (snapshot.sequence > _eventSequence) {
        _eventSequence = snapshot.sequence;
      }
    }
    return snapshot;
  });

  Map<String, Object?> _key(ExecutionKey key) => {
    'taskId': key.taskId,
    'engineId': key.engineId,
    'generation': key.generation,
  };

  Future<Object?> _command(
    String method,
    EngineCommand command, {
    EngineTask? input,
  }) => _guard(() async {
    if (input != null &&
        (input.key != command.key ||
            input.directory.platform != DownloadPlatform.android)) {
      _conflict('staleExecution');
    }
    return _methods.invokeMethod<Object?>(method, {
      'protocolVersion': 1,
      ..._key(command.key),
      'commandId': command.commandId,
      'ownerSessionId': command.ownerSessionId,
      'expectedReceiptVersion': command.expectedReceiptVersion,
      if (input != null) 'input': input.toJson(),
    });
  });

  Future<EngineReceipt> _stopped(
    String method,
    EngineCommand command,
    DownloadStatus state,
  ) => _guard(() async {
    final receipt = EngineReceipt.fromJson(
      jsonObject(await _command(method, command)),
    );
    if (receipt.key != command.key ||
        receipt.state != state ||
        receipt.receiptVersion < command.expectedReceiptVersion) {
      _conflict('receiptPayload');
    }
    return receipt;
  });

  @override
  Future<void> enqueue(EngineCommand command, EngineTask input) async {
    await _command('enqueue', command, input: input);
  }

  @override
  Future<EngineReceipt> pause(EngineCommand command) =>
      _stopped('pause', command, DownloadStatus.paused);

  @override
  Future<void> resume(EngineCommand command) async {
    await _command('resume', command);
  }

  @override
  Future<EngineReceipt> cancel(EngineCommand command) =>
      _stopped('cancel', command, DownloadStatus.cancelling);

  DownloadTask? _committedBusiness(ReceiptAck ack) {
    try {
      return _store.transaction((tx) {
        final committed = tx.readAcknowledgement(ack.key);
        if (committed == null ||
            jsonEncode(committed.toJson()) != jsonEncode(ack.toJson())) {
          _conflict('uncommittedAcknowledgement');
        }
        return tx.readTask(ack.key.taskId);
      });
    } on AndroidEngineException {
      rethrow;
    } catch (_) {
      throw AndroidEngineException(
        DownloadFailure(
          code: FailureCode.persistenceFailure,
          message: '业务确认记录读取失败',
        ),
      );
    }
  }

  @override
  Future<void> acknowledge(ReceiptAck ack) => _guard(() async {
    // A false commitReceipt result is not proof that this payload was saved.
    final business = _committedBusiness(ack);
    if (business != null && business.key == ack.key) {
      final receipt = business.engineReceipt;
      if (receipt == null || receipt.receiptVersion < ack.receiptVersion) {
        _conflict('uncommittedReceipt');
      }
      if (receipt.receiptVersion == ack.receiptVersion) {
        final snapshot = await inspect();
        // Re-read both rows after yielding: an unchanged ack alone does not
        // prove that a deleted/recreated task still has the verified receipt.
        final current = _committedBusiness(ack);
        if (current != null && current.key == ack.key) {
          final currentReceipt = current.engineReceipt;
          if (currentReceipt == null ||
              currentReceipt.receiptVersion < ack.receiptVersion) {
            _conflict('uncommittedReceipt');
          }
          if (currentReceipt.receiptVersion == ack.receiptVersion) {
            final matches = snapshot.receipts.where(
              (r) => r.key == ack.key && r.receiptVersion == ack.receiptVersion,
            );
            if (matches.isEmpty ||
                matches.any(
                  (r) =>
                      jsonEncode(r.toJson()) !=
                      jsonEncode(currentReceipt.toJson()),
                )) {
              _conflict('receiptPayload');
            }
          }
        }
      }
    }
    if (_closed) _conflict('closed');
    // Never remove business acknowledgement rows or perform local material IO.
    await _methods.invokeMethod<void>('acknowledge', {
      'protocolVersion': 1,
      ..._key(ack.key),
      'receiptVersion': ack.receiptVersion,
      'releaseResumeRefs': ack.releaseResumeRefs,
    });
  });

  /// Releases only Dart listening resources; the native execution is untouched.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _initialEvents.clear();
    try {
      await _subscription.cancel();
    } catch (error) {
      throw _failure(error);
    } finally {
      await _events.close();
    }
  }
}

final class AndroidEngineException implements Exception {
  const AndroidEngineException(this.failure);
  final DownloadFailure failure;
  @override
  String toString() => 'AndroidEngineException(${failure.code.name})';
}
