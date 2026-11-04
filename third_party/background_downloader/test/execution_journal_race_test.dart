import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void writer(List<Object> args) async {
  final root = args[0] as String;
  final output = args[1] as SendPort;
  final start = ReceivePort();
  output.send(start.sendPort);
  await start.first;
  final task = DownloadTask(
    taskId: 'race',
    url: 'https://example.org/data',
    filename: 'data',
    metaData: jsonEncode({'executionJournal': root}),
  );
  var success = 0;
  var errors = 0;
  for (var i = 0; i < 100; i++) {
    try {
      ExecutionJournal.record(task, {
        'downloadedBytes': i,
        'payload': '${args[2]}:$i',
      });
      success++;
    } catch (_) {
      errors++;
    }
  }
  output.send([success, errors]);
}

void main() {
  test(
    'diagnostic: concurrent journal writers retain every successful record',
    () async {
      final root = Directory.systemTemp.createTempSync('journal-race-');
      final events = ReceivePort();
      final controls = <SendPort>[];
      var success = 0;
      var errors = 0;
      var finished = 0;
      final done = Completer<void>();
      final subscription = events.listen((message) {
        if (message is SendPort) {
          controls.add(message);
          if (controls.length == 4) {
            for (final port in controls) {
              port.send(true);
            }
          }
        } else {
          success += (message as List)[0] as int;
          errors += message[1] as int;
          if (++finished == 4) done.complete();
        }
      });
      for (var i = 0; i < 4; i++) {
        await Isolate.spawn(writer, [root.path, events.sendPort, i]);
      }
      await done.future.timeout(const Duration(seconds: 30));
      final files = ExecutionJournal.versions(root);
      final records = files.length;
      final snapshots =
          files.map((f) => jsonDecode(f.readAsStringSync()) as Map).toList();
      expect(success, 400);
      expect(errors, 0);
      expect(snapshots.map((r) => r['payload']).toSet().length, 400);
      expect(
        snapshots.map((r) => r['receiptVersion']).toList(),
        List.generate(400, (i) => i + 1),
      );
      // ignore: avoid_print
      print(
        'JOURNAL_RACE successes=$success errors=$errors immutableRecords=$records lost=${success - records}',
      );
      await subscription.cancel();
      events.close();
      root.deleteSync(recursive: true);
      expect(
        records,
        success,
        reason:
            'Each reported durable success requires its own immutable version',
      );
    },
  );
}
