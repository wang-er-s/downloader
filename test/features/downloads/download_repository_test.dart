import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/data/app_store_schema.dart';
import 'package:downloader/shared/platform/file_storage.dart';
import 'package:downloader/features/downloads/data/download_repository.dart';
import 'package:downloader/features/downloads/data/download_engine.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/settings/data/settings_repository.dart';
import 'package:downloader/features/settings/domain/app_settings.dart';
import 'package:downloader/features/saved_downloads/data/saved_download_repository.dart';
import 'package:downloader/features/saved_downloads/domain/saved_download.dart';

final directory = DirectoryLocation(
  platform: DownloadPlatform.macos,
  kind: DirectoryKind.systemDownloads,
  displayName: 'Downloader',
);
final otherDirectory = DirectoryLocation(
  platform: DownloadPlatform.macos,
  kind: DirectoryKind.userSelected,
  locator: 'bookmark',
  displayName: 'Other',
);

class FakeEngine implements DownloadEngine {
  final controller = StreamController<EngineEvent>.broadcast(sync: true);
  final receipts = <EngineReceipt>[];
  final commands = <EngineCommand>[];
  final acks = <ReceiptAck>[];
  bool failAck = false;
  bool failPause = false;
  void Function()? onInspect;
  Future<void> Function(ReceiptAck)? onAck;
  Future<void> Function(EngineCommand)? onPause;
  RepositoryException? cancelFailure;
  Future<void> Function()? onEnqueue;
  int enqueues = 0;
  int sequence = 0;
  String session = 'session';
  @override
  Stream<EngineEvent> get events => controller.stream;
  @override
  Future<EngineSnapshot> inspect() async {
    final snapshot = EngineSnapshot(
      ownerSessionId: session,
      sequence: sequence,
      receipts: receipts,
    );
    onInspect?.call();
    return snapshot;
  }

  @override
  Future<void> enqueue(EngineCommand command, EngineTask input) async {
    enqueues++;
    commands.add(command);
    await onEnqueue?.call();
  }

  EngineReceipt receipt(ExecutionKey key, int version, DownloadStatus state) =>
      EngineReceipt(
        key: key,
        receiptVersion: version,
        state: state,
        downloadedBytes: 8,
        resumeSupport: ResumeSupport.supported,
        resumeRef: 'resume',
      );
  @override
  Future<EngineReceipt> pause(EngineCommand command) async {
    commands.add(command);
    if (failPause) throw StateError('terminalSavePending');
    await onPause?.call(command);
    final r = receipt(
      command.key,
      command.expectedReceiptVersion + 1,
      DownloadStatus.paused,
    );
    receipts.add(r);
    return r;
  }

  @override
  Future<void> resume(EngineCommand command) async {
    commands.add(command);
  }

  @override
  Future<EngineReceipt> cancel(EngineCommand command) async {
    commands.add(command);
    if (cancelFailure != null) throw cancelFailure!;
    return receipt(
      command.key,
      command.expectedReceiptVersion + 1,
      DownloadStatus.cancelling,
    );
  }

  @override
  Future<void> acknowledge(ReceiptAck ack) async {
    if (failAck) throw StateError('injected');
    await onAck?.call(ack);
    acks.add(ack);
  }

  void emit(EngineReceipt receipt, {int? seq, String? owner}) {
    sequence = seq ?? sequence + 1;
    controller.add(
      EngineEvent(
        ownerSessionId: owner ?? session,
        sequence: sequence,
        key: receipt.key,
        downloadedBytes: receipt.downloadedBytes,
        sampleMonotonicMs: 1,
        receipt: receipt,
      ),
    );
  }
}

class FakeStorage implements FileStorage {
  int publications = 0;
  int reads = 0;
  Future<FileLocation> Function(PublishOperation)? onPublish;
  @override
  Future<DirectoryLocation?> pickDirectory() async => null;
  @override
  Future<FileLocation> publish(PublishOperation operation) async {
    publications++;
    if (onPublish != null) return onPublish!(operation);
    throw StateError('unexpected');
  }

  @override
  Future<PublishRecovery> recoverPublication(PublishOperation operation) async {
    reads++;
    return PublishRecovery(disposition: PublishDisposition.uncertain);
  }

  @override
  Future<void> deleteOwned(FileLocation file) async {}
  @override
  Future<void> open(FileLocation file) async {}
}

