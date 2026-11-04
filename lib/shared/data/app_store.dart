import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../features/downloads/domain/download_models.dart';
import '../../features/saved_downloads/domain/saved_download.dart';
import '../../features/settings/domain/app_settings.dart';
import '../platform/app_store_location.dart';
import 'app_store_schema.dart';

/// One connection owned by the application. Transactions are synchronous short
/// units: do not perform network, file copying, or platform calls in callbacks.
final class AppStore {
  AppStore(Database database) : _database = database {
    try {
      final version = database
          .select('PRAGMA user_version')
          .single
          .values
          .single;
      if (version == 0) {
        database.execute('BEGIN IMMEDIATE');
        try {
          database.execute(appStoreSchemaV1);
          database.execute('COMMIT');
        } catch (_) {
          try {
            database.execute('ROLLBACK');
          } catch (_) {
            // Preserve the initialization failure if SQLite already rolled back.
          }
          rethrow;
        }
      } else if (version != 1) {
        invalid(FailureCode.protocolMismatch);
      }
      // Fail closed for damaged/incomplete v1 databases. Never recreate tables.
      for (final query in [
        'SELECT ${_taskColumns.join(',')} FROM download_tasks LIMIT 0',
        'SELECT id,url,file_name,directory_json,created_at,updated_at FROM saved_downloads LIMIT 0',
        'SELECT engine_id,generation,task_id,receipt_version,release_refs_json FROM engine_receipt_acks LIMIT 0',
        'SELECT id,theme,default_directory_json FROM app_settings LIMIT 0',
      ]) {
        database.select(query);
      }
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static Future<AppStore> openPersistent({
    Future<String> Function()? databasePath,
  }) async {
    final path = await (databasePath ?? appStorePath)();
    return AppStore(sqlite3.open(path));
  }

  final Database _database;
  bool _inTransaction = false;
  bool _closed = false;

  T transaction<T>(T Function(StoreTransaction store) action) {
    if (_closed || _inTransaction) {
      throw StateError('AppStore is closed or a transaction is already active');
    }
    _database.execute('BEGIN IMMEDIATE');
    _inTransaction = true;
    final store = StoreTransaction._(_database);
    try {
      final result = action(store);
      if (result is Future) {
        throw ArgumentError('AppStore transactions must be synchronous');
      }
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        _database.execute('ROLLBACK');
      } catch (_) {
        // SQLite may already have aborted the transaction.
      }
      rethrow;
    } finally {
      store._active = false;
      _inTransaction = false;
    }
  }

  List<DownloadTask> readTasks() => transaction((store) => store.readTasks());
  DownloadTask? readTask(String id) =>
      transaction((store) => store.readTask(id));
  List<SavedDownload> readSavedDownloads() =>
      transaction((store) => store.readSavedDownloads());
  AppSettings? readSettings() => transaction((store) => store.readSettings());
  List<ReceiptAck> readAcknowledgements() =>
      transaction((store) => store.readAcknowledgements());

  void close() {
    if (_inTransaction) throw StateError('Cannot close during transaction');
    if (!_closed) {
      _database.close();
      _closed = true;
    }
  }
}

/// The handle expires with its callback; it cannot escape a transaction.
final class StoreTransaction {
  StoreTransaction._(this._database);
  final Database _database;
  bool _active = true;
  void _check() {
    if (!_active) throw StateError('Transaction has ended');
  }

  List<DownloadTask> readTasks() {
    _check();
    return List.unmodifiable(
      _database
          .select('SELECT * FROM download_tasks ORDER BY created_at,id')
          .map(_taskFromRow),
    );
  }

  DownloadTask? readTask(String id) {
    _check();
    nonEmpty(id);
    final rows = _database.select('SELECT * FROM download_tasks WHERE id=?', [
      id,
    ]);
    return rows.isEmpty ? null : _taskFromRow(rows.single);
  }

