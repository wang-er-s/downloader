import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'task.dart';

/// Private execution protocol. This package never imports application models.
/// One transfer owns each directory; acknowledgements are separate records and
/// cannot overwrite a transfer snapshot. Immutable versions make reads replayable.
class ExecutionJournal {
  static String materialToken(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static Directory? directoryFor(Task task) {
    if (task.metaData.isEmpty) return null;
    final metadata = jsonDecode(task.metaData);
    if (metadata is! Map || metadata['executionJournal'] is! String) {
      return null;
    }
    return Directory(metadata['executionJournal'] as String);
  }

  static Map<String, dynamic>? latest(Directory directory) {
    final files = versions(directory);
    if (files.isEmpty) return null;
    return jsonDecode(files.last.readAsStringSync()) as Map<String, dynamic>;
  }

  static List<File> versions(Directory directory) {
    if (!directory.existsSync()) return [];
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  RegExp(r'^[0-9]+\.json$').hasMatch(f.uri.pathSegments.last),
            )
            .toList();
    files.sort((a, b) => _version(a).compareTo(_version(b)));
    return files;
  }

  static int _version(File f) =>
      int.parse(f.uri.pathSegments.last.split('.').first);

  static void record(Task task, Map<String, dynamic> changes) {
    final directory = directoryFor(task);
    if (directory == null) return;
    directory.createSync(recursive: true);
    writeLocked(directory, () {
      final previous = latest(directory);
      final version = (previous?['receiptVersion'] as int? ?? 0) + 1;
      final record = <String, dynamic>{
        'protocolVersion': 1,
        'task': task.toJson(),
        'downloadedBytes': 0,
        'totalBytes': null,
        ...?previous,
        ...changes,
        'receiptVersion': version,
      };
      // Keep evidence from an interrupted/failed publication. A later retry
      // must not truncate the preceding writer's pending bytes.
      final nonce =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      final temporary = File('${directory.path}/$version.$nonce.pending')
        ..createSync(exclusive: true);
      temporary.writeAsStringSync(jsonEncode(record), flush: true);
      final target = File('${directory.path}/$version.json');
      if (target.existsSync()) {
        throw StateError('Receipt version already exists');
      }
      temporary.renameSync(target.path);
    });
  }

  /// SQLite's process/thread locks serialize distinct isolate connections.
  /// The OS releases them after process death; no lock-file ownership guessing.
  static T writeLocked<T>(Directory directory, T Function() action) {
    directory.createSync(recursive: true);
    final database = sqlite3.open('${directory.path}/writer.sqlite');
    try {
      database.execute('PRAGMA busy_timeout=30000');
      database.execute('BEGIN IMMEDIATE');
      try {
        final result = action();
        database.execute('COMMIT');
        return result;
      } catch (_) {
        try {
          database.execute('ROLLBACK');
        } catch (_) {
          // Preserve the original publication/commit failure.
        }
        rethrow;
      }
    } finally {
      database.close();
    }
  }

  static void reclaim(Directory directory, int acknowledgedVersion) {
    writeLocked(directory, () {
      final files = versions(directory);
      for (final file in files.take(files.isEmpty ? 0 : files.length - 1)) {
        if (_version(file) <= acknowledgedVersion) file.deleteSync();
      }
    });
  }
}
