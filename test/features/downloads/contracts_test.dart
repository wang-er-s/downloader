import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/features/saved_downloads/domain/saved_download.dart';
import 'package:downloader/features/settings/domain/app_settings.dart';
import 'fixtures.dart';

void main() {
  test(
    'cached names use safe decoded URL paths without changing saved input',
    () {
      for (final entry in {
        'https://example.com/files/app.apk?token=secret#part': 'app.apk',
        'https://example.com/files/%E4%B8%8B%E8%BD%BD.apk': '下载.apk',
        'https://example.com/': 'download_cache',
        'https://example.com/files/': 'download_cache',
        'https://example.com/a%2Fb.apk': 'download_cache',
        'https://example.com/CON.txt': 'download_cache',
        'https://example.com/%ZZ': '%ZZ',
      }.entries) {
        final value = SavedDownload(
          id: 'cache',
          url: entry.key,
          createdAt: now,
          updatedAt: now,
        );
        expect(value.displayName, entry.value);
        expect(value.fileName, isNull);
        expect(SavedDownload.fromJson(value.toJson()).displayName, entry.value);
      }
      expect(
        SavedDownload(
          id: 'cache',
          url: 'https://example.com/a.apk',
          fileName: 'custom.apk',
          createdAt: now,
          updatedAt: now,
        ).displayName,
        'custom.apk',
      );
    },
  );
  for (final url in [
    '',
    'file:///tmp/a',
    'https://',
    'https://u:p@example.com',
    'https://@example.com',
    'https://example.com/a\n',
    'https://example.com/a b',
  ]) {
    test('reject invalid URL ${jsonEncode(url)}', () {
      // Surrounding whitespace is intentionally normalized, including newlines.
      if (url == 'https://example.com/a\n') {
        expect(downloadUrl(url), 'https://example.com/a');
      } else {
        expect(
          () => CreateDownload(requestId: 'r', url: url),
          throwsA(isA<DownloadValidationException>()),
        );
      }
    });
  }
  test('URL normalized, optional name and directory preserved', () {
    final value = CreateDownload(
      requestId: 'r',
      url: '  https://example.com/a  ',
    );
    expect(value.url, 'https://example.com/a');
    expect(value.directory, isNull);
    expect(value.fileName, isNull);
  });
  for (final name in [
    '..',
    '.',
    '../evil',
    'a/b',
    r'a\b',
    'a\u0000b',
    'CON.txt',
    'LPT9',
    'a?',
    'a.',
    'a ',
    '',
  ]) {
    test('reject unsafe filename ${jsonEncode(name)}', () {
      expect(() => fileName(name), throwsA(isA<DownloadValidationException>()));
    });
  }
  test('all domain models round trip with nullable unknown total', () {
    final failure = DownloadFailure(
      code: FailureCode.restartRequired,
      message: '需要确认重新下载',
      details: {
        'nested': [
          1,
          {'reason': 'changed'},
        ],
      },
    );
    final models =
        <(Map<String, Object?>, Object Function(Map<String, Object?>))>[
          (directory.toJson(), DirectoryLocation.fromJson),
          (location.toJson(), FileLocation.fromJson),
          (key.toJson(), ExecutionKey.fromJson),
          (command.toJson(), EngineCommand.fromJson),
          (publication.toJson(), PublishOperation.fromJson),
          (
            PublishRecovery(disposition: PublishDisposition.uncertain).toJson(),
            PublishRecovery.fromJson,
          ),
          (receipt().toJson(), EngineReceipt.fromJson),
          (
            ReceiptAck(key: key, receiptVersion: 1).toJson(),
            ReceiptAck.fromJson,
          ),
          (
            EngineSnapshot(ownerSessionId: 'session', sequence: 0).toJson(),
            EngineSnapshot.fromJson,
          ),
          (
            EngineTask(
              key: key,
              url: 'http://example.com',
              directory: directory,
              stagingLocation: 'private',
            ).toJson(),
            EngineTask.fromJson,
          ),
          (
            EngineEvent(
              ownerSessionId: 'session',
              sequence: 1,
              key: key,
              downloadedBytes: 19,
              sampleMonotonicMs: 10,
            ).toJson(),
            EngineEvent.fromJson,
          ),
          (
            CreateDownload(requestId: 'r', url: 'https://example.com').toJson(),
            CreateDownload.fromJson,
          ),
          (
            task(engineReceipt: receipt(), fileLocation: location).toJson(),
            DownloadTask.fromJson,
          ),
          (failure.toJson(), DownloadFailure.fromJson),
          (
            SavedDownloadInput(id: 's', url: 'https://example.com').toJson(),
            SavedDownloadInput.fromJson,
          ),
          (
            SavedDownload(
              id: 's',
              url: 'https://example.com',
              createdAt: now,
              updatedAt: now,
            ).toJson(),
            SavedDownload.fromJson,
          ),
          (
            AppSettings(defaultDirectory: directory).toJson(),
            AppSettings.fromJson,
          ),
        ];
    for (final (json, decode) in models) {
      final decoded = decode(jsonObject(jsonDecode(jsonEncode(json))));
      expect(jsonEncode((decoded as dynamic).toJson()), jsonEncode(json));
      final versionKey = json.containsKey('protocolVersion')
          ? 'protocolVersion'
          : 'version';
      expect(
        () => decode({...json, versionKey: 99}),
        throwsA(isA<DownloadValidationException>()),
      );
      expect(
        () => decode({...json, versionKey: 1.0}),
        throwsA(isA<DownloadValidationException>()),
      );
    }
    expect(task().downloadedBytes, greaterThan(0xffffffff));
    expect(task().totalBytes, isNull);
    expect(task().progress, isNull);
    expect(AppSettings(defaultDirectory: directory).theme, AppTheme.system);
  });
  test('empty snapshot retains session, independent byte events grow', () {
    final snapshot = EngineSnapshot(ownerSessionId: 'new-session', sequence: 0);
    expect(snapshot.ownerSessionId, 'new-session');
    expect(snapshot.receipts, isEmpty);
    for (final bytes in [1, 100, 0x100000001]) {
      final event = EngineEvent(
        ownerSessionId: 's',
        sequence: bytes,
        key: key,
        downloadedBytes: bytes,
        sampleMonotonicMs: bytes,
      );
      expect(event.downloadedBytes, bytes);
      expect(event.totalBytes, isNull);
    }
  });
  test(
    'collections, nested details and serialized boundaries are immutable',
    () {
      final refs = ['old'];
      final ack = ReceiptAck(
        key: key,
        receiptVersion: 1,
        releaseResumeRefs: refs,
      );
      refs.add('new');
      expect(ack.releaseResumeRefs, ['old']);
      expect(() => ack.releaseResumeRefs.add('x'), throwsUnsupportedError);
      expect(
        () => (ack.toJson()['releaseResumeRefs'] as List).add('x'),
        throwsUnsupportedError,
      );
      final nested = <String, Object?>{
        'array': [
          <String, Object?>{'value': 1},
        ],
      };
      final error = DownloadFailure(
        code: FailureCode.httpFailure,
        message: '失败',
        details: nested,
      );
      ((nested['array'] as List).first as Map)['value'] = 9;
      final details = error.details!;
      expect(((details['array'] as List).first as Map)['value'], 1);
      expect(
        () => ((details['array'] as List).first as Map)['value'] = 2,
        throwsUnsupportedError,
      );
      final receipts = [receipt()];
      final snapshot = EngineSnapshot(
        ownerSessionId: 's',
        sequence: 1,
        receipts: receipts,
      );
      receipts.clear();
      expect(snapshot.receipts, hasLength(1));
      expect(() => snapshot.receipts.clear(), throwsUnsupportedError);
    },
  );
  test('64-bit counters reject negatives and DTO types', () {
    expect(unsigned64(0x7fffffffffffffff), 0x7fffffffffffffff);
    expect(() => unsigned64(-1), throwsA(isA<DownloadValidationException>()));
    expect(
      () => ExecutionKey(taskId: 't', engineId: 'e', generation: -1),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => ReceiptAck(key: key, receiptVersion: 0),
      throwsA(isA<DownloadValidationException>()),
    );
    for (final value in [-1, 1.5, '10', true]) {
      expect(
        () => EngineReceipt.fromJson({
          ...receipt().toJson(),
          'downloadedBytes': value,
        }),
        throwsA(isA<DownloadValidationException>()),
      );
    }
    expect(
      () => EngineReceipt.fromJson({...receipt().toJson(), 'totalBytes': -1}),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => EngineSnapshot.fromJson({
        'protocolVersion': 1,
        'ownerSessionId': 's',
        'sequence': 0,
        'receipts': {},
      }),
      throwsA(isA<DownloadValidationException>()),
    );
  });
  test('unknown enum and mismatched nested execution are rejected', () {
    expect(
      () => DownloadTask.fromJson({...task().toJson(), 'status': 'future'}),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => DownloadFailure.fromJson({
        'version': 1,
        'code': 'future',
        'message': '失败',
      }),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => EngineReceipt.fromJson({
        ...receipt().toJson(),
        'resumeSupport': 'future',
      }),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => AppSettings.fromJson({
        ...AppSettings(defaultDirectory: directory).toJson(),
        'theme': 'future',
      }),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      () => task(id: 'other', engineReceipt: receipt()),
      throwsA(isA<DownloadValidationException>()),
    );
    expect(
      key,
      ExecutionKey(taskId: 'task', engineId: 'engine', generation: 0),
    );
    expect(
      key,
      isNot(ExecutionKey(taskId: 'task', engineId: 'engine', generation: 1)),
    );
  });
  test('directory/file kind, platform, locator and traversal validation', () {
    for (final mutation in [
      {'version': 2},
      {'platform': 'linux'},
      {'kind': 'future'},
      {'platform': 'ios'},
      {'subdirectory': '../escape'},
      {'kind': 'userSelected', 'locator': null},
      {'platform': 'android', 'kind': 'userSelected', 'locator': '/tmp'},
      {'platform': 'windows', 'kind': 'userSelected', 'locator': 'relative'},
    ]) {
      expect(
        () => DirectoryLocation.fromJson({...directory.toJson(), ...mutation}),
        throwsA(isA<DownloadValidationException>()),
      );
    }
    for (final mutation in [
      {'kind': 'future'},
      {'platform': 'linux'},
      {'locator': 'relative'},
      {'kind': 'contentUri'},
      {'platform': 'windows', 'kind': 'bookmark'},
    ]) {
      expect(
        () => FileLocation.fromJson({...location.toJson(), ...mutation}),
        throwsA(isA<DownloadValidationException>()),
      );
    }
    expect(
      FileLocation(
        platform: DownloadPlatform.windows,
        kind: FileKind.path,
        locator: r'C:\Users\测试\file.bin',
      ).toJson()['version'],
      1,
    );
    expect(
      () => PublishRecovery(disposition: PublishDisposition.published),
      throwsA(isA<DownloadValidationException>()),
    );
  });
  test('domain imports remain pure Dart', () {
    for (final root in [
      'lib/features/downloads/domain',
      'lib/features/saved_downloads/domain',
      'lib/features/settings/domain',
    ]) {
      for (final file in Directory(root).listSync().whereType<File>()) {
        expect(
          file.readAsStringSync(),
          isNot(
            matches(
              r"import .*package:(flutter|riverpod|sqlite3|path_provider)",
            ),
          ),
        );
      }
    }
  });
}
