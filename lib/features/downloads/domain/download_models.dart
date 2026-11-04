import 'validation.dart';
export 'validation.dart';

enum DownloadPlatform { android, ios, macos, windows }

enum DirectoryKind { systemDownloads, appDocuments, userSelected }

// File locators are opaque to business consumers; identity is separate proof.
enum FileKind { path, contentUri, bookmark }

enum DownloadStatus {
  queued,
  running,
  paused,
  waitingRecovery,
  publishing,
  failed,
  completed,
  cancelling,
  deleting,
}

enum ResumeSupport { unknown, supported, unsupported }

enum PublishPhase { prepared, creating, copying, finalizing, published }

enum PublishDisposition {
  notCreated,
  staged,
  published,
  needsPermission,
  uncertain,
}

String validateFileName(String value) => fileName(value);

final class DirectoryLocation {
  DirectoryLocation({
    required this.platform,
    required this.kind,
    this.locator,
    this.subdirectory,
    required String displayName,
  }) : displayName = nonEmpty(displayName) {
    if (kind == DirectoryKind.systemDownloads &&
        platform == DownloadPlatform.ios) {
      invalid();
    }
    if (kind == DirectoryKind.appDocuments &&
        platform != DownloadPlatform.ios) {
      invalid();
    }
    if (kind == DirectoryKind.userSelected) {
      if (locator == null) invalid();
      nonEmpty(locator!);
      if (platform == DownloadPlatform.android &&
          Uri.tryParse(locator!)?.scheme != 'content') {
        invalid();
      }
      if (platform == DownloadPlatform.windows &&
          !RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(locator!)) {
        invalid();
      }
    } else if (locator != null) {
      invalid();
    }
    if (subdirectory != null) fileName(subdirectory!);
  }

  final DownloadPlatform platform;
  final DirectoryKind kind;
  final String? locator;
  final String? subdirectory;
  final String displayName;

  factory DirectoryLocation.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return DirectoryLocation(
      platform: jsonEnum(DownloadPlatform.values, json['platform']),
      kind: jsonEnum(DirectoryKind.values, json['kind']),
      locator: jsonOptional<String>(json, 'locator'),
      subdirectory: jsonOptional<String>(json, 'subdirectory'),
      displayName: jsonValue<String>(json, 'displayName'),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'platform': platform.name,
            'kind': kind.name,
            'locator': locator,
            'subdirectory': subdirectory,
            'displayName': displayName,
          })
          as Map<String, Object?>;
}

final class FileLocation {
  FileLocation({
    required this.platform,
    required this.kind,
    required String locator,
    this.identity,
  }) : locator = nonEmpty(locator) {
    if (identity != null) nonEmpty(identity!);
    if (kind == FileKind.contentUri) {
      if (platform != DownloadPlatform.android ||
          Uri.tryParse(locator)?.scheme != 'content') {
        invalid();
      }
    } else if (kind == FileKind.bookmark) {
      if (platform != DownloadPlatform.ios &&
          platform != DownloadPlatform.macos) {
        invalid();
      }
    } else {
      final absolute = platform == DownloadPlatform.windows
          ? RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(locator)
          : locator.startsWith('/');
      if (!absolute) invalid();
    }
  }

  final DownloadPlatform platform;
  final FileKind kind;
  final String locator;
  final String? identity;

  factory FileLocation.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return FileLocation(
      platform: jsonEnum(DownloadPlatform.values, json['platform']),
      kind: jsonEnum(FileKind.values, json['kind']),
      locator: jsonValue<String>(json, 'locator'),
      identity: jsonOptional<String>(json, 'identity'),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'platform': platform.name,
            'kind': kind.name,
            'locator': locator,
            'identity': identity,
          })
          as Map<String, Object?>;
}

final class DownloadFailure {
  DownloadFailure({
    required this.code,
    required String message,
    this.taskId,
    Map<String, Object?>? details,
  }) : message = nonEmpty(message),
       details = details == null
           ? null
           : freezeJson(details) as Map<String, Object?>;

  final FailureCode code;
  final String message;
  final String? taskId;
  final Map<String, Object?>? details;

  factory DownloadFailure.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return DownloadFailure(
      code: jsonEnum(FailureCode.values, json['code']),
      message: jsonValue<String>(json, 'message'),
      taskId: jsonOptional<String>(json, 'taskId'),
      details: json['details'] == null ? null : jsonObject(json['details']),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'code': code.name,
            'message': message,
            'taskId': taskId,
            'details': details,
          })
          as Map<String, Object?>;
}

