import '../domain/download_models.dart';

/// Implementations persist receipts before delivery; inspect is non-destructive.
/// Commands retain their captured key/session/version, including during retries.
abstract interface class DownloadEngine {
  Stream<EngineEvent> get events;
  Future<EngineSnapshot> inspect();
  Future<void> enqueue(EngineCommand command, EngineTask input);
  Future<EngineReceipt> pause(EngineCommand command);
  Future<void> resume(EngineCommand command);
  Future<EngineReceipt> cancel(EngineCommand command);
  Future<void> acknowledge(ReceiptAck ack);
}