  void saveTask(DownloadTask task) {
    _check();
    final previous = readTask(task.id);
    if (previous != null &&
        (previous.requestId != task.requestId ||
            previous.engineId != task.engineId ||
            previous.originalUrl != task.originalUrl ||
            previous.requestedFileName != task.requestedFileName ||
            jsonEncode(previous.directory.toJson()) !=
                jsonEncode(task.directory.toJson()) ||
            previous.createdAt != task.createdAt ||
            previous.generation > task.generation)) {
      invalid(FailureCode.stateConflict);
    }
    // A retained acknowledgement reserves its execution identity after deletion.
    for (final ack in readAcknowledgements()) {
      if (ack.key.engineId == task.engineId &&
          (ack.key.taskId != task.id || ack.key.generation > task.generation)) {
        invalid(FailureCode.stateConflict);
      }
    }
    final receipt = task.engineReceipt;
    if (previous?.key == task.key &&
        previous?.engineReceipt != null &&
        (receipt == null ||
            receipt.receiptVersion < previous!.engineReceipt!.receiptVersion)) {
      invalid(FailureCode.stateConflict);
    }
    if (receipt != null) {
      final ack = readAcknowledgement(receipt.key);
      if (ack != null && receipt.receiptVersion < ack.receiptVersion) {
        invalid(FailureCode.stateConflict);
      }
    }
    if (previous?.key == task.key &&
        previous?.engineReceipt != null &&
        receipt != null &&
        receipt.receiptVersion == previous!.engineReceipt!.receiptVersion &&
        jsonEncode(receipt.toJson()) !=
            jsonEncode(previous.engineReceipt!.toJson())) {
      invalid(FailureCode.stateConflict);
    }
    final values = _taskValues(task);
    _database.execute('''
      INSERT INTO download_tasks (${_taskColumns.join(',')})
      VALUES (${List.filled(_taskColumns.length, '?').join(',')})
      ON CONFLICT(id) DO UPDATE SET
      ${_taskColumns.skip(1).map((column) => '$column=excluded.$column').join(',')}
    ''', values);
  }

  void deleteTask(String id) {
    _check();
    _database.execute('DELETE FROM download_tasks WHERE id=?', [nonEmpty(id)]);
  }

  /// Atomically aligns business state and confirmation. An older replay is a
  /// no-op, including its release list. Equal-version replays must agree.
  /// Release refs are explicit committed intent, never inferred from terminal
  /// state; adapters must additionally verify ownership before releasing them.
  bool commitReceipt(DownloadTask task, ReceiptAck ack) {
    _check();
    if (task.key != ack.key ||
        task.engineReceipt == null ||
        task.engineReceipt!.receiptVersion != ack.receiptVersion) {
      invalid(FailureCode.stateConflict);
    }
    // Receipts cannot recreate a removed task or import an unknown execution.
    final current = readTask(task.id);
    if (current == null) return false;
    if (current.key != task.key) invalid(FailureCode.stateConflict);
    if (current.engineReceipt?.receiptVersion == ack.receiptVersion &&
        jsonEncode(current.engineReceipt!.toJson()) !=
            jsonEncode(task.engineReceipt!.toJson())) {
      invalid(FailureCode.stateConflict);
    }
    final previous = readAcknowledgement(ack.key);
    if (previous != null && previous.receiptVersion >= ack.receiptVersion) {
      if (previous.receiptVersion == ack.receiptVersion &&
          jsonEncode(previous.toJson()) != jsonEncode(ack.toJson())) {
        invalid(FailureCode.stateConflict);
      }
      return false;
    }
    saveTask(task);
    saveAcknowledgement(ack);
    return true;
  }

  ReceiptAck? readAcknowledgement(ExecutionKey key) {
    _check();
    final rows = _database.select(
      '''SELECT * FROM engine_receipt_acks
      WHERE engine_id=? AND generation=?''',
      [key.engineId, key.generation],
    );
    if (rows.isEmpty) return null;
    final ack = _ackFromRow(rows.single);
    if (ack.key != key) invalid(FailureCode.stateConflict);
    return ack;
  }

  List<ReceiptAck> readAcknowledgements() {
    _check();
    return List.unmodifiable(
      _database
          .select(
            'SELECT * FROM engine_receipt_acks ORDER BY engine_id,generation',
          )
          .map(_ackFromRow),
    );
  }

