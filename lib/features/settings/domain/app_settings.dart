import '../../downloads/domain/download_models.dart';

enum AppTheme { system, light, dark }

final class AppSettings {
  AppSettings({this.theme = AppTheme.system, required this.defaultDirectory});

  final AppTheme theme;
  final DirectoryLocation defaultDirectory;

  factory AppSettings.fromJson(Map<String, Object?> json) {
    jsonVersion(json, field: 'version');
    return AppSettings(
      theme: jsonEnum(AppTheme.values, json['theme']),
      defaultDirectory: DirectoryLocation.fromJson(
        jsonObject(json['defaultDirectory']),
      ),
    );
  }

  Map<String, Object?> toJson() =>
      freezeJson({
            'version': 1,
            'theme': theme.name,
            'defaultDirectory': defaultDirectory.toJson(),
          })
          as Map<String, Object?>;
}
