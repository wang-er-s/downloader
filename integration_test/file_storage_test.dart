import 'dart:convert';
import 'dart:io';

import 'package:downloader/features/downloads/data/publication_journal.dart';
import 'package:downloader/features/downloads/domain/download_models.dart';
import 'package:downloader/shared/platform/native_file_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Faults happen AFTER the real native operation has returned. All filesystem
/// calls still cross the actual platform channel, including recovery queries.
class InterruptedChannel extends MethodChannel {
  InterruptedChannel(this.interrupt) : super('downloader/file_storage');
  String? interrupt;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final value = await super.invokeMethod<T>(method, arguments);
    if (method == interrupt) {
      interrupt = null;
      throw PlatformException(code: 'fileWriteFailure');
    }
    return value;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('downloader/file_storage');
  late Directory root;
  late DirectoryLocation directory;
  late Directory target;
  late SqlitePublicationJournal journal;
  late NativeFileStorage storage;
  var failReceipt = false;
  var receipts = 0;

  SqlitePublicationJournal openJournal() => SqlitePublicationJournal(
    directory: Directory('${root.path}/journal'),
    resolveSource: (operation) async {
      final expected = File('${root.path}/source');
      if (operation.sourceRef != expected.path || operation.sourceLength != expected.lengthSync()) storageFailure(FailureCode.stateConflict);
      return expected.path;
    },
    commitPublished: (operation, file) async {
      if (failReceipt) storageFailure(FailureCode.persistenceFailure);
      receipts++;
    },
  );

  PublishOperation operation(String id, {String name = '结果.txt', String? source, int? length}) => PublishOperation(
    operationId: id,
    key: ExecutionKey(taskId: id, engineId: id, generation: 0),
    sourceRef: source ?? '${root.path}/source',
    sourceLength: length ?? File('${root.path}/source').lengthSync(),
    directory: directory,
    temporaryName: '.downloader-$id.pending',
    candidateName: name,
    phase: PublishPhase.prepared,
  );

  Matcher code(FailureCode expected) => isA<FileStorageException>().having((e) => e.failure.code, 'failure', expected);

  setUp(() async {
    root = await (await getApplicationSupportDirectory()).createTemp('storage-integration-');
    File('${root.path}/source').writeAsBytesSync(List<int>.generate(1024 * 1024 + 13, (i) => i % 251), flush: true);
    directory = DirectoryLocation(platform: DownloadPlatform.macos, kind: DirectoryKind.systemDownloads, subdirectory: 'test-${root.uri.pathSegments.where((s) => s.isNotEmpty).last}', displayName: 'Downloader');
    final resolved = jsonObject(await channel.invokeMethod('resolveDirectory', {'directory': directory.toJson()}));
    target = Directory(resolved['locator'] as String);
    // The production resolver must use the user's Downloads, never a private
    // sandbox fallback. Resolve the entitlement's Downloads symlink as well.
    final system = (await getDownloadsDirectory())!;
    expect(target.resolveSymbolicLinksSync(), startsWith('${system.resolveSymbolicLinksSync()}/Downloader/'));
    failReceipt = false; receipts = 0;
    journal = openJournal(); storage = NativeFileStorage(journal: journal);
  });
  tearDown(() {
    journal.close();
    if (target.existsSync()) target.deleteSync(recursive: true);
    root.deleteSync(recursive: true);
  });

  testWidgets('real default directory, concurrent collision, close, complete bytes, source retained, conservative deletion', (_) async {
    final foreign = File('${target.path}/结果.txt')..writeAsStringSync('foreign');
    final files = await Future.wait([storage.publish(operation('one')), storage.publish(operation('two'))]);
    expect(files.map((f) => f.locator).toSet(), hasLength(2));
    expect(foreign.readAsStringSync(), 'foreign');
    for (final file in files) {
      expect(File(file.locator).readAsBytesSync(), File('${root.path}/source').readAsBytesSync());
      expect(file.identity, isNotEmpty);
      await expectLater(storage.deleteOwned(file), throwsA(code(FailureCode.cleanupFailure)));
      expect(File(file.locator).existsSync(), isTrue);
    }
    expect(target.listSync(), hasLength(5));
    expect(File('${root.path}/source').existsSync(), isTrue);
  });