  /// Also usable in a cancelling/deleting transaction that removes the task.
  /// A lower version cannot overwrite a higher version or its release refs.
  void saveAcknowledgement(ReceiptAck ack) {
    _check();
    final owners = _database.select(
      'SELECT id,generation FROM download_tasks WHERE engine_id=?',
      [ack.key.engineId],
    );
    if (owners.isNotEmpty &&
        (owners.single['id'] != ack.key.taskId ||
            (owners.single['generation'] as int) < ack.key.generation)) {
      invalid(FailureCode.stateConflict);
    }
    final old = readAcknowledgement(ack.key);
    if (old != null && old.receiptVersion >= ack.receiptVersion) {
      if (old.receiptVersion == ack.receiptVersion &&
          jsonEncode(old.toJson()) != jsonEncode(ack.toJson())) {
        invalid(FailureCode.stateConflict);
      }
      return;
    }
    _database.execute(
      '''INSERT INTO engine_receipt_acks
      (engine_id,generation,task_id,receipt_version,release_refs_json)
      VALUES (?,?,?,?,?) ON CONFLICT(engine_id,generation) DO UPDATE SET
      receipt_version=excluded.receipt_version,release_refs_json=excluded.release_refs_json
    ''',
      [
        ack.key.engineId,
        ack.key.generation,
        ack.key.taskId,
        ack.receiptVersion,
        jsonEncode(ack.releaseResumeRefs),
      ],
    );
  }

  List<SavedDownload> readSavedDownloads() {
    _check();
    return List.unmodifiable(
      _database
          .select('SELECT * FROM saved_downloads ORDER BY created_at,id')
          .map(
            (row) => SavedDownload(
              id: row['id'] as String,
              url: row['url'] as String,
              fileName: row['file_name'] as String?,
              directory: _decodeNullable(
                row['directory_json'],
                DirectoryLocation.fromJson,
              ),
              createdAt: _date(row['created_at']),
              updatedAt: _date(row['updated_at']),
            ),
          ),
    );
  }

