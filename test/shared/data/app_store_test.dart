import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:downloader/shared/data/app_store.dart';
import 'package:downloader/shared/platform/app_store_location.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/saved_downloads/domain/saved_download.dart';
import 'package:downloader/features/settings/domain/app_settings.dart';
import '../../features/downloads/fixtures.dart';

void main() {
  late Database db;
  late AppStore store;
  setUp(() {
    db = sqlite3.openInMemory();
    store = AppStore(db);
  });
  tearDown(() => store.close());

  test('atomic schema creates exactly design tables and v1', () {
    expect(db.select('PRAGMA user_version').single['user_version'], 1);
    expect(
      db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((row) => row['name'])
          .toSet(),
      {
        'download_tasks',
        'saved_downloads',
        'app_settings',
        'engine_receipt_acks',
      },
    );
    expect(
      db.select('PRAGMA table_info(download_tasks)').map((row) => row['name']),
      containsAll(['pending_command_json', 'publish_operation_json']),
    );
  });
  test('typed task and nested JSON round trip including owned location', () {
    final original = DownloadTask.fromJson({
      ...task(engineReceipt: receipt(), fileLocation: location).toJson(),
      'pendingCommand': command.toJson(),
      'publishOperation': publication.toJson(),
      'targetRef': '{opaque-reference}',
      'lastError': DownloadFailure(
        code: FailureCode.persistenceFailure,
        message: '保存失败',
        details: {
          'reason': ['disk'],
        },
      ).toJson(),
    });
    store.transaction((tx) => tx.saveTask(original));
    expect(store.readTask('task')!.toJson(), original.toJson());
    expect(store.readTasks().single.totalBytes, isNull);
    expect(store.readTasks().single.downloadedBytes, 0x100000001);
    expect(() => store.readTasks().clear(), throwsUnsupportedError);
  });
  test('maximum signed 64-bit byte/generation persists without truncation', () {
    final original = DownloadTask.fromJson({
      ...task().toJson(),
      'generation': 0x7fffffffffffffff,
      'downloadedBytes': 0x7fffffffffffffff,
      'totalBytes': 0x7fffffffffffffff,
    });
    store.transaction((tx) => tx.saveTask(original));
    expect(store.readTasks().single.toJson(), original.toJson());
  });
  test('duplicate requestId and engineId reject preserving original', () {
    store.transaction((tx) => tx.saveTask(task()));
    expect(
      () => store.transaction(
        (tx) => tx.saveTask(task(id: 'other', engineId: 'other')),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => store.transaction(
        (tx) => tx.saveTask(task(id: 'other', requestId: 'other')),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => store.transaction((tx) => tx.saveTask(task(requestId: 'changed'))),
      throwsA(isA<DownloadValidationException>()),
    );
    for (final changedInput in [
      {'originalUrl': 'https://different.example/file'},
      {'requestedFileName': 'different.bin'},
      {
        'directory': {...directory.toJson(), 'subdirectory': 'Other'},
      },
    ]) {
      expect(
        () => store.transaction(
          (tx) => tx.saveTask(
            DownloadTask.fromJson({...task().toJson(), ...changedInput}),
          ),
        ),
        throwsA(isA<DownloadValidationException>()),
      );
    }
    expect(store.readTasks(), hasLength(1));
    expect(store.readTasks().single.requestId, 'request');
  });
  test('actual SQLite rejects negative counts and illegal enum values', () {
    store.transaction((tx) => tx.saveTask(task()));
    for (final assignment in [
      "status='invalid'",
      'generation=-1',
      'downloaded_bytes=-1',
      'total_bytes=-1',
    ]) {
      expect(
        () => db.execute('UPDATE download_tasks SET $assignment'),
        throwsA(isA<SqliteException>()),
      );
    }
    store.transaction(
      (tx) => tx.saveSettings(AppSettings(defaultDirectory: directory)),
    );
    expect(
      () => db.execute("UPDATE app_settings SET theme='future'"),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => db.execute('UPDATE app_settings SET id=2'),
      throwsA(isA<SqliteException>()),
    );
    for (final values in [
      [-1, 1],
      [0, 0],
      [0, -1],
    ]) {
      expect(
        () => db.execute('INSERT INTO engine_receipt_acks VALUES (?,?,?,?,?)', [
          'e',
          values[0],
          't',
          values[1],
          '[]',
        ]),
        throwsA(isA<SqliteException>()),
      );
    }
    expect(store.readTasks().single.downloadedBytes, 0x100000001);
    expect(store.readSettings()!.theme, AppTheme.system);
  });
  test(
    'business state and ack rollback together on actual SQL write failure',
    () {
      store.transaction((tx) => tx.saveTask(task(bytes: 5)));
      db.execute(
        '''CREATE TRIGGER reject_ack BEFORE INSERT ON engine_receipt_acks
      BEGIN SELECT RAISE(ABORT, 'injected write failure'); END''',
      );
      expect(
        () => store.transaction(
          (tx) => tx.commitReceipt(
            task(engineReceipt: receipt()),
            ReceiptAck(key: key, receiptVersion: 1),
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(store.readTask('task')!.downloadedBytes, 5);
      expect(store.readAcknowledgements(), isEmpty);
      db.execute('DROP TRIGGER reject_ack');
      store.transaction(
        (tx) => tx.commitReceipt(
          task(engineReceipt: receipt()),
          ReceiptAck(key: key, receiptVersion: 1),
        ),
      );
      expect(store.readTask('task')!.downloadedBytes, 0x100000001);
      expect(store.readAcknowledgements().single.receiptVersion, 1);
    },
  );
  test('exception after ack write rolls back both persisted facts', () {
    expect(
      () => store.transaction<void>((tx) {
        tx.saveTask(task());
        tx.commitReceipt(
          task(engineReceipt: receipt()),
          ReceiptAck(key: key, receiptVersion: 1),
        );
        throw StateError('after ack before commit');
      }),
      throwsStateError,
    );
    expect(store.readTasks(), isEmpty);
    expect(store.readAcknowledgements(), isEmpty);
  });
  test('older receipts cannot regress state or release newer material', () {
    store.transaction((tx) => tx.saveTask(task()));
    final latest = ReceiptAck(
      key: key,
      receiptVersion: 3,
      releaseResumeRefs: ['owned-old-material'],
    );
    store.transaction(
      (tx) =>
          tx.commitReceipt(task(engineReceipt: receipt(version: 3)), latest),
    );
    expect(
      store.transaction(
        (tx) => tx.commitReceipt(
          task(engineReceipt: receipt(version: 1)),
          ReceiptAck(
            key: key,
            receiptVersion: 1,
            releaseResumeRefs: ['new-material'],
          ),
        ),
      ),
      isFalse,
    );
    store.transaction(
      (tx) => tx.saveAcknowledgement(ReceiptAck(key: key, receiptVersion: 2)),
    );
    expect(store.readTask('task')!.engineReceipt!.receiptVersion, 3);
    expect(store.readAcknowledgements().single.toJson(), latest.toJson());
    expect(
      () => store.transaction((tx) => tx.saveTask(task())),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => store.transaction(
        (tx) => tx.saveTask(task(engineReceipt: receipt())),
      ),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => store.transaction(
        (tx) => tx.saveAcknowledgement(
          ReceiptAck(
            key: key,
            receiptVersion: 3,
            releaseResumeRefs: ['new-material'],
          ),
        ),
      ),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      store.transaction(
        (tx) =>
            tx.commitReceipt(task(engineReceipt: receipt(version: 3)), latest),
      ),
      isFalse,
    );
  });
  test('delete task keeps last ack and normal ack releases no resume refs', () {
    store.transaction((tx) {
      tx.saveTask(task());
      tx.commitReceipt(
        task(engineReceipt: receipt()),
        ReceiptAck(key: key, receiptVersion: 1),
      );
      tx.deleteTask('task');
    });
    expect(store.readTasks(), isEmpty);
    expect(store.readAcknowledgements().single.releaseResumeRefs, isEmpty);
    expect(db.select('PRAGMA foreign_key_list(engine_receipt_acks)'), isEmpty);
    expect(
      store.transaction(
        (tx) => tx.commitReceipt(
          task(engineReceipt: receipt()),
          ReceiptAck(key: key, receiptVersion: 1),
        ),
      ),
      isFalse,
    );
    expect(store.readTasks(), isEmpty);
    expect(
      store.transaction(
        (tx) => tx.commitReceipt(
          task(engineReceipt: receipt(version: 2)),
          ReceiptAck(key: key, receiptVersion: 2),
        ),
      ),
      isFalse,
    );
    expect(store.readTasks(), isEmpty);
  });
  test('ack key collision and receipt mismatch fail closed', () {
    store.transaction(
      (tx) => tx.saveAcknowledgement(ReceiptAck(key: key, receiptVersion: 1)),
    );
    final wrong = ExecutionKey(
      taskId: 'other',
      engineId: key.engineId,
      generation: 0,
    );
    expect(
      () => store.transaction(
        (tx) =>
            tx.saveAcknowledgement(ReceiptAck(key: wrong, receiptVersion: 2)),
      ),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => store.transaction(
        (tx) => tx.commitReceipt(
          task(engineReceipt: receipt()),
          ReceiptAck(key: key, receiptVersion: 2),
        ),
      ),
      throwsA(isA<DownloadValidationException>()),
    );
  });
  test(
    'configuration delete independent, stable id updates, settings persist',
    () {
      store.transaction((tx) {
        tx.saveTask(task());
        tx.saveSavedDownload(
          SavedDownload(
            id: 'saved',
            url: 'https://example.com',
            createdAt: now,
            updatedAt: now,
          ),
        );
        tx.saveSavedDownload(
          SavedDownload(
            id: 'saved',
            url: 'https://example.org',
            createdAt: now,
            updatedAt: now,
          ),
        );
        tx.saveSettings(
          AppSettings(theme: AppTheme.dark, defaultDirectory: directory),
        );
      });
      expect(store.readSavedDownloads().single.url, 'https://example.org');
      expect(store.readSavedDownloads().single.directory, isNull);
      store.transaction((tx) => tx.deleteSavedDownload('saved'));
      expect(store.readSavedDownloads(), isEmpty);
      expect(store.readTasks(), hasLength(1));
      expect(store.readSettings()!.theme, AppTheme.dark);
    },
  );
  test(
    'invalid JSON/unknown versions read failure does not overwrite data',
    () {
      store.transaction((tx) => tx.saveTask(task()));
      final bad = jsonEncode({...directory.toJson(), 'version': 99});
      db.execute('UPDATE download_tasks SET directory_json=?', [bad]);
      expect(store.readTasks, throwsA(isA<DownloadValidationException>()));
      expect(
        () => store.transaction((tx) => tx.saveTask(task(bytes: 1))),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        db
            .select('SELECT directory_json FROM download_tasks')
            .single['directory_json'],
        bad,
      );
      db.execute("UPDATE download_tasks SET directory_json='broken-json'");
      expect(store.readTasks, throwsFormatException);
      expect(
        db.select('SELECT count(*) AS n FROM download_tasks').single['n'],
        1,
      );
    },
  );
  test('transaction handles expire, nested and async callbacks rejected', () {
    late StoreTransaction expired;
    store.transaction((tx) {
      expired = tx;
    });
    expect(expired.readTasks, throwsStateError);
    expect(
      () => store.transaction((tx) => store.readTasks()),
      throwsStateError,
    );
    expect(
      () => store.transaction((tx) => Future.value(1)),
      throwsArgumentError,
    );
    expect(store.readTasks(), isEmpty);
  });
  test(
    'unknown directory versions cannot be overwritten in settings/config',
    () {
      store.transaction((tx) {
        tx.saveSettings(AppSettings(defaultDirectory: directory));
        tx.saveSavedDownload(
          SavedDownload(
            id: 's',
            url: 'https://example.com',
            directory: directory,
            createdAt: now,
            updatedAt: now,
          ),
        );
      });
      final bad = jsonEncode({...directory.toJson(), 'version': 9});
      db.execute('UPDATE app_settings SET default_directory_json=?', [bad]);
      db.execute('UPDATE saved_downloads SET directory_json=?', [bad]);
      expect(
        () => store.transaction(
          (tx) => tx.saveSettings(AppSettings(defaultDirectory: directory)),
        ),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        () => store.transaction(
          (tx) => tx.saveSavedDownload(
            SavedDownload(
              id: 's',
              url: 'https://example.org',
              createdAt: now,
              updatedAt: now,
            ),
          ),
        ),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        db
            .select('SELECT default_directory_json FROM app_settings')
            .single
            .values
            .single,
        bad,
      );
      expect(
        db
            .select('SELECT directory_json FROM saved_downloads')
            .single
            .values
            .single,
        bad,
      );
    },
  );
  test('persistent application-support path and real disk reopen', () async {
    final temp = Directory.systemTemp.createTempSync('downloader-store-');
    try {
      final path = await appStorePath(
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      expect(path, '${temp.path}/support/downloader.db');
      var disk = await AppStore.openPersistent(databasePath: () async => path);
      disk.transaction((tx) {
        tx.saveTask(task());
        tx.commitReceipt(
          task(engineReceipt: receipt()),
          ReceiptAck(key: key, receiptVersion: 1),
        );
        tx.saveSettings(AppSettings(defaultDirectory: directory));
        tx.saveSavedDownload(
          SavedDownload(
            id: 's',
            url: 'https://example.com',
            createdAt: now,
            updatedAt: now,
          ),
        );
      });
      disk.close();
      disk = await AppStore.openPersistent(databasePath: () async => path);
      expect(disk.readTasks().single.downloadedBytes, 0x100000001);
      expect(disk.readAcknowledgements().single.receiptVersion, 1);
      expect(disk.readSettings()!.theme, AppTheme.system);
      expect(disk.readSavedDownloads(), hasLength(1));
      disk.close();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
  test(
    'failed initial schema creation rolls all tables back, preserving file',
    () {
      final temp = Directory.systemTemp.createTempSync(
        'downloader-init-failure-',
      );
      final path = '${temp.path}/db';
      var raw = sqlite3.open(path);
      raw.execute('CREATE TABLE saved_downloads (marker TEXT)');
      raw.execute("INSERT INTO saved_downloads VALUES ('original')");
      raw.close();
      try {
        expect(
          () => AppStore(sqlite3.open(path)),
          throwsA(isA<SqliteException>()),
        );
        raw = sqlite3.open(path);
        expect(raw.select('PRAGMA user_version').single['user_version'], 0);
        expect(
          raw
              .select("SELECT name FROM sqlite_master WHERE type='table'")
              .map((r) => r['name']),
          ['saved_downloads'],
        );
        expect(
          raw.select('SELECT marker FROM saved_downloads').single['marker'],
          'original',
        );
        raw.close();
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );
  test('future schema and damaged v1 never delete existing records', () {
    final temp = Directory.systemTemp.createTempSync('downloader-version-');
    final path = '${temp.path}/db';
    var raw = sqlite3.open(path);
    raw.execute('CREATE TABLE marker (value TEXT)');
    raw.execute("INSERT INTO marker VALUES ('kept')");
    raw.execute('PRAGMA user_version=2');
    raw.close();
    try {
      expect(
        () => AppStore(sqlite3.open(path)),
        throwsA(isA<DownloadValidationException>()),
      );
      raw = sqlite3.open(path);
      expect(raw.select('SELECT value FROM marker').single['value'], 'kept');
      raw.execute('PRAGMA user_version=1');
      raw.close();
      expect(
        () => AppStore(sqlite3.open(path)),
        throwsA(isA<SqliteException>()),
      );
      raw = sqlite3.open(path);
      expect(raw.select('SELECT value FROM marker').single['value'], 'kept');
      raw.close();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
  test(
    'same version cannot change receipt payload through either write path',
    () {
      final changed = task(
        engineReceipt: EngineReceipt.fromJson({
          ...receipt().toJson(),
          'downloadedBytes': 7,
        }),
      );
      final ack = ReceiptAck(key: key, receiptVersion: 1);
      store.transaction((tx) {
        tx.saveTask(task(engineReceipt: receipt()));
        tx.saveAcknowledgement(ack);
      });
      expect(
        () => store.transaction((tx) => tx.saveTask(changed)),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        () => store.transaction((tx) => tx.commitReceipt(changed, ack)),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        store.readTask('task')!.engineReceipt!.downloadedBytes,
        0x100000001,
      );
    },
  );
  test('first forged ack and reuse of retained execution are rejected', () {
    store.transaction((tx) => tx.saveTask(task()));
    expect(
      () => store.transaction(
        (tx) => tx.saveAcknowledgement(
          ReceiptAck(
            key: ExecutionKey(
              taskId: 'forged',
              engineId: 'engine',
              generation: 0,
            ),
            receiptVersion: 9,
          ),
        ),
      ),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(store.readAcknowledgements(), isEmpty);
    store.transaction((tx) {
      tx.saveAcknowledgement(ReceiptAck(key: key, receiptVersion: 1));
      tx.deleteTask('task');
    });
    expect(
      () => store.transaction((tx) => tx.saveTask(task(id: 'forged'))),
      throwsA(isA<DownloadValidationException>()),
    );
  });
  test('rollback failure does not hide original callback error', () {
    final failure = StateError('original failure');
    expect(
      () => store.transaction((tx) {
        db.execute('ROLLBACK');
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(store.readTasks(), isEmpty);
  });
}
