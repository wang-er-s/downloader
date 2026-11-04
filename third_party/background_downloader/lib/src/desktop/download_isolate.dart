import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'material_digest.dart';
import '../execution_journal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../exceptions.dart';
import '../models.dart';
import '../task.dart';
import '../utils.dart';
import 'desktop_downloader.dart';
import 'isolate.dart';

var taskRangeStartByte = 0; // Start of the Task's download range
String? eTagHeader;
late DownloadTask downloadTask; // global because filename may change

/// Execute the download task
///
/// Sends updates via the [sendPort] and can be commanded to cancel/pause via
/// the [messagesToIsolate] queue
Future<void> doDownloadTask(
  DownloadTask task,
  ResumeData? resumeData,
  bool isResume,
  Duration requestTimeout,
  String? tempFilePathConfig,
  SendPort sendPort,
) async {
  // use downloadTask from here on as a 'global' variable in this isolate,
  // as we may change the filename of the task
  downloadTask = task;
  downloadDigest = null;
  downloadCheckpointFailed = false;
  downloadMaterial = null;
  var filePath = await downloadTask.filePath();
  // tempFilePath is taken from [resumeDataString] if this is a resuming task.
  // Otherwise, it is a generated full path to the temp directory
  final tempFilePath =
      isResume && resumeData != null
          ? resumeData.tempFilepath
          : p.join(
            ExecutionJournal.directoryFor(task)?.path ??
                tempFilePathConfig ??
                (await getTemporaryDirectory()).path,
            'com.bbflight.background_downloader${Random().nextInt(1 << 32).toString()}',
          );
  final requiredStartByte =
      resumeData?.requiredStartByte ?? 0; // start for resume
  final eTag = resumeData?.eTag;
  if (isResume &&
      (!await determineIfResumeIsPossible(tempFilePath, requiredStartByte) ||
          !await materialMatches(task, tempFilePath))) {
    taskException = TaskResumeException('restartRequired: localMaterial');
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
    return;
  }
  final client = DesktopDownloader.httpClientForUrl(downloadTask.url);
  var request = http.Request(
    downloadTask.httpRequestMethod,
    Uri.parse(downloadTask.url),
  );
  request.headers.addAll(downloadTask.headers);
  request.persistentConnection = false;
  if (isResume) {
    final taskRangeHeader = downloadTask.headers['Range'] ?? '';
    final taskRange = parseRange(taskRangeHeader);
    taskRangeStartByte = taskRange.$1;
    final resumeRange = (taskRangeStartByte + requiredStartByte, taskRange.$2);
    final newRangeString = 'bytes=${resumeRange.$1}-${resumeRange.$2 ?? ""}';
    request.headers['Range'] = newRangeString;
    if (eTag != null) request.headers['If-Range'] = eTag;
  }
  if (downloadTask.post case String post) {
    request.body = post;
  }
  var resultStatus = TaskStatus.failed;
  try {
    final response = await client.send(request);
    if (!isCanceled) {
      eTagHeader = response.headers['etag'] ?? response.headers['ETag'];
      final acceptRangesHeader = response.headers['accept-ranges'];
      final serverAcceptsRanges =
          acceptRangesHeader == 'bytes' || response.statusCode == 206;
      var taskCanResume = false;
      if (downloadTask.allowPause) {
        // determine if this task can be paused
        taskCanResume = serverAcceptsRanges;
        sendPort.send(('taskCanResume', taskCanResume));
      }
      if (isResume &&
          (response.statusCode != 206 ||
              eTag == null ||
              !eTag.startsWith('"') ||
              !eTag.endsWith('"') ||
              eTag.startsWith('W/') ||
              eTagHeader != eTag)) {
        throw TaskResumeException('restartRequired: responseOrValidator');
      }
      if (!downloadTask.hasFilename) {
        downloadTask = await taskWithSuggestedFilename(
          downloadTask,
          response.headers,
          true,
        );
        // update the filePath by replacing the last segment with the new filename
        filePath = p.join(p.dirname(filePath), downloadTask.filename);
        log.finest(
          'Suggested filename for taskId ${task.taskId}: ${task.filename}',
        );
      }
      responseHeaders = response.headers;
      responseStatusCode = response.statusCode;
      extractContentType(response.headers);
      if (okResponses.contains(response.statusCode)) {
        resultStatus = await processOkDownloadResponse(
          filePath,
          tempFilePath,
          serverAcceptsRanges,
          taskCanResume,
          isResume,
          requestTimeout,
          response,
          sendPort,
        );
      } else {
        // not an OK response
        responseBody = await responseContent(response);
        if (response.statusCode == 404) {
          resultStatus = TaskStatus.notFound;
        } else {
          taskException = TaskHttpException(
            responseBody?.isNotEmpty == true
                ? responseBody!
                : response.reasonPhrase ?? 'Invalid HTTP Request',
            response.statusCode,
          );
        }
      }
    }
  } catch (e) {
    logError(downloadTask, e.toString());
    setTaskError(e);
  }
  if (isCanceled) {
    // cancellation overrides other results
    resultStatus = TaskStatus.canceled;
  }
  processStatusUpdateInIsolate(downloadTask, resultStatus, sendPort);
}

