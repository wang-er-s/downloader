import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart' as plugin;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../shared/data/app_store.dart';
import '../domain/download_models.dart';
import 'download_engine.dart';

/// Execution-only adapter. AppStore remains the sole business facts database.
/// Opening, inspecting, and replaying commands never resubmits a transfer.
final class PluginEngine implements DownloadEngine {
  PluginEngine._(this._root, this._commands, this._store, this._downloader);

  static Future<PluginEngine> open({
    required AppStore store,
    Directory? journalDirectory,
  }) async {
    if (Platform.isAndroid || Platform.isLinux) {
      throw UnsupportedError('PluginEngine supports iOS, macOS and Windows');
    }
    final root =
        journalDirectory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/plugin_engine_v1',
        );
    root.createSync(recursive: true);
    final database = sqlite3.open('${root.path}/commands.sqlite');
    final version = database.select('PRAGMA user_version').single.values.single;
    if (version != 0 && version != 1) {
      database.close();
      throw PluginEngineException(
        DownloadFailure(
          code: FailureCode.protocolMismatch,
          message: '执行日志版本不支持',
        ),
      );
    }
    database.execute('PRAGMA synchronous=FULL');
    database.execute('''
      CREATE TABLE IF NOT EXISTS executions (
        id TEXT PRIMARY KEY, input TEXT NOT NULL, plugin_task TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY, payload TEXT NOT NULL, result TEXT
      );
      CREATE TABLE IF NOT EXISTS acknowledgements (
        id TEXT PRIMARY KEY, payload TEXT NOT NULL
      );
      PRAGMA user_version=1;
    ''');
    final engine = PluginEngine._(
      root,
      database,
      store,
      plugin.FileDownloader(),
    );
    engine._downloader.registerCallbacks(
      group: _group,
      taskStatusCallback: (_) => engine._poll(),
      taskProgressCallback: (_) => engine._poll(),
    );
    await engine._downloader.ready;
    await engine._downloader.start(
      doTrackTasks: false,
      doRescheduleKilledTasks: false,
      markDownloadedComplete: false,
      autoCleanDatabase: false,
    );
    if (!Platform.isIOS) {
      final active = (await engine._downloader.allTasks(
        allGroups: true,
      )).map((t) => t.taskId).toSet();
      for (final row in database.select('SELECT * FROM executions')) {
        final task = plugin.DownloadTask.fromJson(
          jsonDecode(row['plugin_task'] as String),
        );
        final latest = plugin.ExecutionJournal.latest(
          engine._directory(task.taskId),
        );
        if (latest != null &&
            !active.contains(task.taskId) &&
            [0, 1].contains(latest['status'])) {
          await engine._downloader.recordExecution(task, {'detached': true});
        }
      }
    }
    // Historical samples remain inspectable, but are not fresh observations
    // in this process's monotonic clock domain.
    for (final receipt in engine._snapshot().receipts) {
      final id = engine._id(receipt.key);
      engine._delivered[id] = max(
        engine._delivered[id] ?? 0,
        receipt.receiptVersion,
      );
    }
    engine._timer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => engine._poll(),
    );
    return engine;
  }

  static const _group = 'downloader.execution.v1';
  final Directory _root;
  final Database _commands;
  final AppStore _store;
  final plugin.FileDownloader _downloader;
  final String _session =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final _events = StreamController<EngineEvent>.broadcast();
  final _delivered = <String, int>{};
  final _clock = Stopwatch()..start();
  int _sequence = 0;
  Timer? _timer;
  Future<void> _tail = Future.value();

  @override
  Stream<EngineEvent> get events => _events.stream;

  String _id(ExecutionKey key) => base64Url
      .encode(utf8.encode(jsonEncode(key.toJson())))
      .replaceAll('=', '');
  Directory _directory(String id) => Directory('${_root.path}/$id');

  T _decode<T>(String value, T Function(Map<String, Object?>) decode) =>
      decode(Map<String, Object?>.from(jsonDecode(value) as Map));

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Never _conflict(String reason) => throw PluginEngineException(
    DownloadFailure(
      code: FailureCode.stateConflict,
      message: '执行状态已变化，请同步后重试',
      details: {'reason': reason},
    ),
  );

  EngineReceipt _receipt(ExecutionKey key, Map<String, dynamic> raw) {
    if (raw['protocolVersion'] != 1) {
      throw PluginEngineException(
        DownloadFailure(
          code: FailureCode.protocolMismatch,
          message: '执行回执版本不支持',
        ),
      );
    }
    final status = raw['status'] as int? ?? 0;
    final exception = raw['exception'] as Map?;
    final resume = raw['resumeData'] as Map?;
    final state = raw['detached'] == true
        ? DownloadStatus.waitingRecovery
        : switch (status) {
            0 => DownloadStatus.queued,
            1 => DownloadStatus.running,
            2 => DownloadStatus.publishing,
            3 || 4 => DownloadStatus.failed,
            5 => DownloadStatus.cancelling,
            7 => DownloadStatus.paused,
            _ => throw StateError('Unexpected plugin status $status'),
          };
    return EngineReceipt(
      key: key,
      receiptVersion: raw['receiptVersion'] as int,
      state: state,
      downloadedBytes: raw['downloadedBytes'] as int,
      totalBytes: raw['totalBytes'] as int?,
      resumeSupport: resume == null
          ? ResumeSupport.unknown
          : ResumeSupport.supported,
      resumeRef: resume == null
          ? null
          : '${_id(key)}:${raw['materialHash'] ?? plugin.ExecutionJournal.materialToken(resume['data'] as String)}',
      stagingLocation: raw['stagingLocation'] as String?,
      error: exception == null
          ? null
          : DownloadFailure(
              code: exception['type'] == 'TaskResumeException'
                  ? FailureCode.restartRequired
                  : FailureCode.httpFailure,
              message: exception['type'] == 'TaskResumeException'
                  ? '资源或恢复材料变化，需要确认重新下载'
                  : '下载执行失败，已保留恢复材料',
              taskId: key.taskId,
              details: {'pluginType': exception['type']},
            ),
    );
  }

  EngineSnapshot _snapshot() {
    final latestReceipts = <EngineReceipt>[];
    final pending = <EngineReceipt>[];
    for (final row in _commands.select('SELECT * FROM executions')) {
      final input = _decode(row['input'] as String, EngineTask.fromJson);
      final id = row['id'] as String;
      final files = plugin.ExecutionJournal.versions(_directory(id));
      if (files.isEmpty) continue;
      latestReceipts.add(
        _receipt(input.key, jsonDecode(files.last.readAsStringSync())),
      );
      final ackRows = _commands.select(
        'SELECT payload FROM acknowledgements WHERE id=?',
        [id],
      );
      final ack = ackRows.isEmpty
          ? null
          : _decode(ackRows.single['payload'] as String, ReceiptAck.fromJson);
      for (final file in files) {
        final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if ((raw['receiptVersion'] as int) > (ack?.receiptVersion ?? 0)) {
          pending.add(_receipt(input.key, raw));
        }
      }
    }
    for (final latest in latestReceipts) {
      if (!pending.any(
        (r) => r.key == latest.key && r.receiptVersion == latest.receiptVersion,
      )) {
        pending.add(latest);
      }
    }
    return EngineSnapshot(
      ownerSessionId: _session,
      sequence: _sequence,
      receipts: pending,
    );
  }

  void _poll() {
    if (_events.isClosed) return;
    try {
      final latest = <String, EngineReceipt>{};
      for (final receipt in _snapshot().receipts) {
        final id = _id(receipt.key);
        if (receipt.receiptVersion > (latest[id]?.receiptVersion ?? 0)) {
          latest[id] = receipt;
        }
      }
      for (final receipt in latest.values) {
        final id = _id(receipt.key);
        if ((_delivered[id] ?? 0) >= receipt.receiptVersion) continue;
        _delivered[id] = receipt.receiptVersion;
        _events.add(
          EngineEvent(
            ownerSessionId: _session,
            sequence: ++_sequence,
            key: receipt.key,
            downloadedBytes: receipt.downloadedBytes,
            totalBytes: receipt.totalBytes,
            sampleMonotonicMs: _clock.elapsedMilliseconds,
            receipt: receipt,
          ),
        );
      }
    } catch (error, stack) {
      _events.addError(error, stack);
    }
  }

  @override
  Future<EngineSnapshot> inspect() async => _snapshot();

  Future<EngineReceipt?> _command(
    String operation,
    EngineCommand command, {
    EngineTask? input,
  }) => _serial(() async {
    final payload = jsonEncode({
      'operation': operation,
      'command': command.toJson(),
      if (input != null) 'input': input.toJson(),
    });
    final existing = _commands.select('SELECT * FROM commands WHERE id=?', [
      command.commandId,
    ]);
    if (existing.isNotEmpty) {
      if (existing.single['payload'] != payload) _conflict('commandPayload');
      final result = existing.single['result'] as String?;
      if (result == null) _conflict('commandOutcomeUnknown');
      final decoded = jsonDecode(result);
      if (decoded is Map && decoded['failure'] is Map) {
        throw PluginEngineException(
          DownloadFailure.fromJson(
            Map<String, Object?>.from(decoded['failure']),
          ),
        );
      }
      return decoded == null
          ? null
          : EngineReceipt.fromJson(Map<String, Object?>.from(decoded));
    }
    if (command.ownerSessionId != _session) _conflict('staleSession');
    if (input != null && input.key != command.key) _conflict('staleExecution');
    final id = _id(command.key);
    final all = _commands.select('SELECT input FROM executions');
    for (final row in all) {
      final previous = _decode(row['input'] as String, EngineTask.fromJson);
      if (previous.key.engineId == command.key.engineId &&
          previous.key.generation < command.key.generation) {
        final oldId = _id(previous.key);
        final old = plugin.ExecutionJournal.latest(_directory(oldId));
        final acks = _commands.select(
          'SELECT payload FROM acknowledgements WHERE id=?',
          [oldId],
        );
        if (old == null ||
            old['status'] != 5 ||
            acks.isEmpty ||
            _decode(
                  acks.single['payload'] as String,
                  ReceiptAck.fromJson,
                ).receiptVersion !=
                old['receiptVersion']) {
          _conflict('priorExecutionNotReleased');
        }
      }
      if (previous.key.engineId == command.key.engineId &&
          (previous.key.taskId != command.key.taskId ||
              previous.key.generation > command.key.generation)) {
        _conflict('staleExecution');
      }
    }
    final current = plugin.ExecutionJournal.latest(_directory(id));
    if ((current?['receiptVersion'] ?? 0) != command.expectedReceiptVersion) {
      _conflict('staleReceipt');
    }
    plugin.DownloadTask task;
    if (operation == 'enqueue') {
      if (current != null || input == null) _conflict('staleExecution');
      final staging = File(input.stagingLocation);
      if (!staging.isAbsolute || staging.existsSync()) {
        _conflict('stagingOccupied');
      }
      staging.parent.createSync(recursive: true);
      task = plugin.DownloadTask(
        taskId: id,
        url: input.url,
        filename: staging.uri.pathSegments.last,
        directory: staging.parent.path,
        baseDirectory: plugin.BaseDirectory.root,
        group: _group,
        updates: plugin.Updates.statusAndProgress,
        retries: 0,
        allowPause: true,
        metaData: jsonEncode({'executionJournal': _directory(id).path}),
      );
    } else {
      final rows = _commands.select(
        'SELECT plugin_task FROM executions WHERE id=?',
        [id],
      );
      if (rows.isEmpty || current == null) _conflict('staleExecution');
      task = plugin.DownloadTask.fromJson(
        jsonDecode(rows.single['plugin_task'] as String),
      );
    }
    // Execution identity and the unknown command outcome form one durable
    // intent. A crash cannot leave an execution with no command to query.
    _commands.execute('BEGIN IMMEDIATE');
    try {
      if (input != null) {
        _commands.execute('INSERT INTO executions VALUES (?,?,?)', [
          id,
          jsonEncode(input.toJson()),
          jsonEncode(task.toJson()),
        ]);
      }
      _commands.execute('INSERT INTO commands VALUES (?,?,NULL)', [
        command.commandId,
        payload,
      ]);
      _commands.execute('COMMIT');
    } catch (_) {
      try {
        _commands.execute('ROLLBACK');
      } catch (_) {
        // Preserve the first persistence failure.
      }
      rethrow;
    }
    EngineReceipt? result;
    try {
      if (operation == 'enqueue') {
        await _downloader.recordExecution(task, {'status': 0});
        if (!await _downloader.enqueue(task)) _conflict('enqueueRejected');
      } else if (operation == 'resume') {
        if (![4, 7].contains(current!['status']) &&
            current['detached'] != true) {
          _conflict('notResumable');
        }
        if (current['resumeData'] == null) {
          throw PluginEngineException(
            DownloadFailure(
              code: FailureCode.restartRequired,
              message: '缺少可验证的恢复材料，需要确认重新下载',
              taskId: command.key.taskId,
            ),
          );
        }
        await _downloader.waitForExecutionIdle(task);
        await _downloader.restoreExecutionResumeData(
          plugin.ResumeData.fromJson(
            Map<String, dynamic>.from(current['resumeData']),
          ),
        );
        await _downloader.recordExecution(task, {
          'status': 0,
          'detached': false,
          'exception': null,
        });

        if (!await _downloader.resume(task)) _conflict('resumeRejected');
      } else if (operation == 'pause') {
        if (current!['status'] != 7) {
          if (!await _downloader.pause(task)) _conflict('pauseRejected');
          result = await _wait(
            command.key,
            (r) =>
                r.state == DownloadStatus.paused ||
                r.state == DownloadStatus.failed,
          );
          if (result.state == DownloadStatus.failed) {
            throw PluginEngineException(
              result.error ??
                  DownloadFailure(
                    code: FailureCode.fileWriteFailure,
                    message: '暂停未能安全保存，请同步实际状态',
                    taskId: command.key.taskId,
                  ),
            );
          }
        } else {
          result = _receipt(command.key, current);
        }
        await _downloader.waitForExecutionIdle(task);
      } else {
        final active = (await _downloader.allTasks(
          allGroups: true,
        )).any((t) => t.taskId == id);
        if (active && [0, 1].contains(current!['status'])) {
          if (!await _downloader.cancelTasksWithIds([id])) {
            _conflict('cancelRejected');
          }
          result = await _wait(
            command.key,
            (r) => r.state == DownloadStatus.cancelling,
          );
          await _downloader.waitForExecutionIdle(task);
        } else {
          await _downloader.waitForExecutionIdle(task);
          await _downloader.recordExecution(task, {
            'status': 5,
            'detached': false,
          });
          result = _receipt(
            command.key,
            plugin.ExecutionJournal.latest(_directory(id))!,
          );
        }
      }
    } on PluginEngineException catch (error) {
      _commands.execute('UPDATE commands SET result=? WHERE id=?', [
        jsonEncode({'failure': error.failure.toJson()}),
        command.commandId,
      ]);
      rethrow;
    }
    _commands.execute('UPDATE commands SET result=? WHERE id=?', [
      jsonEncode(result?.toJson()),
      command.commandId,
    ]);
    _poll();
    return result;
  });

  Future<EngineReceipt> _wait(
    ExecutionKey key,
    bool Function(EngineReceipt) done,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final raw = plugin.ExecutionJournal.latest(_directory(_id(key)));
      if (raw != null) {
        final receipt = _receipt(key, raw);
        if (done(receipt)) return receipt;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('Execution state was not durably confirmed');
  }

  @override
  Future<void> enqueue(EngineCommand command, EngineTask input) async {
    await _command('enqueue', command, input: input);
  }

  @override
  Future<EngineReceipt> pause(EngineCommand command) async =>
      (await _command('pause', command))!;
  @override
  Future<void> resume(EngineCommand command) async {
    await _command('resume', command);
  }

  @override
  Future<EngineReceipt> cancel(EngineCommand command) async =>
      (await _command('cancel', command))!;

  @override
  Future<void> acknowledge(ReceiptAck ack) => _serial(() async {
    final committed = _store.readAcknowledgements().where(
      (a) => a.key == ack.key,
    );
    if (committed.isEmpty ||
        jsonEncode(committed.single.toJson()) != jsonEncode(ack.toJson())) {
      _conflict('uncommittedAcknowledgement');
    }
    final id = _id(ack.key);
    final raw = plugin.ExecutionJournal.latest(_directory(id));
    if (raw == null || ack.receiptVersion > (raw['receiptVersion'] as int)) {
      _conflict('staleReceipt');
    }
    final business = _store.readTask(ack.key.taskId);
    if (business != null && business.key == ack.key) {
      final receipt = business.engineReceipt;
      if (receipt == null || receipt.receiptVersion < ack.receiptVersion) {
        _conflict('uncommittedReceipt');
      }
      final versionFile = File(
        '${_directory(id).path}/${ack.receiptVersion}.json',
      );
      if (receipt.receiptVersion == ack.receiptVersion &&
          versionFile.existsSync() &&
          jsonEncode(receipt.toJson()) !=
              jsonEncode(
                _receipt(
                  ack.key,
                  jsonDecode(versionFile.readAsStringSync()),
                ).toJson(),
              )) {
        _conflict('receiptPayload');
      }
    }
    final oldRows = _commands.select(
      'SELECT payload FROM acknowledgements WHERE id=?',
      [id],
    );
    if (oldRows.isNotEmpty) {
      final old = _decode(
        oldRows.single['payload'] as String,
        ReceiptAck.fromJson,
      );
      if (old.receiptVersion > ack.receiptVersion) return;
      if (old.receiptVersion == ack.receiptVersion &&
          jsonEncode(old.toJson()) != jsonEncode(ack.toJson())) {
        _conflict('ackPayload');
      }
    }
    if (ack.releaseResumeRefs.isNotEmpty) {
      final latest = _receipt(ack.key, raw);
      if (ack.receiptVersion != latest.receiptVersion ||
          ![
            DownloadStatus.cancelling,
            DownloadStatus.publishing,
          ].contains(latest.state) ||
          ack.releaseResumeRefs.any((ref) => ref != latest.resumeRef)) {
        _conflict('materialStillReferenced');
      }
      if (!Platform.isIOS && raw['resumeData'] is Map) {
        final materials = <String>{
          raw['resumeData']['data'] as String,
          ...List<String>.from(raw['ownedMaterials'] as List? ?? []),
        };
        // Validate the whole owned set before deleting any member.
        for (final path in materials) {
          final material = File(path);
          final owned = _directory(id).resolveSymbolicLinksSync();
          final normalized = material.absolute.uri.normalizePath().toFilePath();
          final lexicalRoot = File(
            _directory(id).absolute.path,
          ).uri.normalizePath().toFilePath();
          final parent = material.parent.resolveSymbolicLinksSync();
          final prefix = '$owned${Platform.pathSeparator}';
          // Check both lexical traversal and real filesystem aliases. The path
          // in a receipt is a locator, not proof that a file belongs to us.
          if (!normalized.startsWith('$lexicalRoot${Platform.pathSeparator}') ||
              (parent != owned && !parent.startsWith(prefix)) ||
              FileSystemEntity.typeSync(material.path, followLinks: false) ==
                  FileSystemEntityType.link ||
              material.existsSync() &&
                  !material.resolveSymbolicLinksSync().startsWith(prefix)) {
            _conflict('materialOwnership');
          }
        }
        for (final path in materials) {
          final material = File(path);
          if (material.existsSync()) material.deleteSync();
        }
      }
    }
    _commands.execute('INSERT OR REPLACE INTO acknowledgements VALUES (?,?)', [
      id,
      jsonEncode(ack.toJson()),
    ]);
    if (!Platform.isIOS) {
      plugin.ExecutionJournal.reclaim(_directory(id), ack.receiptVersion);
    } else {
      // Native callbacks have a different lock owner. Retain immutable history
      // rather than reclaim outside that native serialization boundary.
    }
  });

  /// Application teardown only; a View must never own this adapter's lifetime.
  Future<void> close() async {
    _timer?.cancel();
    await _tail;
    _downloader.unregisterCallbacks(group: _group);
    await _events.close();
    _commands.close();
  }
}

/// Stable application error payload; no plugin or platform exception escapes.
final class PluginEngineException implements Exception {
  const PluginEngineException(this.failure);
  final DownloadFailure failure;
  @override
  String toString() => 'PluginEngineException(${failure.code.name})';
}
