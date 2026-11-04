import '../../features/downloads/domain/download_models.dart';

/// Platform adapters prove ownership before mutation. Recovery only inspects;
/// uncertain results must never allocate or guess which file to delete.
abstract interface class FileStorage {
  Future<DirectoryLocation?> pickDirectory();
  Future<FileLocation> publish(PublishOperation operation);
  Future<PublishRecovery> recoverPublication(PublishOperation operation);
  Future<void> deleteOwned(FileLocation file);
  Future<void> open(FileLocation file);
}
