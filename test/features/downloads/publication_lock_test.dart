import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:downloader/features/downloads/data/publication_journal.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> compete(String path, SendPort port) => Isolate.run(() async {
  port.send('waiting');
  await sqliteFileGate(path, () async {
    port.send('entered');
  });
});

void main() {
  test(
    'SQLite async gate excludes another isolate and same-isolate waiter without blocking owner IO',
    () async {
      final root = Directory.systemTemp.createTempSync('publication-gate-');
      final path = '${root.path}/gate.sqlite';
      final entered = Completer<void>();
      final release = Completer<void>();
      final messages = ReceivePort();
      final observed = <String>[];
      final subscription = messages.listen(
        (value) => observed.add(value as String),
      );
      try {
        final owner = sqliteFileGate(path, () async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final port = messages.sendPort;
        final competing = compete(path, port);
        final sameIsolate = sqliteFileGate(path, () async {
          observed.add('same');
        });
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!observed.contains('waiting') &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(observed, ['waiting']);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(observed, ['waiting']);
        release.complete();
        await Future.wait([owner, competing, sameIsolate]);
        await Future<void>.delayed(Duration.zero);
        expect(observed, containsAll(['waiting', 'entered', 'same']));
      } finally {
        if (!release.isCompleted) release.complete();
        await subscription.cancel();
        messages.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'SQLite gate releases its connection after an asynchronous owner failure',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'publication-gate-failure-',
      );
      final path = '${root.path}/gate.sqlite';
      try {
        final failure = StateError('owner failed');
        await expectLater(
          sqliteFileGate<void>(path, () async {
            await Future<void>.delayed(Duration.zero);
            throw failure;
          }),
          throwsA(same(failure)),
        );
        var entered = false;
        await sqliteFileGate(path, () async {
          entered = true;
        }).timeout(const Duration(seconds: 5));
        expect(entered, isTrue);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