final class ExecutionKey {
  ExecutionKey({
    required String taskId,
    required String engineId,
    required int generation,
  }) : taskId = nonEmpty(taskId),
       engineId = nonEmpty(engineId),
       generation = unsigned64(generation);

  final String taskId;
  final String engineId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is ExecutionKey &&
      taskId == other.taskId &&
      engineId == other.engineId &&
      generation == other.generation;
  @override
  int get hashCode => Object.hash(taskId, engineId, generation);

  factory ExecutionKey.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return ExecutionKey(
      taskId: jsonValue<String>(json, 'taskId'),
      engineId: jsonValue<String>(json, 'engineId'),
      generation: jsonValue<int>(json, 'generation'),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'taskId': taskId,
            'engineId': engineId,
            'generation': generation,
          })
          as Map<String, Object?>;
}

final class EngineCommand {
  EngineCommand({
    required String commandId,
    required this.key,
    required String ownerSessionId,
    required int expectedReceiptVersion,
  }) : commandId = nonEmpty(commandId),
       ownerSessionId = nonEmpty(ownerSessionId),
       expectedReceiptVersion = unsigned64(expectedReceiptVersion);

  final String commandId;
  final ExecutionKey key;
  final String ownerSessionId;
  final int expectedReceiptVersion;

  factory EngineCommand.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return EngineCommand(
      commandId: jsonValue<String>(json, 'commandId'),
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      ownerSessionId: jsonValue<String>(json, 'ownerSessionId'),
      expectedReceiptVersion: jsonValue<int>(json, 'expectedReceiptVersion'),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'commandId': commandId,
            'key': key.toJson(),
            'ownerSessionId': ownerSessionId,
            'expectedReceiptVersion': expectedReceiptVersion,
          })
          as Map<String, Object?>;
}

final class PublishOperation {
  PublishOperation({
    required String operationId,
    required this.key,
    required String sourceRef,
    required int sourceLength,
    required this.directory,
    required String temporaryName,
    required String candidateName,
    required this.phase,
    this.targetRef,
    this.identity,
    this.error,
  }) : operationId = nonEmpty(operationId),
       sourceRef = nonEmpty(sourceRef),
       sourceLength = unsigned64(sourceLength),
       temporaryName = fileName(temporaryName),
       candidateName = fileName(candidateName) {
    if (!temporaryName.contains(operationId)) invalid();
    if (targetRef != null) nonEmpty(targetRef!);
    if (identity != null) nonEmpty(identity!);
  }

  final String operationId;
  final ExecutionKey key;
  final String sourceRef;
  final int sourceLength;
  final DirectoryLocation directory;
  final String temporaryName;
  final String candidateName;
  final PublishPhase phase;
  final String? targetRef;
  final String? identity;
  final DownloadFailure? error;

