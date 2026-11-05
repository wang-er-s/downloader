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
import 'publication_journal.dart';

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
    PluginEngine? openingEngine;
    try {
      final version = database
          .select('PRAGMA user_version')
          .single
          .values
          .single;
      if (version != 0 && version != 1 && version != 2) {
        throw PluginEngineException(
          DownloadFailure(
            code: FailureCode.protocolMismatch,
            message: '执行日志版本不支持',
          ),
        );
      }
      database.execute('PRAGMA synchronous=FULL');
      database.execute('BEGIN IMMEDIATE');
      try {
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
      CREATE TABLE IF NOT EXISTS complete_sources (
        id TEXT PRIMARY KEY, ref TEXT NOT NULL UNIQUE, members TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS material_releases (
        id TEXT PRIMARY KEY, ack TEXT NOT NULL, done TEXT NOT NULL
      );
      PRAGMA user_version=2;
    ''');
        database.select('SELECT id,ref,members FROM complete_sources LIMIT 0');
        database.select('SELECT id,ack,done FROM material_releases LIMIT 0');
        database.execute('COMMIT');
      } catch (_) {
        try {
          database.execute('ROLLBACK');
        } catch (_) {
          // Rollback cleanup must not replace the original initialization error.
        }
        rethrow;
      }
      final engine = PluginEngine._(
        root,
        database,
        store,
        plugin.FileDownloader(),
      );
      openingEngine = engine;
      if (_callbackOwner != null) engine._conflict('engineAlreadyOpen');
      _callbackOwner = engine;
      engine._downloader.registerCallbacks(
        group: _group,
        taskStatusCallback: engine._statusCallback,
        taskProgressCallback: engine._progressCallback,
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
    } catch (_) {
      try {
        if (openingEngine != null) {
          await openingEngine.close();
        } else {
          database.close();
        }
      } catch (_) {
        // Preserve the initialization failure even when teardown also fails.
      }
      rethrow;
    }
  }

  static const _group = 'downloader.execution.v1';
  static PluginEngine? _callbackOwner;
  void _statusCallback(plugin.TaskStatusUpdate _) => _poll();
  void _progressCallback(plugin.TaskProgressUpdate _) => _poll();
  Future<void>? _closing;
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
  static final _executionQueues = <String, Future<void>>{};
  late final String _queueKey = _root.resolveSymbolicLinksSync();
  Future<void> get _tail => _executionQueues[_queueKey] ?? Future<void>.value();

  @override
  Stream<EngineEvent> get events => _events.stream;

  String _id(ExecutionKey key) => base64Url
      .encode(utf8.encode(jsonEncode(key.toJson())))
      .replaceAll('=', '');
  Directory _directory(String id) => Directory('${_root.path}/$id');

  T _decode<T>(String value, T Function(Map<String, Object?>) decode) =>
      decode(Map<String, Object?>.from(jsonDecode(value) as Map));

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      return sqliteFileGate('$_queueKey/execution.gate.sqlite', action);
    });
    _executionQueues[_queueKey] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
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
            2 =>
              raw['publishedLocation'] == null
                  ? DownloadStatus.publishing
                  : DownloadStatus.completed,
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
      resumeRef:
          raw['completeSourceRef'] as String? ??
          (resume == null
              ? null
              : '${_id(key)}:${raw['materialHash'] ?? plugin.ExecutionJournal.materialToken(resume['data'] as String)}'),
      stagingLocation: raw['stagingLocation'] as String?,
      publishOperation: raw['publishOperation'] == null
          ? null
          : PublishOperation.fromJson(jsonObject(raw['publishOperation'])),
      publishedLocation: raw['publishedLocation'] == null
          ? null
          : FileLocation.fromJson(jsonObject(raw['publishedLocation'])),
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

  /// FileStorage's sole authority is this execution owner. The separate
  /// execution-side SQLite journal does not add another business writer.
  SqlitePublicationJournal? _publicationJournal;
  PublicationJournal
  get publicationJournal => _publicationJournal ??= SqlitePublicationJournal(
    directory: _root,
    executionExclusive: _serial,
    resolveSource: (operation) async {
      final rows = _commands.select('SELECT input FROM executions WHERE id=?', [
        _id(operation.key),
      ]);
      if (rows.isEmpty) storageFailure(FailureCode.notFound);
      final input = _decode(
        rows.single['input'] as String,
        EngineTask.fromJson,
      );
      final raw = plugin.ExecutionJournal.latest(
        _directory(_id(operation.key)),
      );
      if (input.key != operation.key ||
          raw == null ||
          raw['status'] != 2 ||
          raw['detached'] == true ||
          raw['stagingLocation'] != operation.sourceRef ||
          raw['downloadedBytes'] != operation.sourceLength ||
          (raw['totalBytes'] != null &&
              raw['totalBytes'] != operation.sourceLength) ||
          jsonEncode(input.directory.toJson()) !=
              jsonEncode(operation.directory.toJson())) {
        storageFailure(FailureCode.stateConflict, '完整下载材料或发布目录不匹配');
      }
      return operation.sourceRef;
    },
    commitPublished: (operation, file) async {
      final rows = _commands.select(
        'SELECT plugin_task FROM executions WHERE id=?',
        [_id(operation.key)],
      );
      if (rows.isEmpty) storageFailure(FailureCode.notFound);
      final task = plugin.DownloadTask.fromJson(
        jsonDecode(rows.single['plugin_task'] as String),
      );
      final raw = plugin.ExecutionJournal.latest(
        _directory(_id(operation.key)),
      );
      if (raw == null || raw['status'] != 2) {
        storageFailure(FailureCode.stateConflict);
      }
      if (raw['publishedLocation'] != null) {
        if (jsonEncode(raw['publishedLocation']) != jsonEncode(file.toJson())) {
          storageFailure(FailureCode.stateConflict);
        }
        if (raw['completeSourceRef'] != null) return;
      }
      final id = _id(operation.key);
      final sources = _commands.select(
        'SELECT ref FROM complete_sources WHERE id=?',
        [id],
      );
      final ref = sources.isEmpty
          ? 'complete:${DateTime.now().microsecondsSinceEpoch}:${Random.secure().nextInt(1 << 32)}'
          : sources.single['ref'] as String;
      if (sources.isEmpty) {
        final members = <String>{operation.sourceRef};
        for (final version in plugin.ExecutionJournal.versions(
          _directory(id),
        )) {
          final prior = jsonObject(jsonDecode(version.readAsStringSync()));
          members.addAll(
            List<String>.from(prior['ownedMaterials'] as List? ?? []),
          );
          if (!Platform.isIOS && prior['resumeData'] is Map) {
            members.add(
              jsonValue<String>(jsonObject(prior['resumeData']), 'data'),
            );
          }
        }
        _commands.execute('INSERT INTO complete_sources VALUES (?,?,?)', [
          id,
          ref,
          jsonEncode(members.toList()),
        ]);
      }
      await _downloader.recordExecution(task, {
        'completeSourceRef': ref,
        'publishOperation': {
          ...operation.toJson(),
          'phase': 'published',
          'targetRef': file.locator,
          'identity': file.identity,
        },
        'publishedLocation': file.toJson(),
      });
      _poll();
    },
  );

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
  Future<EngineReceipt> cancel(EngineCommand command) async {
    final stopped = (await _command('cancel', command))!;
    await _publicationCleanupGate(command.key);
    return stopped;
  }

  Future<void> _publicationCleanupGate(ExecutionKey key) async {
    final journal = publicationJournal as SqlitePublicationJournal;
    try {
      await journal.exclusiveFiles(
        () async => journal.assertPrivateCleanupAllowed(key),
      );
    } on FileStorageException catch (error) {
      throw PluginEngineException(error.failure);
    }
  }

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
    if (ack.releaseResumeRefs.isNotEmpty &&
        _receipt(ack.key, raw).state == DownloadStatus.completed) {
      await _releaseCompleted(ack, _receipt(ack.key, raw));
    } else if (ack.releaseResumeRefs.isNotEmpty) {
      await _publicationCleanupGate(ack.key);
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

  Future<void> _releaseCompleted(ReceiptAck ack, EngineReceipt latest) async {
    final id = _id(ack.key);
    void validateCurrent() {
      final business = _store.readTask(ack.key.taskId);
      final committed = _store.readAcknowledgements().where(
        (a) => a.key == ack.key,
      );
      final current = plugin.ExecutionJournal.latest(_directory(id));
      if (committed.length != 1 ||
          jsonEncode(committed.single.toJson()) != jsonEncode(ack.toJson()) ||
          current == null ||
          jsonEncode(_receipt(ack.key, current).toJson()) !=
              jsonEncode(latest.toJson()) ||
          ack.receiptVersion != latest.receiptVersion ||
          ack.releaseResumeRefs.length != 1 ||
          ack.releaseResumeRefs.single != latest.resumeRef ||
          latest.publishedLocation == null ||
          latest.publishOperation?.phase != PublishPhase.published ||
          business == null ||
          business.key != ack.key ||
          business.status != DownloadStatus.completed ||
          jsonEncode(business.engineReceipt?.toJson()) !=
              jsonEncode(latest.toJson()) ||
          jsonEncode(business.fileLocation?.toJson()) !=
              jsonEncode(latest.publishedLocation?.toJson()) ||
          jsonEncode(business.publishOperation?.toJson()) !=
              jsonEncode(latest.publishOperation?.toJson())) {
        _conflict('materialStillReferenced');
      }
    }

    validateCurrent();
    for (final row in _commands.select('SELECT input FROM executions')) {
      final other = _decode(row['input'] as String, EngineTask.fromJson).key;
      if (other.engineId == ack.key.engineId &&
          other.generation > ack.key.generation) {
        _conflict('staleExecution');
      }
    }
    final task = plugin.DownloadTask.fromJson(
      jsonDecode(
        _commands.select('SELECT plugin_task FROM executions WHERE id=?', [
              id,
            ]).single['plugin_task']
            as String,
      ),
    );
    await _downloader.waitForExecutionIdle(task);
    if ((await _downloader.allTasks(
      allGroups: true,
    )).any((task) => task.taskId == id)) {
      _conflict('materialStillReferenced');
    }
    final source = _commands.select(
      'SELECT ref,members FROM complete_sources WHERE id=?',
      [id],
    );
    if (source.isEmpty || source.single['ref'] != latest.resumeRef) {
      _conflict('unknownMaterial');
    }
    final members = (jsonDecode(source.single['members'] as String) as List)
        .cast<String>();
    final roots =
        [await getApplicationSupportDirectory(), await getTemporaryDirectory()]
            .where((directory) => directory.existsSync())
            .map((directory) => directory.resolveSymbolicLinksSync())
            .toList();
    // AppStore and native callbacks can change while idle/path queries yield.
    validateCurrent();
    // Paths are read solely from immutable execution history; private roots add
    // a boundary, while the opaque reference and exact completed ack authorize IO.
    for (final path in members) {
      final file = File(path);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (!file.isAbsolute ||
          !roots.any(
            (root) => path.startsWith('$root${Platform.pathSeparator}'),
          ) ||
          path == latest.publishedLocation!.locator ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file) ||
          (file.existsSync() && file.resolveSymbolicLinksSync() != path)) {
        _conflict('unknownMaterial');
      }
    }
    final payload = jsonEncode(ack.toJson());
    final intent = _commands.select(
      'SELECT ack,done FROM material_releases WHERE id=?',
      [id],
    );
    if (intent.isNotEmpty && intent.single['ack'] != payload) {
      _conflict('ackPayload');
    }
    final done = intent.isEmpty
        ? <String>[]
        : (jsonDecode(intent.single['done'] as String) as List).cast<String>();
    if (intent.isEmpty) {
      _commands.execute('INSERT INTO material_releases VALUES (?,?,?)', [
        id,
        payload,
        '[]',
      ]);
    }
    for (final path in members) {
      if (done.contains(path)) continue;
      validateCurrent();
      try {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type != FileSystemEntityType.notFound) {
          if (type != FileSystemEntityType.file) _conflict('unknownMaterial');
          await File(path).delete();
        }
        done.add(path);
        _commands.execute('UPDATE material_releases SET done=? WHERE id=?', [
          jsonEncode(done),
          id,
        ]);
      } on FileSystemException {
        throw PluginEngineException(
          DownloadFailure(
            code: FailureCode.cleanupFailure,
            message: '私有下载材料释放未完成，可重试确认',
          ),
        );
      }
    }
    validateCurrent();
  }

  /// Application teardown only; a View must never own this adapter's lifetime.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _timer?.cancel();
    if (identical(_callbackOwner, this)) {
      _downloader.unregisterCallbacks(group: _group, callback: _statusCallback);
      _downloader.unregisterCallbacks(
        group: _group,
        callback: _progressCallback,
      );
      _callbackOwner = null;
    }
    try {
      await _tail;
    } finally {
      try {
        await _events.close();
      } finally {
        try {
          _publicationJournal?.close();
        } finally {
          _commands.close();
        }
      }
    }
  }
}

/// Stable application error payload; no plugin or platform exception escapes.
final class PluginEngineException implements Exception {
  const PluginEngineException(this.failure);
  final DownloadFailure failure;
  @override
  String toString() => 'PluginEngineException(${failure.code.name})';
}