/// Return true if resume is possible
///
/// Confirms that file at [tempFilePath] exists and its length equals
/// [requiredStartByte]
Future<bool> determineIfResumeIsPossible(
  String tempFilePath,
  int requiredStartByte,
) async {
  if (File(tempFilePath).existsSync()) {
    if (await File(tempFilePath).length() >= requiredStartByte) {
      return true;
    } else {
      log.fine('Partially downloaded file is corrupted, resume not possible');
    }
  } else {
    log.fine('Partially downloaded file not available, resume not possible');
  }
  return false;
}

/// Process response with valid response code
///
/// Performs the actual bytes transfer from response to a temp file,
/// and handles the result of the transfer:
/// - .complete -> copy temp to final file location
/// - .failed -> delete temp file
/// - .paused -> post resume information
Future<TaskStatus> processOkDownloadResponse(
  String filePath,
  String tempFilePath,
  bool serverAcceptsRanges,
  bool taskCanResume,
  bool isResume,
  Duration requestTimeout,
  http.StreamedResponse response,
  SendPort sendPort,
) async {
  // contentLength is extracted from response header, and if not available
  // we attempt to extract from [Task.headers], allowing developer to
  // set the content length if already known
  final contentLength = getContentLength(response.headers, downloadTask);
  if (isResume && !await materialMatches(downloadTask, tempFilePath)) {
    taskException = TaskResumeException('restartRequired: localMaterial');
    return TaskStatus.failed;
  }
  if (isResume && !await prepareResume(response, tempFilePath)) {
    return TaskStatus.failed;
  }
  var resultStatus = TaskStatus.failed;
  var actualTempFilePath = tempFilePath;
  IOSink? outStream;
  // A failed/interrupted prefix copy must not reach the transfer finalizer:
  // it has no authority to authenticate the original uncommitted tail.
  if (isResume && await File(tempFilePath).length() > startByte) {
    actualTempFilePath = await forkCheckpoint(
      downloadTask,
      tempFilePath,
      startByte,
    );
  }
  if (isResume) {
    final journal = ExecutionJournal.directoryFor(downloadTask);
    final expected =
        journal == null
            ? null
            : ExecutionJournal.latest(journal)?['materialHash'];
    if (journal == null) {
      // Preserve upstream non-adapter tasks, which have no material journal.
      final state = MaterialDigest();
      await for (final bytes in File(
        actualTempFilePath,
      ).openRead(0, startByte)) {
        state.add(bytes);
      }
      if (state.length != startByte) {
        throw TaskResumeException('restartRequired: prefixChanged');
      }
      downloadDigest = state;
    } else {
      if (expected is! String) {
        throw TaskResumeException('restartRequired: missingDigest');
      }
      downloadDigest = await MaterialDigest.verify(
        File(actualTempFilePath),
        startByte,
        expected,
      );
      if (downloadDigest == null) {
        throw TaskResumeException('restartRequired: prefixChanged');
      }
    }
  } else {
    downloadDigest = MaterialDigest();
  }
  try {
    // do the actual download
    try {
      Directory(p.dirname(actualTempFilePath)).createSync(recursive: true);
      outStream = File(
        actualTempFilePath,
      ).openWrite(mode: isResume ? FileMode.append : FileMode.write);
    } catch (e) {
      if (!isResume) {
        // Fallback to the target download directory as a hidden file
        final targetDir = p.dirname(filePath);
        Directory(targetDir).createSync(recursive: true);
        actualTempFilePath = p.join(targetDir, '.${p.basename(tempFilePath)}');
        log.info(
          'Standard temporary directory not writeable ($e). '
          'Falling back to target directory temp file: $actualTempFilePath',
        );
        outStream = File(actualTempFilePath).openWrite(mode: FileMode.write);
      } else {
        rethrow;
      }
    }
    if (!isResume) {
      ExecutionJournal.record(downloadTask, {
        'resumeData':
            ResumeData(
              downloadTask,
              actualTempFilePath,
              0,
              eTagHeader,
            ).toJson(),
        'materialHash': downloadDigest!.snapshot(),
      });
    }
    downloadMaterial = File(actualTempFilePath);
    final transferBytesResult = await transferBytes(
      response.stream,
      outStream,
      contentLength,
      downloadTask,
      sendPort,
      requestTimeout,
    );
    switch (transferBytesResult) {
      case TaskStatus.complete:
        // copy file to destination, creating dirs if needed
        try {
          await outStream.flush();
        } catch (_) {
          downloadCheckpointFailed = true;
          rethrow;
        }
        if (downloadDigest!.length != bytesTotal + startByte ||
            File(actualTempFilePath).lengthSync() != downloadDigest!.length) {
          downloadCheckpointFailed = true;
          throw FileSystemException('Completed download length mismatch');
        }
        final dirPath = p.dirname(filePath);
        Directory(dirPath).createSync(recursive: true);
        File(actualTempFilePath).copySync(filePath);
        resultStatus = TaskStatus.complete;

      case TaskStatus.canceled:
        resultStatus = TaskStatus.canceled;

      case TaskStatus.paused:
        // Even an unresumable resource must stop and preserve its bytes.
        resultStatus = TaskStatus.paused;

      case TaskStatus.failed:
        break;

      default:
        throw ArgumentError('Cannot process $transferBytesResult');
    }
  } catch (e) {
    logError(downloadTask, e.toString());
    setTaskError(e);
  } finally {
    try {
      try {
        await outStream?.close();
      } catch (e) {
        setTaskError(e);
        rethrow;
      }
      if (downloadCheckpointFailed) {
        throw FileSystemException(
          'Prior checkpoint failed; retaining authenticated prefix',
        );
      }
      if (resultStatus != TaskStatus.complete) {
        final material = File(actualTempFilePath);
        if (material.existsSync()) {
          final state = downloadDigest;
          if (state == null ||
              state.length != bytesTotal + startByte ||
              material.lengthSync() != state.length) {
            throw FileSystemException('Stopped download length mismatch');
          }
          final offset = state.length;
          final data = ResumeData(
            downloadTask,
            actualTempFilePath,
            offset,
            eTagHeader,
          );
          ExecutionJournal.record(downloadTask, {
            'resumeData': data.toJson(),
            'materialHash': state.snapshot(),
            'downloadedBytes': offset,
          });
          sendPort.send(('resumeData', actualTempFilePath, offset, eTagHeader));
        }
      } else {
        ExecutionJournal.record(downloadTask, {
          'stagingLocation': filePath,
          'downloadedBytes': bytesTotal + startByte,
        });
        File(actualTempFilePath).deleteSync();
      }
    } catch (e) {
      logError(downloadTask, 'Could not persist execution material: $e');
      // Do not publish paused/complete after a failed durable checkpoint.
      rethrow;
    }
  }
  return resultStatus;
}