  factory PublishOperation.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return PublishOperation(
      operationId: jsonValue<String>(json, 'operationId'),
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      sourceRef: jsonValue<String>(json, 'sourceRef'),
      sourceLength: jsonValue<int>(json, 'sourceLength'),
      directory: DirectoryLocation.fromJson(jsonObject(json['directory'])),
      temporaryName: jsonValue<String>(json, 'temporaryName'),
      candidateName: jsonValue<String>(json, 'candidateName'),
      phase: jsonEnum(PublishPhase.values, json['phase']),
      targetRef: jsonOptional<String>(json, 'targetRef'),
      identity: jsonOptional<String>(json, 'identity'),
      error: json['error'] == null
          ? null
          : DownloadFailure.fromJson(jsonObject(json['error'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'operationId': operationId,
            'key': key.toJson(),
            'sourceRef': sourceRef,
            'sourceLength': sourceLength,
            'directory': directory.toJson(),
            'temporaryName': temporaryName,
            'candidateName': candidateName,
            'phase': phase.name,
            'targetRef': targetRef,
            'identity': identity,
            'error': error?.toJson(),
          })
          as Map<String, Object?>;
}

final class PublishRecovery {
  PublishRecovery({required this.disposition, this.ownedLocation}) {
    if ((disposition == PublishDisposition.staged ||
            disposition == PublishDisposition.published) &&
        ownedLocation == null) {
      invalid();
    }
    if (disposition == PublishDisposition.notCreated && ownedLocation != null) {
      invalid();
    }
  }

  final PublishDisposition disposition;
  final FileLocation? ownedLocation;

  factory PublishRecovery.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return PublishRecovery(
      disposition: jsonEnum(PublishDisposition.values, json['disposition']),
      ownedLocation: json['ownedLocation'] == null
          ? null
          : FileLocation.fromJson(jsonObject(json['ownedLocation'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'disposition': disposition.name,
            'ownedLocation': ownedLocation?.toJson(),
          })
          as Map<String, Object?>;
}

final class EngineReceipt {
  EngineReceipt({
    required this.key,
    required int receiptVersion,
    required this.state,
    required int downloadedBytes,
    this.totalBytes,
    required this.resumeSupport,
    this.resumeRef,
    this.stagingLocation,
    this.publishOperation,
    this.publishedLocation,
    this.error,
  }) : receiptVersion = unsigned64(receiptVersion, positive: true),
       downloadedBytes = unsigned64(downloadedBytes) {
    if (totalBytes != null) unsigned64(totalBytes!);
    if (resumeRef != null) nonEmpty(resumeRef!);
    if (stagingLocation != null) nonEmpty(stagingLocation!);
    if (publishOperation != null && publishOperation!.key != key) invalid();
  }

  final ExecutionKey key;
  final int receiptVersion;
  final DownloadStatus state;
  final int downloadedBytes;
  final int? totalBytes;
  final ResumeSupport resumeSupport;
  final String? resumeRef;
  final String? stagingLocation;
  final PublishOperation? publishOperation;
  final FileLocation? publishedLocation;
  final DownloadFailure? error;

  factory EngineReceipt.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return EngineReceipt(
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      receiptVersion: jsonValue<int>(json, 'receiptVersion'),
      state: jsonEnum(DownloadStatus.values, json['state']),
      downloadedBytes: jsonValue<int>(json, 'downloadedBytes'),
      totalBytes: jsonOptional<int>(json, 'totalBytes'),
      resumeSupport: jsonEnum(ResumeSupport.values, json['resumeSupport']),
      resumeRef: jsonOptional<String>(json, 'resumeRef'),
      stagingLocation: jsonOptional<String>(json, 'stagingLocation'),
      publishOperation: json['publishOperation'] == null
          ? null
          : PublishOperation.fromJson(jsonObject(json['publishOperation'])),
      publishedLocation: json['publishedLocation'] == null
          ? null
          : FileLocation.fromJson(jsonObject(json['publishedLocation'])),
      error: json['error'] == null
          ? null
          : DownloadFailure.fromJson(jsonObject(json['error'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'key': key.toJson(),
            'receiptVersion': receiptVersion,
            'state': state.name,
            'downloadedBytes': downloadedBytes,
            'totalBytes': totalBytes,
            'resumeSupport': resumeSupport.name,
            'resumeRef': resumeRef,
            'stagingLocation': stagingLocation,
            'publishOperation': publishOperation?.toJson(),
            'publishedLocation': publishedLocation?.toJson(),
            'error': error?.toJson(),
          })
          as Map<String, Object?>;
}

final class ReceiptAck {
  ReceiptAck({
    required this.key,
    required int receiptVersion,
    List<String> releaseResumeRefs = const [],
  }) : receiptVersion = unsigned64(receiptVersion, positive: true),
       releaseResumeRefs = List.unmodifiable(releaseResumeRefs) {
    for (final ref in releaseResumeRefs) {
      nonEmpty(ref);
    }
  }

  final ExecutionKey key;
  final int receiptVersion;
  final List<String> releaseResumeRefs;

  factory ReceiptAck.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return ReceiptAck(
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      receiptVersion: jsonValue<int>(json, 'receiptVersion'),
      releaseResumeRefs: jsonValue<List>(json, 'releaseResumeRefs')
          .map(
            (item) =>
                item is String ? item : invalid(FailureCode.protocolMismatch),
          )
          .toList(),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'key': key.toJson(),
            'receiptVersion': receiptVersion,
            'releaseResumeRefs': releaseResumeRefs,
          })
          as Map<String, Object?>;
}

final class EngineSnapshot {
  EngineSnapshot({
    required String ownerSessionId,
    required int sequence,
    List<EngineReceipt> receipts = const [],
  }) : ownerSessionId = nonEmpty(ownerSessionId),
       sequence = unsigned64(sequence),
       receipts = List.unmodifiable(receipts);

  final String ownerSessionId;
  final int sequence;
  final List<EngineReceipt> receipts;

  factory EngineSnapshot.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return EngineSnapshot(
      ownerSessionId: jsonValue<String>(json, 'ownerSessionId'),
      sequence: jsonValue<int>(json, 'sequence'),
      receipts: jsonValue<List>(
        json,
        'receipts',
      ).map((item) => EngineReceipt.fromJson(jsonObject(item))).toList(),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'ownerSessionId': ownerSessionId,
            'sequence': sequence,
            'receipts': receipts.map((item) => item.toJson()).toList(),
          })
          as Map<String, Object?>;
}

final class EngineTask {
  EngineTask({
    required this.key,
    required String url,
    this.requestedFileName,
    required this.directory,
    required String stagingLocation,
  }) : url = downloadUrl(url),
       stagingLocation = nonEmpty(stagingLocation) {
    if (requestedFileName != null) fileName(requestedFileName!);
  }

  final ExecutionKey key;
  final String url;
  final String? requestedFileName;
  final DirectoryLocation directory;
  final String stagingLocation;

  factory EngineTask.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return EngineTask(
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      url: jsonValue<String>(json, 'url'),
      requestedFileName: jsonOptional<String>(json, 'requestedFileName'),
      directory: DirectoryLocation.fromJson(jsonObject(json['directory'])),
      stagingLocation: jsonValue<String>(json, 'stagingLocation'),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'key': key.toJson(),
            'url': url,
            'requestedFileName': requestedFileName,
            'directory': directory.toJson(),
            'stagingLocation': stagingLocation,
          })
          as Map<String, Object?>;
}

final class EngineEvent {
  EngineEvent({
    required String ownerSessionId,
    required int sequence,
    required this.key,
    required int downloadedBytes,
    this.totalBytes,
    required int sampleMonotonicMs,
    this.receipt,
  }) : ownerSessionId = nonEmpty(ownerSessionId),
       sequence = unsigned64(sequence),
       downloadedBytes = unsigned64(downloadedBytes),
       sampleMonotonicMs = unsigned64(sampleMonotonicMs) {
    if (totalBytes != null) unsigned64(totalBytes!);
    if (receipt != null && receipt!.key != key) invalid();
  }

  final String ownerSessionId;
  final int sequence;
  final ExecutionKey key;
  final int downloadedBytes;
  final int? totalBytes;
  final int sampleMonotonicMs;
  final EngineReceipt? receipt;

  factory EngineEvent.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'protocolVersion');
    return EngineEvent(
      ownerSessionId: jsonValue<String>(json, 'ownerSessionId'),
      sequence: jsonValue<int>(json, 'sequence'),
      key: ExecutionKey.fromJson(jsonObject(json['key'])),
      downloadedBytes: jsonValue<int>(json, 'downloadedBytes'),
      totalBytes: jsonOptional<int>(json, 'totalBytes'),
      sampleMonotonicMs: jsonValue<int>(json, 'sampleMonotonicMs'),
      receipt: json['receipt'] == null
          ? null
          : EngineReceipt.fromJson(jsonObject(json['receipt'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'protocolVersion': 1,
            'ownerSessionId': ownerSessionId,
            'sequence': sequence,
            'key': key.toJson(),
            'downloadedBytes': downloadedBytes,
            'totalBytes': totalBytes,
            'sampleMonotonicMs': sampleMonotonicMs,
            'receipt': receipt?.toJson(),
          })
          as Map<String, Object?>;
}

final class CreateDownload {
  CreateDownload({
    required String requestId,
    required String url,
    this.fileName,
    this.directory,
  }) : requestId = nonEmpty(requestId),
       url = downloadUrl(url) {
    if (fileName != null) validateFileName(fileName!);
  }

  final String requestId;
  final String url;
  final String? fileName;
  final DirectoryLocation? directory;

  factory CreateDownload.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return CreateDownload(
      requestId: jsonValue<String>(json, 'requestId'),
      url: jsonValue<String>(json, 'url'),
      fileName: jsonOptional<String>(json, 'fileName'),
      directory: json['directory'] == null
          ? null
          : DirectoryLocation.fromJson(jsonObject(json['directory'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'requestId': requestId,
            'url': url,
            'fileName': fileName,
            'directory': directory?.toJson(),
          })
          as Map<String, Object?>;
}

final class DownloadTask {
  DownloadTask({
    required String id,
    required String requestId,
    required String engineId,
    required int generation,
    required String originalUrl,
    this.effectiveUrl,
    this.requestedFileName,
    required String displayName,
    required this.directory,
    required this.status,
    required int downloadedBytes,
    this.totalBytes,
    this.fileLocation,
    this.lastError,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.stagingRef,
    this.targetRef,
    this.engineReceipt,
    this.pendingCommand,
    this.publishOperation,
  }) : id = nonEmpty(id),
       requestId = nonEmpty(requestId),
       engineId = nonEmpty(engineId),
       generation = unsigned64(generation),
       originalUrl = downloadUrl(originalUrl),
       displayName = fileName(displayName),
       downloadedBytes = unsigned64(downloadedBytes),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    if (totalBytes != null) unsigned64(totalBytes!);
    if (effectiveUrl != null) downloadUrl(effectiveUrl!);
    if (requestedFileName != null) fileName(requestedFileName!);
    if (updatedAt.isBefore(createdAt)) invalid();
    if (engineReceipt != null && engineReceipt!.key != key) invalid();
    if (pendingCommand != null && pendingCommand!.key != key) invalid();
    if (publishOperation != null && publishOperation!.key != key) invalid();
  }

  final String id;
  final String requestId;
  final String engineId;
  final int generation;
  final String originalUrl;
  final String? effectiveUrl;
  final String? requestedFileName;
  final String displayName;
  final DirectoryLocation directory;
  final DownloadStatus status;
  final int downloadedBytes;
  final int? totalBytes;
  final FileLocation? fileLocation;
  final DownloadFailure? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? stagingRef;
  final String? targetRef;
  final EngineReceipt? engineReceipt;
  final EngineCommand? pendingCommand;
  final PublishOperation? publishOperation;

  ExecutionKey get key =>
      ExecutionKey(taskId: id, engineId: engineId, generation: generation);
  double? get progress => totalBytes == null || totalBytes == 0
      ? null
      : downloadedBytes / totalBytes!;

  factory DownloadTask.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return DownloadTask(
      id: jsonValue<String>(json, 'id'),
      requestId: jsonValue<String>(json, 'requestId'),
      engineId: jsonValue<String>(json, 'engineId'),
      generation: jsonValue<int>(json, 'generation'),
      originalUrl: jsonValue<String>(json, 'originalUrl'),
      effectiveUrl: jsonOptional<String>(json, 'effectiveUrl'),
      requestedFileName: jsonOptional<String>(json, 'requestedFileName'),
      displayName: jsonValue<String>(json, 'displayName'),
      directory: DirectoryLocation.fromJson(jsonObject(json['directory'])),
      status: jsonEnum(DownloadStatus.values, json['status']),
      downloadedBytes: jsonValue<int>(json, 'downloadedBytes'),
      totalBytes: jsonOptional<int>(json, 'totalBytes'),
      fileLocation: json['fileLocation'] == null
          ? null
          : FileLocation.fromJson(jsonObject(json['fileLocation'])),
      lastError: json['lastError'] == null
          ? null
          : DownloadFailure.fromJson(jsonObject(json['lastError'])),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        jsonValue<int>(json, 'createdAt'),
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        jsonValue<int>(json, 'updatedAt'),
        isUtc: true,
      ),
      stagingRef: jsonOptional<String>(json, 'stagingRef'),
      targetRef: jsonOptional<String>(json, 'targetRef'),
      engineReceipt: json['engineReceipt'] == null
          ? null
          : EngineReceipt.fromJson(jsonObject(json['engineReceipt'])),
      pendingCommand: json['pendingCommand'] == null
          ? null
          : EngineCommand.fromJson(jsonObject(json['pendingCommand'])),
      publishOperation: json['publishOperation'] == null
          ? null
          : PublishOperation.fromJson(jsonObject(json['publishOperation'])),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'id': id,
            'requestId': requestId,
            'engineId': engineId,
            'generation': generation,
            'originalUrl': originalUrl,
            'effectiveUrl': effectiveUrl,
            'requestedFileName': requestedFileName,
            'displayName': displayName,
            'directory': directory.toJson(),
            'status': status.name,
            'downloadedBytes': downloadedBytes,
            'totalBytes': totalBytes,
            'fileLocation': fileLocation?.toJson(),
            'lastError': lastError?.toJson(),
            'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
            'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
            'stagingRef': stagingRef,
            'targetRef': targetRef,
            'engineReceipt': engineReceipt?.toJson(),
            'pendingCommand': pendingCommand?.toJson(),
            'publishOperation': publishOperation?.toJson(),
          })
          as Map<String, Object?>;
}