  testWidgets('create response lost: reopen preserves uncertain and never creates twice or claims foreign name', (_) async {
    final op = operation('create-fault');
    storage = NativeFileStorage(journal: journal, channel: InterruptedChannel('create'));
    await expectLater(storage.publish(op), throwsA(code(FailureCode.fileWriteFailure)));
    expect(journal.read(op.operationId)!['phase'], 'creating');
    final before = target.listSync().map((f) => f.path).toList();
    journal.close(); journal = openJournal(); storage = NativeFileStorage(journal: journal);
    expect((await storage.recoverPublication(op)).disposition, PublishDisposition.uncertain);
    await expectLater(storage.publish(op), throwsA(code(FailureCode.publicationUncertain)));
    expect(target.listSync().map((f) => f.path).toList(), before);
    expect(File('${root.path}/source').existsSync(), isTrue);
  });

  testWidgets('final creation response lost: query is read-only and reopen refuses a second target', (_) async {
    final op = operation('final-fault');
    storage = NativeFileStorage(journal: journal, channel: InterruptedChannel('publish'));
    await expectLater(storage.publish(op), throwsA(code(FailureCode.fileWriteFailure)));
    final before = target.listSync().map((f) => f.path).toList()..sort();
    final persisted = jsonEncode(journal.read(op.operationId));
    expect((await storage.recoverPublication(op)).disposition, PublishDisposition.uncertain);
    expect(jsonEncode(journal.read(op.operationId)), persisted);
    expect((target.listSync().map((f) => f.path).toList()..sort()), before);
    journal.close(); journal = openJournal(); storage = NativeFileStorage(journal: journal);
    await expectLater(storage.publish(op), throwsA(code(FailureCode.publicationUncertain)));
    expect(target.listSync(), hasLength(2));
    expect(receipts, 0);
  });

  testWidgets('receipt commit failure keeps published identity; reopened explicit retry only reconciles', (_) async {
    final op = operation('receipt-fault'); failReceipt = true;
    await expectLater(storage.publish(op), throwsA(code(FailureCode.persistenceFailure)));
    final original = journal.read(op.operationId)!;
    expect(original['phase'], 'published');
    expect((await storage.recoverPublication(op)).disposition, PublishDisposition.published);
    journal.close(); journal = openJournal(); storage = NativeFileStorage(journal: journal); failReceipt = false;
    final file = await storage.publish(op);
    expect(file.identity, jsonObject(original['file'])['identity']);
    expect(target.listSync(), hasLength(2));
    expect(receipts, 1);
  });

  testWidgets('foreign replacement and symlink are not owned, not opened or deleted', (_) async {
    final op = operation('replaced'); final file = await storage.publish(op);
    File(file.locator).deleteSync();
    File(file.locator).writeAsStringSync('foreign replacement');
    expect((await storage.recoverPublication(op)).disposition, PublishDisposition.uncertain);
    await expectLater(storage.deleteOwned(file), throwsA(isA<FileStorageException>()));
    expect(File(file.locator).readAsStringSync(), 'foreign replacement');
    File(file.locator).deleteSync();
    Link(file.locator).createSync('${root.path}/source');
    await expectLater(storage.deleteOwned(file), throwsA(isA<FileStorageException>()));
    expect(File('${root.path}/source').existsSync(), isTrue);
  });

  testWidgets('source gate, payload conflict, unknown SQLite version, and missing file errors', (_) async {
    await expectLater(storage.publish(operation('forged', source: '${root.path}/arbitrary')), throwsA(code(FailureCode.stateConflict)));
    await expectLater(storage.publish(operation('length', length: 1)), throwsA(code(FailureCode.stateConflict)));
    expect(target.listSync(), isEmpty);
    final op = operation('missing'); final file = await storage.publish(op);
    await expectLater(storage.publish(operation('missing', name: 'other.txt')), throwsA(code(FailureCode.stateConflict)));
    File(file.locator).deleteSync();
    await expectLater(storage.open(file), throwsA(code(FailureCode.fileMissing)));
    await expectLater(storage.deleteOwned(file), throwsA(code(FailureCode.cleanupFailure)));
    final futureRoot = Directory('${root.path}/future')..createSync();
    final futureDb = sqlite3.open('${futureRoot.path}/publications.sqlite');
    futureDb.execute('PRAGMA user_version=99');
    futureDb.close();
    expect(() => SqlitePublicationJournal(directory: futureRoot, resolveSource: (_) async => '', commitPublished: (_, _) async {}), throwsA(code(FailureCode.protocolMismatch)));
    final reopened = sqlite3.open('${futureRoot.path}/publications.sqlite');
    expect(reopened.select('PRAGMA user_version').single.values.single, 99);
    reopened.close();
  });

