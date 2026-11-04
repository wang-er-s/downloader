import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Application support, never cache or a user-selected download directory.
/// The injectable resolver also permits real temporary-disk storage tests.
Future<String> appStorePath({
  Future<Directory> Function()? supportDirectory,
}) async {
  final directory =
      await (supportDirectory ?? getApplicationSupportDirectory)();
  await directory.create(recursive: true);
  return directory.uri.resolve('downloader.db').toFilePath();
}
