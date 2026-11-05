import 'dart:convert';

import 'package:flutter/services.dart';

import '../../features/downloads/data/publication_journal.dart';
import '../../features/downloads/domain/download_models.dart';
import 'file_storage.dart';

/// The native boundary uses handles/file identities and atomic no-replace
/// publication. All decisions and phases are durable in the execution journal.
final class NativeFileStorage implements FileStorage {
  NativeFileStorage({required this.journal, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('downloader/file_storage');

  final PublicationJournal journal;
  final MethodChannel _channel;

  Future<Map<String, Object?>> _call(String method, Map<String, Object?> args) async {
    try {
      return jsonObject(await _channel.invokeMethod<Object?>(method, args));
    } on PlatformException catch (error) {
      final code = FailureCode.values.where((c) => c.name == error.code).firstOrNull ?? FailureCode.fileWriteFailure;
      storageFailure(code);
    }
  }

  @override
  Future<DirectoryLocation?> pickDirectory() async {
    try {
      final result = await _channel.invokeMethod<Object?>('pickDirectory');
      return result == null ? null : DirectoryLocation.fromJson(jsonObject(result));
    } on PlatformException catch (error) {
      storageFailure(FailureCode.values.where((c) => c.name == error.code).firstOrNull ?? FailureCode.directoryUnavailable);
    }
  }

  Map<String, Object?> _args(Map<String, Object?> record) => {
    'directory': record['directory'],
    'parent': record['parent'],
    'temporaryName': record['temporaryName'],
    'candidateName': record['candidateName'],
    'identity': record['identity'],
    'temporaryIdentity': record['temporaryIdentity'],
    'publishAttempt': record['publishAttempt'],
    'source': record['source'],
    'sourceIdentity': record['sourceIdentity'],
    'sourceLength': record['sourceLength'],
  };

  Map<String, Object?>? _read(PublishOperation operation) {
    final record = journal.read(operation.operationId);
    if (record != null) {
      final original = jsonObject(jsonDecode(record['request'] as String));
      final request = operation.toJson();
      for (final field in ['operationId', 'key', 'sourceRef', 'sourceLength', 'directory', 'temporaryName']) {
        if (jsonEncode(original[field]) != jsonEncode(request[field])) storageFailure(FailureCode.stateConflict, '发布操作身份或载荷不匹配');
      }
      if (operation.candidateName != original['candidateName'] && operation.candidateName != record['candidateName']) storageFailure(FailureCode.stateConflict);
    }
    return record;
  }

  void _save(PublishOperation operation, Map<String, Object?> record, String phase) {
    record['phase'] = phase;
    journal.save(operation.operationId, record);
  }

  @override
  Future<FileLocation> publish(PublishOperation operation) => journal.exclusive(() async {
    // Revalidate even an existing operation: cancellation wins over late calls.
    final source = await journal.authorize(operation);
    var record = _read(operation);
    if (record == null) {
      if (operation.phase != PublishPhase.prepared || operation.identity != null || operation.targetRef != null) {
        storageFailure(FailureCode.stateConflict);
      }
      final directory = await _call('resolveDirectory', {'directory': operation.directory.toJson()});
      final sourceInfo = await _call('sourceInfo', {'source': source, 'sourceLength': operation.sourceLength});
      record = {
        'request': jsonEncode(operation.toJson()),
        'directory': operation.directory.toJson(),
        'parent': directory,
        'source': source,
        'sourceIdentity': sourceInfo['identity'],
        'sourceLength': operation.sourceLength,
        'temporaryName': operation.temporaryName,
        'candidateName': operation.candidateName,
        'identity': null,
      };
      _save(operation, record, 'prepared');
    }
    if (['cleaning', 'cleaned'].contains(record['phase'])) storageFailure(FailureCode.stateConflict, '发布已取消，不可再次创建');
    try {
      var recovery = await _recover(record);
      if (recovery.disposition == PublishDisposition.uncertain || recovery.disposition == PublishDisposition.needsPermission) {
        storageFailure(recovery.disposition == PublishDisposition.needsPermission ? FailureCode.permissionDenied : FailureCode.publicationUncertain);
      }
      if (recovery.disposition == PublishDisposition.notCreated) {
        _save(operation, record, 'creating');
        final created = await _call('create', _args(record));
        record['identity'] = created['identity'];
        record['temporaryIdentity'] = created['identity'];
        _save(operation, record, 'copying');
      }
      if (record['phase'] == 'copying') {
        // Copy is repeatable only against the saved target identity. A failed
        // copy never consumes the private complete source.
        await _call('copy', _args(record));
        _save(operation, record, 'finalizing');
      }
      if (record['phase'] == 'finalizing' && recovery.disposition != PublishDisposition.published) {
        var index = (record['index'] as int?) ?? 0;
        while (true) {
          record['publishAttempt'] = true;
          _save(operation, record, 'finalizing');
          final result = await _call('publish', _args(record));
          if (result['conflict'] != true) {
            if (result['identity'] != null) record['identity'] = result['identity'];
            record['keepTemporary'] = result['keepTemporary'] == true;
            _save(operation, record, 'finalizing');
            break;
          }
          record['publishAttempt'] = false;
          index++;
          if (index > 10000) storageFailure(FailureCode.fileWriteFailure);
          final name = jsonObject(jsonDecode(record['request'] as String))['candidateName'] as String;
          final dot = name.lastIndexOf('.');
          record['candidateName'] = dot > 0 ? '${name.substring(0, dot)} ($index)${name.substring(dot)}' : '$name ($index)';
          record['index'] = index;
          _save(operation, record, 'finalizing');
        }
      }
      recovery = await _recover(record);
      if (recovery.disposition != PublishDisposition.published) storageFailure(FailureCode.publicationUncertain);
      final file = recovery.ownedLocation!;
      record['file'] = file.toJson();
      record.remove('error');
      _save(operation, record, 'published');
      if (record['keepTemporary'] != true) await _call('cleanup', _args(record));
      // A crash/failure here leaves the published identity in SQLite. The next
      // explicit publish only reconciles this receipt, never creates a target.
      await journal.published(PublishOperation.fromJson({...operation.toJson(), 'candidateName': record['candidateName'], 'phase': 'published', 'targetRef': file.locator, 'identity': file.identity}), file);
      return file;
    } on FileStorageException catch (error) {
      record['error'] = error.failure.toJson();
      // Preserve the original failure if persisting its diagnostic also fails.
      try { journal.save(operation.operationId, record); } catch (_) {}
      rethrow;
    }
  });

  Future<PublishRecovery> _recover(Map<String, Object?> record) async {
    if (record['phase'] == 'cleaned') return PublishRecovery(disposition: PublishDisposition.notCreated);
    try {
      final result = await _call('recover', {..._args(record), 'phase': record['phase']});
      return PublishRecovery.fromJson(result);
    } on FileStorageException catch (error) {
      if (error.failure.code == FailureCode.publicationUncertain) return PublishRecovery(disposition: PublishDisposition.uncertain);
      if ([FailureCode.permissionDenied, FailureCode.directoryUnavailable].contains(error.failure.code)) {
        return PublishRecovery(disposition: PublishDisposition.needsPermission);
      }
      rethrow;
    }
  }

  @override
  Future<PublishRecovery> recoverPublication(PublishOperation operation) => journal.exclusive(() async {
    final record = _read(operation);
    if (record == null) return PublishRecovery(disposition: PublishDisposition.notCreated);
    return _recover(record);
  });

  /// Repository calls this after its cancel intent and actual engine stop.
  /// A published user file requires a separate explicit delete choice.
  Future<void> cleanupPublication(PublishOperation operation) => journal.exclusive(() async {
    final record = _read(operation);
    if (record == null || record['phase'] == 'cleaned') return;
    final recovery = await _recover(record);
    if (![PublishDisposition.notCreated, PublishDisposition.staged].contains(recovery.disposition)) {
      record['error'] = DownloadFailure(code: FailureCode.cleanupFailure, message: '发布结果未核实或已发布，完整下载已保留').toJson();
      journal.save(operation.operationId, record);
      storageFailure(FailureCode.cleanupFailure);
    }
    try {
      _save(operation, record, 'cleaning');
      if (recovery.disposition == PublishDisposition.staged) await _call('cleanup', _args(record));
      final after = await _recover(record);
      if (after.disposition != PublishDisposition.notCreated) storageFailure(FailureCode.cleanupFailure);
      record.remove('error');
      _save(operation, record, 'cleaned');
    } on FileStorageException catch (error) {
      record['error'] = error.failure.toJson();
      try { journal.save(operation.operationId, record); } catch (_) {}
      rethrow;
    }
  });

  Future<void> _fileAction(String action, FileLocation file) => journal.exclusive(() async {
    final record = journal.findFile(file);
    if (record == null || file.identity == null) storageFailure(FailureCode.cleanupFailure, '无法核实文件归属');
    try {
      await _call(action, {..._args(record), 'file': file.toJson()});
    } on FileStorageException catch (error) {
      record['error'] = error.failure.toJson();
      try { journal.save(jsonObject(jsonDecode(record['request'] as String))['operationId'] as String, record); } catch (_) {}
      rethrow;
    }
  });

  @override
  Future<void> deleteOwned(FileLocation file) => _fileAction('delete', file);
  @override
  Future<void> open(FileLocation file) => _fileAction('open', file);
}