void main() {
  late Database db;
  late AppStore store;
  late FakeEngine engine;
  late FakeStorage storage;
  late SettingsRepository settings;
  late DownloadRepository repository;
  late SavedDownloadRepository saved;
  setUp(() async {
    db = sqlite3.openInMemory();
    store = AppStore(db);
    engine = FakeEngine();
    storage = FakeStorage();
    settings = SettingsRepository(store: store, defaultDirectory: directory);
    repository = await DownloadRepository.initialize(
      store: store,
      engine: engine,
      storage: storage,
      stagingDirectory: '/tmp/repository-test',
    );
    saved = SavedDownloadRepository(store: store, downloads: repository);
  });
  tearDown(() async {
    await saved.close();
    await repository.close();
    await settings.close();
    await engine.controller.close();
    store.close();
  });
  Future<DownloadTask> create([String request = 'request']) =>
      repository.create(
        CreateDownload(requestId: request, url: ' https://example.com/file '),
      );
  test('stable request dedup persists original nullable directory', () async {
    final task = await create();
    await settings.setDefaultDirectory(otherDirectory);
    expect((await create()).id, task.id);
    expect(engine.enqueues, 1);
    await expectLater(
      repository.create(
        CreateDownload(
          requestId: 'request',
          url: task.originalUrl,
          directory: directory,
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(engine.enqueues, 1);
  });
  test(
    'event delivered during initial inspect is buffered and applied after snapshot',
    () async {
      final task = await create();
      await repository.close();
      engine.onInspect = () {
        engine.onInspect = null;
        engine.emit(engine.receipt(task.key, 2, DownloadStatus.paused));
      };
      repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '/tmp/repository-test',
      );
      await repository.synchronize();
      expect(store.readTask(task.id)!.engineReceipt!.receiptVersion, 2);
    },
  );
  test(
    'unknown total progress without receipt preserves real bytes and immutable snapshot',
    () async {
      final task = await create();
      engine.controller.add(
        EngineEvent(
          ownerSessionId: engine.session,
          sequence: 1,
          key: task.key,
          downloadedBytes: 12345,
          sampleMonotonicMs: 100,
        ),
      );
      final progressed = await repository.watchTasks().firstWhere(
        (tasks) => tasks.single.downloadedBytes == 12345,
      );
      expect(progressed.single.totalBytes, isNull);
      expect(progressed.single.progress, isNull);
    },
  );
  test('watch delivers immutable initial and updated snapshots', () async {
    final first = await repository.watchTasks().first;
    expect(first, isEmpty);
    expect(() => first.clear(), throwsUnsupportedError);
    final task = await create();
    expect((await repository.watchTasks().first).single.id, task.id);
  });
  test(
    'settings persist theme and retain existing directory on reopen',
    () async {
      await settings.setTheme(AppTheme.dark);
      await settings.setDefaultDirectory(otherDirectory);
      final second = SettingsRepository(
        store: store,
        defaultDirectory: directory,
      );
      expect((await second.watchSettings().first).theme, AppTheme.dark);
      expect(second.current.defaultDirectory.locator, 'bookmark');
      await second.close();
    },
  );
  test(
    'saved configuration save does not download and start uses latest default',
    () async {
      await saved.save(
        SavedDownloadInput(id: 'saved', url: 'https://example.com/file'),
      );
      expect(engine.enqueues, 0);
      await settings.setDefaultDirectory(otherDirectory);
      final task = await saved.start('saved', 'start');
      await saved.delete('saved');
      expect(task.directory.locator, 'bookmark');
      expect(store.readTasks().length, 1);
      expect(await saved.watchSavedDownloads().first, isEmpty);
    },
  );
  test(
    'pause persists receipt before ack and repeated pause is idempotent',
    () async {
      final task = await create();
      await repository.pause(task.id);
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      expect(engine.acks.single.releaseResumeRefs, isEmpty);
      await repository.pause(task.id);
      expect(engine.commands.length, 2);
    },
  );
  test(
    'pause save failure retains actual stopped state and does not acknowledge',
    () async {
      final task = await create();
      db.execute(
        "CREATE TRIGGER fail_receipt BEFORE INSERT ON engine_receipt_acks BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        repository.pause(task.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(
        (await repository.watchTasks().first).single.status,
        DownloadStatus.paused,
      );
      expect(engine.acks, isEmpty);
      final commandCount = engine.commands.length;
      await expectLater(
        repository.resume(task.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(engine.commands.length, commandCount);
      expect(
        store.readTask(task.id)!.engineReceipt,
        isNull,
        reason:
            'a later intent must not persist the uncommitted receipt without its ack',
      );
      db.execute('DROP TRIGGER fail_receipt');
      await repository.synchronize();
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      expect(engine.acks, isNotEmpty);
    },
  );
  test(
    'ack failure preserves business commit and replays confirmation',
    () async {
      final task = await create();
      engine.failAck = true;
      await expectLater(
        repository.pause(task.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      engine.failAck = false;
      await repository.synchronize();
      expect(engine.enqueues, 1);
      expect(engine.acks, isNotEmpty);
    },
  );
  test(
    'cancel removes task but retains confirmation and ignores orphan event',
    () async {
      final task = await create();
      await repository.cancel(task.id);
      engine.emit(engine.receipt(task.key, 8, DownloadStatus.running));
      await repository.synchronize();
      expect(store.readTasks(), isEmpty);
      expect(store.readAcknowledgements(), isNotEmpty);
    },
  );
  test('older receipt cannot roll back newer checkpoint', () async {
    final task = await create();
    final newest = engine.receipt(task.key, 3, DownloadStatus.paused);
    engine.receipts.add(newest);
    engine.emit(newest);
    await repository.synchronize();
    engine.emit(engine.receipt(task.key, 1, DownloadStatus.running));
    await repository.synchronize();
    expect(store.readTask(task.id)!.engineReceipt!.receiptVersion, 3);
  });
  test(
    'restart unsupported preserves execution and sends no command',
    () async {
      final task = await create();
      await repository.pause(task.id);
      final count = engine.commands.length;
      await expectLater(
        repository.resume(task.id, restartFromZero: true),
        throwsA(isA<RepositoryException>()),
      );
      expect(engine.commands.length, count);
      expect(store.readTask(task.id)!.generation, 0);
    },
  );
  test(
    'v1 migrates without guessing original input and retains four tables',
    () {
      final raw = sqlite3.openInMemory();
      raw.execute(appStoreSchemaV1);
      final migrated = AppStore(raw);
      expect(raw.userVersion, 2);
      expect(
        raw.select("SELECT name FROM sqlite_master WHERE type='table'").length,
        4,
      );
      expect(
        migrated.transaction((tx) => tx.readCreateInput('missing')),
        isNull,
      );
      migrated.close();
    },
  );
  test('v1 migration failure retains version and sentinel database', () {
    final root = Directory.systemTemp.createTempSync('repository-migrate-');
    final path = '${root.path}/db';
    var raw = sqlite3.open(path);
    raw.execute(appStoreSchemaV1);
    raw.execute('DROP TABLE saved_downloads');
    raw.close();
    try {
      expect(
        () => AppStore(sqlite3.open(path)),
        throwsA(isA<SqliteException>()),
      );
      raw = sqlite3.open(path);
      expect(raw.userVersion, 1);
      expect(
        raw
            .select('PRAGMA table_info(download_tasks)')
            .any((r) => r['name'] == 'create_input_json'),
        isFalse,
      );
      raw.close();
    } finally {
      root.deleteSync(recursive: true);
    }
  });
  test(
    'pause retries retain full command after terminal save failure',
    () async {
      final task = await create();
      engine.failPause = true;
      await expectLater(
        repository.pause(task.id),
        throwsA(isA<RepositoryException>()),
      );
      final original = engine.commands.last;
      engine.failPause = false;
      await repository.pause(task.id);
      expect(engine.commands.last.toJson(), original.toJson());
    },
  );
  test(
    'input and initial task rollback together on SQL input write failure',
    () async {
      db.execute(
        "CREATE TRIGGER fail_input BEFORE UPDATE OF create_input_json ON download_tasks BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(create(), throwsA(isA<RepositoryException>()));
      expect(store.readTasks(), isEmpty);
      expect(engine.enqueues, 0);
    },
  );
  test(
    'historical task with unknown original input rejects without enqueue',
    () async {
      final task = await create();
      db.execute('UPDATE download_tasks SET create_input_json=NULL');
      await expectLater(create(), throwsA(isA<RepositoryException>()));
      expect(store.readTask(task.id), isNotNull);
      expect(engine.enqueues, 1);
    },
  );
  test(
    'subscription error reaches task stream without emitting fake empty state',
    () async {
      await create();
      final error = repository.watchTasks().firstWhere((_) => false);
      engine.controller.addError(StateError('injected'));
      await expectLater(error, throwsA(isA<RepositoryException>()));
      expect((await repository.watchTasks().first).length, 1);
    },
  );
  test(
    'old session event triggers inspection and cannot replace current receipt',
    () async {
      final task = await create();
      await repository.pause(task.id);
      engine.emit(
        engine.receipt(task.key, 99, DownloadStatus.running),
        owner: 'old-session',
      );
      await repository.synchronize();
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      expect(engine.enqueues, 1);
    },
  );
  test(
    'startup publication uncertain is read only and explicit retry also refuses',
    () async {
      final task = await create();
      final operation = PublishOperation(
        operationId: 'op',
        key: task.key,
        sourceRef: '/tmp/source',
        sourceLength: 8,
        directory: directory,
        temporaryName: '.op.part',
        candidateName: 'file',
        phase: PublishPhase.creating,
      );
      final receipt = EngineReceipt(
        key: task.key,
        receiptVersion: 1,
        state: DownloadStatus.publishing,
        downloadedBytes: 8,
        resumeSupport: ResumeSupport.unsupported,
        stagingLocation: '/tmp/source',
        publishOperation: operation,
      );
      engine.receipts.add(receipt);
      await repository.synchronize();
      expect(
        store.readTask(task.id)!.lastError!.code,
        FailureCode.publicationUncertain,
      );
      await expectLater(
        repository.retryPublication(task.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(storage.publications, 0);
      expect(storage.reads, greaterThanOrEqualTo(2));
    },
  );
  test(
    'cancel intent wins over queued completed event without releasing source',
    () async {
      final task = await create();
      final operation = PublishOperation(
        operationId: 'done',
        key: task.key,
        sourceRef: '/tmp/source',
        sourceLength: 8,
        directory: directory,
        temporaryName: '.done.part',
        candidateName: 'file',
        phase: PublishPhase.published,
        targetRef: '/tmp/final',
        identity: 'owned',
      );
      engine.emit(
        EngineReceipt(
          key: task.key,
          receiptVersion: 1,
          state: DownloadStatus.completed,
          downloadedBytes: 8,
          resumeSupport: ResumeSupport.unsupported,
          resumeRef: 'complete:owned',
          publishOperation: operation,
          publishedLocation: FileLocation(
            platform: DownloadPlatform.macos,
            kind: FileKind.path,
            locator: '/tmp/final',
            identity: 'owned',
          ),
        ),
      );
      await expectLater(
        repository.cancel(task.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.readTask(task.id)!.status, DownloadStatus.cancelling);
      expect(engine.acks.every((ack) => ack.releaseResumeRefs.isEmpty), isTrue);
      expect(
        store.readTask(task.id)!.pendingCommand!.commandId,
        startsWith('cancel:'),
      );
    },
  );
  test(
    'settings SQL failure keeps previous persisted value and stream',
    () async {
      db.execute(
        "CREATE TRIGGER fail_settings BEFORE INSERT ON app_settings BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        settings.setTheme(AppTheme.dark),
        throwsA(isA<RepositoryException>()),
      );
      expect((await settings.watchSettings().first).theme, AppTheme.system);
    },
  );
  test(
    'reopen before business commit replays actual pause without enqueue',
    () async {
      final task = await create();
      final receipt = engine.receipt(task.key, 2, DownloadStatus.paused);
      engine.receipts.add(receipt);
      await repository.close();
      repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '/tmp/repository-test',
      );
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      expect(engine.enqueues, 1);
      expect(engine.acks.last.receiptVersion, 2);
    },
  );
  test(
    'reopen after business commit replays identical ack without command',
    () async {
      final task = await create();
      engine.failAck = true;
      await expectLater(
        repository.pause(task.id),
        throwsA(isA<RepositoryException>()),
      );
      final ack = store.readAcknowledgements().single;
      await repository.close();
      engine.failAck = false;
      repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '/tmp/repository-test',
      );
      expect(engine.acks.last.toJson(), ack.toJson());
      expect(engine.enqueues, 1);
    },
  );
  EngineReceipt completed(DownloadTask task, int version) => EngineReceipt(
    key: task.key,
    receiptVersion: version,
    state: DownloadStatus.completed,
    downloadedBytes: 8,
    resumeSupport: ResumeSupport.unsupported,
    resumeRef: 'complete:owned',
    publishOperation: PublishOperation(
      operationId: 'operation',
      key: task.key,
      sourceRef: '/tmp/source',
      sourceLength: 8,
      directory: directory,
      temporaryName: '.operation.part',
      candidateName: 'file',
      phase: PublishPhase.published,
      targetRef: '/tmp/final',
      identity: 'owned',
    ),
    publishedLocation: FileLocation(
      platform: DownloadPlatform.macos,
      kind: FileKind.path,
      locator: '/tmp/final',
      identity: 'owned',
    ),
  );
  test(
    'cancel persists during blocked publish, retains late completion and survives reopen',
    () async {
      final task = await create();
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.onPublish = (operation) async {
        entered.complete();
        await release.future;
        engine.receipts.add(completed(task, 2));
        return completed(task, 2).publishedLocation!;
      };
      engine.emit(
        EngineReceipt(
          key: task.key,
          receiptVersion: 1,
          state: DownloadStatus.publishing,
          downloadedBytes: 8,
          resumeSupport: ResumeSupport.unsupported,
          stagingLocation: '/tmp/source',
        ),
      );
      await entered.future.timeout(const Duration(seconds: 2));
      final cancellation = repository.cancel(task.id);
      final rejected = expectLater(
        cancellation,
        throwsA(isA<RepositoryException>()),
      );
      expect(store.readTask(task.id)!.status, DownloadStatus.cancelling);
      final original = store.readTask(task.id)!.pendingCommand!.toJson();
      final second = await create('other').timeout(const Duration(seconds: 2));
      await repository.pause(second.id).timeout(const Duration(seconds: 2));
      expect(store.readTask(second.id)!.status, DownloadStatus.paused);
      release.complete();
      await rejected;
      expect(store.readTask(task.id)!.fileLocation, isNotNull);
      expect(store.readTask(task.id)!.status, DownloadStatus.cancelling);
      expect(
        store
            .readAcknowledgements()
            .firstWhere((a) => a.key == task.key)
            .releaseResumeRefs,
        isEmpty,
      );
      await repository.close();
      repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '/tmp/repository-test',
      );
      expect(store.readTask(task.id)!.pendingCommand!.toJson(), original);
      expect(storage.publications, 1);
      expect(engine.enqueues, 2);
    },
  );
  test(
    'cancel persists while another receipt acknowledgement is blocked',
    () async {
      final task = await create();
      final entered = Completer<void>();
      final release = Completer<void>();
      engine.onAck = (ack) async {
        if (ack.key == task.key && ack.receiptVersion == 1) {
          entered.complete();
          await release.future;
        }
      };
      engine.emit(engine.receipt(task.key, 1, DownloadStatus.running));
      await entered.future.timeout(const Duration(seconds: 2));
      final cancellation = repository.cancel(task.id);
      expect(store.readTask(task.id)!.status, DownloadStatus.cancelling);
      release.complete();
      await cancellation;
      expect(store.readTask(task.id), isNull);
    },
  );
  test(
    'delete record retains complete authorization until full ack succeeds',
    () async {
      final task = await create();
      engine.receipts.add(completed(task, 1));
      await repository.synchronize();
      final original = store.readAcknowledgements().single.toJson();
      engine.failAck = true;
      await expectLater(
        repository.deleteCompleted(task.id, deleteFile: false),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.readTask(task.id)!.status, DownloadStatus.completed);
      expect(store.readAcknowledgements().single.toJson(), original);
      engine.failAck = false;
      await repository.deleteCompleted(task.id, deleteFile: false);
      expect(store.readTask(task.id), isNull);
      expect(engine.acks.last.toJson(), original);
    },
  );
  test(
    'createTask rejects existing identity and explicit directory mismatch atomically',
    () async {
      final task = await create();
      expect(
        () => store.transaction(
          (tx) => tx.createTask(
            task,
            CreateDownload(requestId: 'different', url: task.originalUrl),
          ),
        ),
        throwsA(isA<DownloadValidationException>()),
      );
      final changed = DownloadTask.fromJson({
        ...task.toJson(),
        'id': 'new',
        'requestId': 'new',
        'engineId': 'new',
        'pendingCommand': null,
      });
      expect(
        () => store.transaction(
          (tx) => tx.createTask(
            changed,
            CreateDownload(
              requestId: 'new',
              url: task.originalUrl,
              directory: otherDirectory,
            ),
          ),
        ),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(store.readTasks().length, 1);
    },
  );
  test(
    'fresh and migrated databases have identical four table definitions',
    () {
      final raw = sqlite3.openInMemory();
      raw.execute(appStoreSchemaV1);
      final migrated = AppStore(raw);
      expect(
        raw.select(
          "SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name",
        ),
        db.select(
          "SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name",
        ),
      );
      expect(
        raw.select('PRAGMA table_info(download_tasks)'),
        db.select('PRAGMA table_info(download_tasks)'),
      );
      migrated.close();
    },
  );
  test(
    'completed commit SQL failure retains source authorization for atomic retry',
    () async {
      final task = await create();
      engine.receipts.add(completed(task, 1));
      db.execute(
        "CREATE TRIGGER fail_complete BEFORE INSERT ON engine_receipt_acks BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        repository.synchronize(),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.readTask(task.id)!.engineReceipt, isNull);
      expect(engine.acks, isEmpty);
      db.execute('DROP TRIGGER fail_complete');
      await repository.synchronize();
      expect(store.readTask(task.id)!.status, DownloadStatus.completed);
      expect(store.readAcknowledgements().single.releaseResumeRefs, [
        'complete:owned',
      ]);
    },
  );
  test(
    'create input survives repository reopen and ordinary saveTask',
    () async {
      final task = await create();
      await repository.pause(task.id);
      await repository.close();
      await settings.setDefaultDirectory(otherDirectory);
      repository = await DownloadRepository.initialize(
        store: store,
        engine: engine,
        storage: storage,
        stagingDirectory: '/tmp/repository-test',
      );
      expect((await create()).id, task.id);
      expect(
        store.transaction((tx) => tx.readCreateInput('request'))!.directory,
        isNull,
      );
      expect(engine.enqueues, 1);
    },
  );
  test(
    'pause command can wait for event acknowledgement without queue deadlock',
    () async {
      final task = await create();
      final acknowledged = Completer<void>();
      engine.onAck = (ack) async {
        if (!acknowledged.isCompleted) acknowledged.complete();
      };
      engine.onPause = (command) async {
        engine.emit(engine.receipt(command.key, 1, DownloadStatus.paused));
        await acknowledged.future.timeout(const Duration(seconds: 2));
      };
      await repository.pause(task.id).timeout(const Duration(seconds: 3));
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
    },
  );
  test(
    'initial inspect failure rejects initialization without fake empty repository',
    () async {
      engine.onInspect = () => throw StateError('initial inspect failed');
      await expectLater(
        DownloadRepository.initialize(
          store: store,
          engine: engine,
          storage: storage,
          stagingDirectory: '/tmp/repository-test',
        ),
        throwsA(isA<RepositoryException>()),
      );
      engine.onInspect = null;
    },
  );
  test(
    'sequence gap re-inspects and ignores triggering stale event payload',
    () async {
      final task = await create();
      engine.receipts.add(engine.receipt(task.key, 2, DownloadStatus.paused));
      engine.emit(engine.receipt(task.key, 99, DownloadStatus.running), seq: 8);
      await repository.synchronize();
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
      expect(store.readTask(task.id)!.engineReceipt!.receiptVersion, 2);
    },
  );
  test(
    'definitely rejected cancel keeps intent and permits fresh explicit command after sync',
    () async {
      final task = await create();
      engine.cancelFailure = RepositoryException(
        DownloadFailure(
          code: FailureCode.stateConflict,
          message: 'stale',
          details: {'reason': 'staleReceipt'},
        ),
      );
      await expectLater(
        repository.cancel(task.id),
        throwsA(isA<RepositoryException>()),
      );
      final rejected = engine.commands.last.toJson();
      expect(store.readTask(task.id)!.status, DownloadStatus.cancelling);
      expect(store.readTask(task.id)!.pendingCommand, isNull);
      engine.receipts.add(engine.receipt(task.key, 2, DownloadStatus.paused));
      await repository.synchronize();
      engine.cancelFailure = null;
      await repository.cancel(task.id);
      expect(engine.commands.last.expectedReceiptVersion, 2);
      expect(engine.commands.last.commandId, isNot(rejected['commandId']));
      expect(store.readTask(task.id), isNull);
    },
  );
  test(
    'same task pause waits for enqueue acceptance while other tasks remain independent',
    () async {
      final other = await create('other');
      final entered = Completer<void>();
      final release = Completer<void>();
      engine.onEnqueue = () async {
        entered.complete();
        await release.future;
      };
      final creating = create();
      await entered.future.timeout(const Duration(seconds: 2));
      final task = store.readTasks().firstWhere(
        (t) => t.requestId == 'request',
      );
      final pausing = repository.pause(task.id);
      await repository.cancel(other.id).timeout(const Duration(seconds: 2));
      expect(engine.commands.where((c) => c.key == task.key).length, 1);
      release.complete();
      await creating;
      await pausing;
      expect(store.readTask(task.id)!.status, DownloadStatus.paused);
    },
  );
}
