import '../../downloads/domain/download_models.dart';

final class SavedDownloadInput {
  SavedDownloadInput({
    required String id,
    required String url,
    this.fileName,
    this.directory,
  }) : id = nonEmpty(id),
       url = downloadUrl(url) {
    if (fileName != null) validateFileName(fileName!);
  }

  final String id;
  final String url;
  final String? fileName;
  final DirectoryLocation? directory;

  factory SavedDownloadInput.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return SavedDownloadInput(
      id: jsonValue<String>(json, 'id'),
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
            'id': id,
            'url': url,
            'fileName': fileName,
            'directory': directory?.toJson(),
          })
          as Map<String, Object?>;
}

final class SavedDownload {
  SavedDownload({
    required String id,
    required String url,
    this.fileName,
    this.directory,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : id = nonEmpty(id),
       url = downloadUrl(url),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    if (fileName != null) validateFileName(fileName!);
    if (updatedAt.isBefore(createdAt)) invalid();
  }

  final String id;
  final String url;
  final String? fileName;
  final DirectoryLocation? directory;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayName => fileName ?? downloadFileName(url, 'download_$id');

  factory SavedDownload.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return SavedDownload(
      id: jsonValue<String>(json, 'id'),
      url: jsonValue<String>(json, 'url'),
      fileName: jsonOptional<String>(json, 'fileName'),
      directory: json['directory'] == null
          ? null
          : DirectoryLocation.fromJson(jsonObject(json['directory'])),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        jsonValue<int>(json, 'createdAt'),
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        jsonValue<int>(json, 'updatedAt'),
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'id': id,
            'url': url,
            'fileName': fileName,
            'directory': directory?.toJson(),
            'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
            'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
          })
          as Map<String, Object?>;
}
