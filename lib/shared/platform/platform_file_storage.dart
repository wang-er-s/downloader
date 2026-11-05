import 'dart:io';

import 'package:flutter/services.dart';

import '../../features/downloads/data/publication_journal.dart';
import '../../features/downloads/domain/download_models.dart';
import 'file_storage.dart';
import 'native_file_storage.dart';

export '../../features/downloads/data/publication_journal.dart'
    show FileStorageException, PublicationJournal;
export 'file_storage.dart';
export 'native_file_storage.dart';

/// Repository composition: pass PluginEngine.publicationJournal on Apple and
/// Windows. Android's native engine owns its publication journal and source gate.
FileStorage platformFileStorage({PublicationJournal? journal}) {
  if (Platform.isAndroid) return AndroidFileStorage();
  if (journal == null) throw ArgumentError('An execution-owned publication journal is required');
  return NativeFileStorage(journal: journal);
}

DirectoryLocation defaultDownloadDirectory() {
  final platform = Platform.isAndroid ? DownloadPlatform.android : Platform.isIOS ? DownloadPlatform.ios : Platform.isMacOS ? DownloadPlatform.macos : Platform.isWindows ? DownloadPlatform.windows : throw UnsupportedError('Unsupported file storage platform');
  return DirectoryLocation(platform: platform, kind: platform == DownloadPlatform.ios ? DirectoryKind.appDocuments : DirectoryKind.systemDownloads, displayName: platform == DownloadPlatform.ios ? 'Downloads' : 'Downloader');
}

/// After persisting cancelling and awaiting the real engine stop, clean only
/// the unpublished target, then replay the original cancel command. Published
/// or uncertain results require user resolution and keep the complete source.
Future<void> cleanupPendingPublication(FileStorage storage, PublishOperation operation) {
  if (storage is NativeFileStorage) return storage.cleanupPublication(operation);
  if (storage is AndroidFileStorage) return storage.cleanupPublication(operation);
  throw ArgumentError('Unknown FileStorage implementation');
}

final class AndroidFileStorage implements FileStorage {
  AndroidFileStorage({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('downloader/file_storage');
  final MethodChannel _channel;
  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try { return await _channel.invokeMethod<Object?>(method, args); }
    on PlatformException catch (error) {
      storageFailure(FailureCode.values.where((value) => value.name == error.code).firstOrNull ?? FailureCode.fileWriteFailure);
    }
  }
  @override
  Future<DirectoryLocation?> pickDirectory() async {
    final value = await _call('pickDirectory');
    return value == null ? null : DirectoryLocation.fromJson(jsonObject(value));
  }
  @override
  Future<FileLocation> publish(PublishOperation operation) async => FileLocation.fromJson(jsonObject(await _call('publish', {'operation': operation.toJson()})));
  @override
  Future<PublishRecovery> recoverPublication(PublishOperation operation) async => PublishRecovery.fromJson(jsonObject(await _call('recoverPublication', {'operation': operation.toJson()})));
  Future<void> cleanupPublication(PublishOperation operation) async { await _call('cleanupPublication', {'operation': operation.toJson()}); }
  @override
  Future<void> deleteOwned(FileLocation file) async { await _call('deleteOwned', {'file': file.toJson()}); }
  @override
  Future<void> open(FileLocation file) async { await _call('open', {'file': file.toJson()}); }
}
