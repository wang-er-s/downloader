import 'package:downloader/features/downloads/domain/download_models.dart';

final directory = DirectoryLocation(
  platform: DownloadPlatform.macos,
  kind: DirectoryKind.systemDownloads,
  subdirectory: 'Downloader',
  displayName: '下载',
);
final key = ExecutionKey(taskId: 'task', engineId: 'engine', generation: 0);
final now = DateTime.utc(2026, 11, 4);
final location = FileLocation(
  platform: DownloadPlatform.macos,
  kind: FileKind.path,
  locator: '/tmp/文件.bin',
  identity: 'owned-inode',
);
final command = EngineCommand(
  commandId: 'command',
  key: key,
  ownerSessionId: 'session',
  expectedReceiptVersion: 0,
);
final publication = PublishOperation(
  operationId: 'operation',
  key: key,
  sourceRef: 'private-staging',
  sourceLength: 0x100000001,
  directory: directory,
  temporaryName: 'operation.partial',
  candidateName: '文件.bin',
  phase: PublishPhase.prepared,
);
EngineReceipt receipt({int version = 1}) => EngineReceipt(
  key: key,
  receiptVersion: version,
  state: DownloadStatus.paused,
  downloadedBytes: 0x100000001,
  resumeSupport: ResumeSupport.supported,
  resumeRef: 'private-resume-$version',
  stagingLocation: 'private-staging',
  publishOperation: publication,
);
DownloadTask task({
  String id = 'task',
  String requestId = 'request',
  String engineId = 'engine',
  EngineReceipt? engineReceipt,
  int bytes = 0x100000001,
  FileLocation? fileLocation,
}) => DownloadTask(
  id: id,
  requestId: requestId,
  engineId: engineId,
  generation: 0,
  originalUrl: 'https://example.com/file',
  displayName: '文件.bin',
  directory: directory,
  status: DownloadStatus.paused,
  downloadedBytes: bytes,
  fileLocation: fileLocation,
  createdAt: now,
  updatedAt: now,
  engineReceipt: engineReceipt,
);