/// Prepare for resume if possible
///
/// Returns true if task can continue, false if task failed.
/// Validates the requested suffix before opening the original file.
Future<bool> prepareResume(
  http.StreamedResponse response,
  String tempFilePath,
) async {
  final range = response.headers['content-range'];
  if (range == null) {
    log.fine('Could not process partial response Content-Range');
    taskException = TaskResumeException(
      'Could not process partial response Content-Range',
    );
    return false;
  }
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(range);
  final directory = ExecutionJournal.directoryFor(downloadTask);
  final checkpoint =
      directory == null
          ? null
          : ExecutionJournal.latest(directory)?['resumeData'] as Map?;
  final length =
      checkpoint?['requiredStartByte'] as int? ??
      await File(tempFilePath).length();
  if (response.statusCode != 206 || match == null) {
    taskException = TaskResumeException('restartRequired: contentRange');
    return false;
  }
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = int.parse(match.group(3)!);
  final requestedEnd = parseRange(downloadTask.headers['Range'] ?? '').$2;
  final expectedEnd = min(requestedEnd ?? total - 1, total - 1);
  final journal = ExecutionJournal.directoryFor(downloadTask);
  final knownTotal =
      journal == null ? null : ExecutionJournal.latest(journal)?['totalBytes'];
  if ((downloadTask.headers['Range'] == null &&
          knownTotal != null &&
          total != knownTotal) ||
      start != taskRangeStartByte + length ||
      end < start ||
      end != expectedEnd ||
      response.contentLength != end - start + 1) {
    taskException = TaskResumeException('restartRequired: rangeLength');
    return false;
  }
  startByte = length;
  return true;
}