  void saveSavedDownload(SavedDownload saved) {
    _check();
    final existing = _database.select(
      'SELECT directory_json FROM saved_downloads WHERE id=?',
      [saved.id],
    );
    if (existing.isNotEmpty) {
      _decodeNullable(
        existing.single['directory_json'],
        DirectoryLocation.fromJson,
      );
    }
    _database.execute(
      '''INSERT INTO saved_downloads
      (id,url,file_name,directory_json,created_at,updated_at) VALUES (?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET url=excluded.url,file_name=excluded.file_name,
      directory_json=excluded.directory_json,updated_at=excluded.updated_at
    ''',
      [
        saved.id,
        saved.url,
        saved.fileName,
        _encode(saved.directory?.toJson()),
        saved.createdAt.millisecondsSinceEpoch,
        saved.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  void deleteSavedDownload(String id) {
    _check();
    _database.execute('DELETE FROM saved_downloads WHERE id=?', [nonEmpty(id)]);
  }

  AppSettings? readSettings() {
    _check();
    final rows = _database.select('SELECT * FROM app_settings WHERE id=1');
    if (rows.isEmpty) return null;
    final row = rows.single;
    return AppSettings(
      theme: jsonEnum(AppTheme.values, row['theme']),
      defaultDirectory: _decode(
        row['default_directory_json'],
        DirectoryLocation.fromJson,
      ),
    );
  }

  void saveSettings(AppSettings settings) {
    _check();
    // Validate an existing version before replacing it with a v1 value.
    readSettings();
    _database.execute(
      '''INSERT INTO app_settings
      (id,theme,default_directory_json) VALUES (1,?,?) ON CONFLICT(id)
      DO UPDATE SET theme=excluded.theme,default_directory_json=excluded.default_directory_json
    ''',
      [settings.theme.name, jsonEncode(settings.defaultDirectory.toJson())],
    );
  }
}

const _taskColumns = [
  'id',
  'request_id',
  'engine_id',
  'generation',
  'original_url',
  'effective_url',
  'requested_file_name',
  'display_name',
  'directory_json',
  'status',
  'downloaded_bytes',
  'total_bytes',
  'staging_ref',
  'target_ref',
  'engine_receipt_json',
  'pending_command_json',
  'publish_operation_json',
  'last_error_json',
  'created_at',
  'updated_at',
];
List<Object?> _taskValues(DownloadTask task) => [
  task.id,
  task.requestId,
  task.engineId,
  task.generation,
  task.originalUrl,
  task.effectiveUrl,
  task.requestedFileName,
  task.displayName,
  jsonEncode(task.directory.toJson()),
  task.status.name,
  task.downloadedBytes, task.totalBytes, task.stagingRef,
  // v1 target_ref encodes both the opaque pending reference and owned location.
  // This preserves all FileLocation metadata without adding a fifth table/column.
  task.targetRef == null && task.fileLocation == null
      ? null
      : jsonEncode({
          'version': 1,
          'targetRef': task.targetRef,
          'fileLocation': task.fileLocation?.toJson(),
        }),
  _encode(task.engineReceipt?.toJson()), _encode(task.pendingCommand?.toJson()),
  _encode(task.publishOperation?.toJson()), _encode(task.lastError?.toJson()),
  task.createdAt.millisecondsSinceEpoch, task.updatedAt.millisecondsSinceEpoch,
];
DownloadTask _taskFromRow(Row row) => DownloadTask(
  id: row['id'] as String,
  requestId: row['request_id'] as String,
  engineId: row['engine_id'] as String,
  generation: row['generation'] as int,
  originalUrl: row['original_url'] as String,
  effectiveUrl: row['effective_url'] as String?,
  requestedFileName: row['requested_file_name'] as String?,
  displayName: row['display_name'] as String,
  directory: _decode(row['directory_json'], DirectoryLocation.fromJson),
  status: jsonEnum(DownloadStatus.values, row['status']),
  downloadedBytes: row['downloaded_bytes'] as int,
  totalBytes: row['total_bytes'] as int?,
  stagingRef: row['staging_ref'] as String?,
  targetRef: _target(row)['targetRef'] as String?,
  fileLocation: _decodeTargetLocation(row),
  engineReceipt: _decodeNullable(
    row['engine_receipt_json'],
    EngineReceipt.fromJson,
  ),
  pendingCommand: _decodeNullable(
    row['pending_command_json'],
    EngineCommand.fromJson,
  ),
  publishOperation: _decodeNullable(
    row['publish_operation_json'],
    PublishOperation.fromJson,
  ),
  lastError: _decodeNullable(row['last_error_json'], DownloadFailure.fromJson),
  createdAt: _date(row['created_at']),
  updatedAt: _date(row['updated_at']),
);
Map<String, Object?> _target(Row row) {
  final value = row['target_ref'];
  if (value == null) return const {};
  final json = jsonObject(jsonDecode(value as String));
  jsonVersion(json);
  jsonOptional<String>(json, 'targetRef');
  return json;
}

FileLocation? _decodeTargetLocation(Row row) {
  final value = _target(row)['fileLocation'];
  return value == null ? null : FileLocation.fromJson(jsonObject(value));
}

ReceiptAck _ackFromRow(Row row) => ReceiptAck.fromJson({
  'protocolVersion': 1,
  'key': ExecutionKey(
    taskId: row['task_id'] as String,
    engineId: row['engine_id'] as String,
    generation: row['generation'] as int,
  ).toJson(),
  'receiptVersion': row['receipt_version'],
  'releaseResumeRefs': jsonDecode(row['release_refs_json'] as String),
});
String? _encode(Object? value) => value == null ? null : jsonEncode(value);
T _decode<T>(Object? value, T Function(Map<String, Object?>) decode) =>
    decode(jsonObject(jsonDecode(value as String)));
T? _decodeNullable<T>(Object? value, T Function(Map<String, Object?>) decode) =>
    value == null ? null : _decode(value, decode);
DateTime _date(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
