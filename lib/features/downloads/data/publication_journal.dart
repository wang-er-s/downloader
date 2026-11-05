import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../domain/download_models.dart';

/// Implemented by the execution owner, never by AppStore. The source resolver
/// must validate the current, complete execution before returning a local file.
abstract interface class PublicationJournal {
  Future<T> exclusive<T>(Future<T> Function() action);
  Map<String, Object?>? read(String operationId);
  void save(String operationId, Map<String, Object?> record);
  Future<String> authorize(PublishOperation operation);
  Future<void> published(PublishOperation operation, FileLocation file);
  Map<String, Object?>? findFile(FileLocation file);
}

final class FileStorageException implements Exception {
  FileStorageException(this.failure);
  final DownloadFailure failure;
  @override
  String toString() => 'FileStorageException(${failure.code.name})';
}

Never storageFailure(FailureCode code, [String message = '文件操作未完成，原始下载已保留']) =>
    throw FileStorageException(DownloadFailure(code: code, message: message));

/// A separate SQLite connection owns the gate across asynchronous file work.
/// Busy acquisition is retried asynchronously: blocking SQLite on the same
/// isolate would deadlock the current owner while it waits for platform IO.
/// Never reenter the same gate.
Future<T> sqliteFileGate<T>(String path, Future<T> Function() action) async {
  final gate = sqlite3.open(path);
  gate.execute('PRAGMA busy_timeout=0');
  var acquired = false;
  try {
    while (!acquired) {
      try {
        gate.execute('BEGIN IMMEDIATE');
        acquired = true;
      } on SqliteException catch (error) {
        if (error.resultCode != 5 && error.resultCode != 6) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    return await action();
  } finally {
    try {
      if (acquired) gate.execute('ROLLBACK');
    } finally {
      gate.close();
    }
  }
}

final class SqlitePublicationJournal implements PublicationJournal {
  SqlitePublicationJournal({
    required Directory directory,
    required this.resolveSource,
    required this.commitPublished,
    this.executionExclusive,
  }) {
    directory.createSync(recursive: true);
    _path = '${directory.resolveSymbolicLinksSync()}/publications.sqlite';
    _db = sqlite3.open(_path);
    try {
      _db.execute('PRAGMA busy_timeout=30000');
      _db.execute('PRAGMA synchronous=FULL');
      final version = _db.select('PRAGMA user_version').single.values.single;
      if (version != 0 && version != 1) {
        storageFailure(FailureCode.protocolMismatch, '文件发布日志版本不支持');
      }
      if (version == 0) {
        _db.execute('BEGIN IMMEDIATE');
        try {
          final lockedVersion = _db
              .select('PRAGMA user_version')
              .single
              .values
              .single;
          if (lockedVersion == 0) {
            _db.execute(
              'CREATE TABLE publications (id TEXT PRIMARY KEY NOT NULL, execution TEXT NOT NULL UNIQUE, record TEXT NOT NULL)',
            );
            _db.execute('PRAGMA user_version=1');
          } else if (lockedVersion != 1) {
            storageFailure(FailureCode.protocolMismatch);
          }
          _db.execute('COMMIT');
        } catch (_) {
          _db.execute('ROLLBACK');
          rethrow;
        }
      }
      _db.select('SELECT id, execution, record FROM publications LIMIT 0');
    } catch (_) {
      _db.close();
      rethrow;
    }
  }

  late final String _path;
  late final Database _db;
  final Future<String> Function(PublishOperation) resolveSource;
  final Future<void> Function(PublishOperation, FileLocation) commitPublished;
  final Future<T> Function<T>(Future<T> Function())? executionExclusive;
  static final _queues = <String, Future<void>>{};

  @override
  Future<T> exclusive<T>(Future<T> Function() action) =>
      executionExclusive == null
      ? exclusiveFiles(action)
      : executionExclusive!<T>(() => exclusiveFiles(action));

  /// Used by the execution owner while it already holds its command queue.
  Future<T> exclusiveFiles<T>(Future<T> Function() action) {
    final result = (_queues[_path] ?? Future<void>.value()).then((_) async {
      return sqliteFileGate('$_path.gate.sqlite', action);
    });
    _queues[_path] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Map<String, Object?>? read(String operationId) {
    final rows = _db.select('SELECT record FROM publications WHERE id=?', [
      operationId,
    ]);
    return rows.isEmpty
        ? null
        : jsonObject(jsonDecode(rows.single['record'] as String));
  }

  @override
  void save(String operationId, Map<String, Object?> record) {
    try {
      final execution = jsonEncode(
        jsonObject(jsonDecode(record['request'] as String))['key'],
      );
      final existing = _db.select(
        'SELECT id FROM publications WHERE execution=?',
        [execution],
      );
      if (existing.isNotEmpty && existing.single['id'] != operationId) {
        storageFailure(FailureCode.stateConflict, '该执行已有发布操作');
      }
      _db.execute(
        'INSERT INTO publications(id, execution, record) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET record=excluded.record',
        [operationId, execution, jsonEncode(record)],
      );
    } on SqliteException {
      storageFailure(FailureCode.persistenceFailure, '文件发布日志保存失败');
    }
  }

  @override
  Future<String> authorize(PublishOperation operation) =>
      resolveSource(operation);
  @override
  Future<void> published(PublishOperation operation, FileLocation file) =>
      commitPublished(operation, file);

  @override
  Map<String, Object?>? findFile(FileLocation file) {
    for (final row in _db.select('SELECT record FROM publications')) {
      final record = jsonObject(jsonDecode(row['record'] as String));
      if (record['file'] != null &&
          jsonEncode(record['file']) == jsonEncode(file.toJson())) {
        return record;
      }
    }
    return null;
  }

  /// Call under exclusiveFiles before releasing any private execution material.
  void assertPrivateCleanupAllowed(ExecutionKey key) {
    final rows = _db.select(
      'SELECT record FROM publications WHERE execution=?',
      [jsonEncode(key.toJson())],
    );
    for (final row in rows) {
      final record = jsonObject(jsonDecode(row['record'] as String));
      if (record['phase'] != 'cleaned') {
        storageFailure(FailureCode.cleanupFailure, '发布目标尚未核实或清理，完整下载已保留');
      }
    }
  }

  void close() => _db.close();
}