/// Delete the temporary file
void deleteTempFile(String tempFilePath) async {
  try {
    File(tempFilePath).deleteSync();
  } on FileSystemException {
    log.fine('Could not delete temp file $tempFilePath');
  }
}

/// Extract content type from [headers] and set [mimeType] and [charSet]
void extractContentType(Map<String, String> headers) {
  final contentType = headers['content-type'];
  if (contentType != null) {
    final regEx = RegExp(r'(.*);\s*charset\s*=(.*)');
    final match = regEx.firstMatch(contentType);
    if (match != null) {
      mimeType = match.group(1);
      charSet = match.group(2);
    } else {
      mimeType = contentType;
    }
  }
}

Future<bool> materialMatches(Task task, String path) async {
  final directory = ExecutionJournal.directoryFor(task);
  if (directory == null) return true;
  final raw = ExecutionJournal.latest(directory);
  final expected = raw?['materialHash'];
  final resume = raw?['resumeData'] as Map?;
  final offset = resume?['requiredStartByte'] as int?;
  if (expected is! String ||
      offset == null ||
      offset < 0 ||
      !File(path).existsSync() ||
      await File(path).length() < offset) {
    return false;
  }
  return await MaterialDigest.verify(File(path), offset, expected) != null;
}

/// Register every private output before creation. Interrupted copies remain
/// attributable; a retry allocates a new candidate and preserves old evidence.
Future<String> forkCheckpoint(Task task, String source, int offset) async {
  final directory = ExecutionJournal.directoryFor(task);
  if (directory == null) throw TaskResumeException('restartRequired: noOwner');
  final ownedRoot = directory.resolveSymbolicLinksSync();
  final sourceFile = File(source);
  if (FileSystemEntity.typeSync(source, followLinks: false) !=
          FileSystemEntityType.file ||
      sourceFile.parent.resolveSymbolicLinksSync() != ownedRoot) {
    throw TaskResumeException('restartRequired: materialOwnership');
  }
  final operation =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final candidate = File(p.join(ownedRoot, 'recovery-$operation.partial'));
  final raw = ExecutionJournal.latest(directory)!;
  final materials = <String>{
    source,
    ...List<String>.from(raw['ownedMaterials'] as List? ?? []),
  };
  materials.add(candidate.path);
  ExecutionJournal.record(task, {
    'ownedMaterials': materials.toList(),
    'recoveryOperation': {
      'id': operation,
      'source': source,
      'candidate': candidate.path,
      'offset': offset,
      'phase': 'copying',
    },
  });
  candidate.createSync(exclusive: true);
  final output = candidate.openWrite();
  try {
    await output.addStream(sourceFile.openRead(0, offset));
    await output.flush();
  } finally {
    await output.close();
  }
  if (candidate.lengthSync() != offset ||
      !await materialMatches(task, candidate.path)) {
    throw TaskResumeException('restartRequired: prefixChanged');
  }
  final resume = Map<String, dynamic>.from(raw['resumeData'] as Map);
  ExecutionJournal.record(task, {
    'resumeData': {...resume, 'data': candidate.path},
    'recoveryOperation': {
      'id': operation,
      'source': source,
      'candidate': candidate.path,
      'offset': offset,
      'phase': 'ready',
    },
  });
  return candidate.path;
}