  testWidgets('uncertain cleanup preserves full source and target; published cleanup never deletes user file', (_) async {
    final uncertain = operation('uncertain-cleanup');
    final source = File('${root.path}/source').readAsBytesSync();
    storage = NativeFileStorage(journal: journal, channel: InterruptedChannel('create'));
    await expectLater(storage.publish(uncertain), throwsA(code(FailureCode.fileWriteFailure)));
    await expectLater(storage.cleanupPublication(uncertain), throwsA(code(FailureCode.cleanupFailure)));
    expect(() => journal.assertPrivateCleanupAllowed(uncertain.key), throwsA(code(FailureCode.cleanupFailure)));
    expect(File('${root.path}/source').readAsBytesSync(), source);
    expect(target.listSync(), hasLength(1));
    final completed = operation('published-cleanup');
    final file = await storage.publish(completed);
    await expectLater(storage.cleanupPublication(completed), throwsA(code(FailureCode.cleanupFailure)));
    expect(File(file.locator).readAsBytesSync(), source);
  });

  testWidgets('existing staged cleanup is refused; missing target can reconcile a failed cleaned commit', (_) async {
    final op = operation('cleanup-commit');
    storage = NativeFileStorage(journal: journal, channel: InterruptedChannel('copy'));
    await expectLater(storage.publish(op), throwsA(code(FailureCode.fileWriteFailure)));
    await expectLater(storage.cleanupPublication(op), throwsA(code(FailureCode.cleanupFailure)));
    expect(target.listSync(), hasLength(1));
    // An external owner explicitly removed the fixture; production never unlinks.
    target.listSync().single.deleteSync();
    final db = sqlite3.open('${root.path}/journal/publications.sqlite');
    db.execute("CREATE TRIGGER clean_failure BEFORE UPDATE ON publications WHEN json_extract(NEW.record,'\$.phase')='cleaned' BEGIN SELECT RAISE(ABORT,'injected'); END");
    final source = File('${root.path}/source').readAsBytesSync();
    await expectLater(storage.cleanupPublication(op), throwsA(code(FailureCode.persistenceFailure)));
    expect(target.listSync(), isEmpty);
    expect(journal.read(op.operationId)!['phase'], 'cleaning');
    expect(() => journal.assertPrivateCleanupAllowed(op.key), throwsA(code(FailureCode.cleanupFailure)));
    db.execute('DROP TRIGGER clean_failure'); db.close();
    journal.close(); journal = openJournal(); storage = NativeFileStorage(journal: journal);
    await storage.cleanupPublication(op);
    journal.assertPrivateCleanupAllowed(op.key);
    expect(journal.read(op.operationId)!['phase'], 'cleaned');
    await expectLater(storage.publish(op), throwsA(code(FailureCode.stateConflict)));
    expect(target.listSync(), isEmpty);
    expect(File('${root.path}/source').readAsBytesSync(), source);
  });

  testWidgets('publication and cleanup share serialization; completed publication cannot be deleted by queued cleanup', (_) async {
    final op = operation('serialized');
    final publication = storage.publish(op);
    final cleanup = expectLater(storage.cleanupPublication(op), throwsA(code(FailureCode.cleanupFailure)));
    final file = await publication; await cleanup;
    expect(File(file.locator).existsSync(), isTrue);
    expect(journal.read(op.operationId)!['phase'], 'published');
    expect(File('${root.path}/source').existsSync(), isTrue);
  });
}
