// Pure Dart trust-boundary validation. Never include private locators in errors.
enum FailureCode {
  invalidInput,
  protocolMismatch,
  notFound,
  stateConflict,
  networkUnavailable,
  timeout,
  httpFailure,
  restartRequired,
  directoryUnavailable,
  permissionDenied,
  directoryUnsupported,
  publicationUncertain,
  insufficientSpace,
  fileWriteFailure,
  backgroundRestricted,
  persistenceFailure,
  cleanupFailure,
  fileMissing,
  noHandler,
  installPermissionRequired,
}

Never invalid([FailureCode code = FailureCode.invalidInput]) =>
    throw DownloadValidationException(code);

final class DownloadValidationException implements Exception {
  const DownloadValidationException(this.code);
  final FailureCode code;
  @override
  String toString() => 'DownloadValidationException(${code.name})';
}

String nonEmpty(String value) {
  if (value.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
    invalid();
  }
  return value;
}

int unsigned64(int value, {bool positive = false}) {
  if (value < (positive ? 1 : 0) || value > 0x7fffffffffffffff) invalid();
  return value;
}

String downloadUrl(String value) {
  final text = value.trim();
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(text) ||
      RegExp(r'^https?://[^/?#]*@', caseSensitive: false).hasMatch(text)) {
    invalid();
  }
  return text;
}

String fileName(String value) {
  nonEmpty(value);
  // Portable strict subset, including Windows reserved names.
  if (value == '.' ||
      value == '..' ||
      RegExp(r'[<>:"/\\|?*]').hasMatch(value) ||
      value.endsWith('.') ||
      value.endsWith(' ') ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(value)) {
    invalid();
  }
  return value;
}

String downloadFileName(String url, String fallback) {
  try {
    return fileName(Uri.parse(url).pathSegments.last);
  } catch (_) {
    return fallback;
  }
}

Map<String, Object?> jsonObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    invalid(FailureCode.protocolMismatch);
  }
  return Map<String, Object?>.from(value);
}

void jsonVersion(Map<String, Object?> value, {String field = 'version'}) {
  if (value[field] is! int || value[field] != 1) {
    invalid(FailureCode.protocolMismatch);
  }
}

T jsonValue<T>(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! T) invalid(FailureCode.protocolMismatch);
  return result;
}

T? jsonOptional<T>(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result == null) return null;
  if (result is! T) invalid(FailureCode.protocolMismatch);
  return result as T;
}

T jsonEnum<T extends Enum>(List<T> values, Object? value) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  invalid(FailureCode.protocolMismatch);
}

Object? freezeJson(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List) return List<Object?>.unmodifiable(value.map(freezeJson));
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      jsonObject(value).map((key, value) => MapEntry(key, freezeJson(value))),
    );
  }
  invalid(FailureCode.protocolMismatch);
}
