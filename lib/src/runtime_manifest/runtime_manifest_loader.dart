import 'dart:convert';
import 'dart:io';

import 'runtime_manifest_models.dart';
import 'runtime_manifest_validator.dart';

class RuntimeManifestLoader {
  const RuntimeManifestLoader({
    this.validator = const RuntimeManifestValidator(),
  });

  final RuntimeManifestValidator validator;

  RuntimeManifest decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw RuntimeManifestValidationException([
        RuntimeManifestValidationError(r'$', 'invalid JSON: ${error.message}'),
      ]);
    }
    if (decoded is! Map<String, Object?>) {
      throw RuntimeManifestValidationException(const [
        RuntimeManifestValidationError(r'$', 'must be a JSON object'),
      ]);
    }
    return fromJson(decoded);
  }

  Future<RuntimeManifest> loadFile(File file) async {
    return decode(await file.readAsString());
  }

  RuntimeManifest fromJson(Map<String, Object?> json) {
    final reader = _ManifestReader();
    final manifest = reader.readManifest(json);
    if (reader.errors.isNotEmpty) {
      throw RuntimeManifestValidationException(reader.errors);
    }
    validator.validateOrThrow(manifest);
    return manifest;
  }
}

class _ManifestReader {
  final List<RuntimeManifestValidationError> errors = [];

  RuntimeManifest readManifest(Map<String, Object?> json) {
    return RuntimeManifest(
      schemaVersion: _requiredInt(json, 'schemaVersion', r'$') ?? -1,
      components: _objectList(
        json,
        'components',
        r'$',
      ).indexed.map((entry) => _readComponent(entry.$2, entry.$1)).toList(),
    );
  }

  RuntimeComponent _readComponent(Map<String, Object?> json, int index) {
    final path = '\$.components[$index]';
    final service = _optionalObject(json, 'service', path);
    final androidSdk = _optionalObject(json, 'androidSdk', path);
    return RuntimeComponent(
      id: _requiredString(json, 'id', path) ?? '',
      displayName: _requiredString(json, 'displayName', path) ?? '',
      version: _requiredString(json, 'version', path) ?? '',
      minimumCompatibleVersion:
          _requiredString(json, 'minimumCompatibleVersion', path) ?? '',
      provisioning: _enumValue(
        json,
        'provisioning',
        path,
        RuntimeProvisioning.values,
        (value) => value.jsonValue,
      ),
      artifacts: _objectList(json, 'artifacts', path).indexed
          .map(
            (entry) => _readArtifact(entry.$2, '$path.artifacts[${entry.$1}]'),
          )
          .toList(),
      executables: _objectList(json, 'executables', path).indexed
          .map(
            (entry) =>
                _readExecutable(entry.$2, '$path.executables[${entry.$1}]'),
          )
          .toList(),
      dependencies: _stringList(json, 'dependencies', path),
      service: service == null ? null : _readService(service, '$path.service'),
      androidSdk: androidSdk == null
          ? null
          : _readAndroidSdk(androidSdk, '$path.androidSdk'),
    );
  }

  RuntimeArtifact _readArtifact(Map<String, Object?> json, String path) {
    final urlText = _requiredString(json, 'officialUrl', path) ?? '';
    final mirrorUrlTexts = _optionalStringList(json, 'mirrorUrls', path);
    return RuntimeArtifact(
      platform: _enumValue(
        json,
        'platform',
        path,
        RuntimePlatform.values,
        (value) => value.jsonValue,
      ),
      architecture: _enumValue(
        json,
        'architecture',
        path,
        RuntimeArchitecture.values,
        (value) => value.jsonValue,
      ),
      officialUrl: Uri.tryParse(urlText) ?? Uri(),
      mirrorUrls: mirrorUrlTexts
          .map((value) => Uri.tryParse(value) ?? Uri())
          .toList(),
      sha256: _requiredString(json, 'sha256', path) ?? '',
      archiveType: _enumValue(
        json,
        'archiveType',
        path,
        RuntimeArchiveType.values,
        (value) => value.jsonValue,
      ),
      archiveRoot: _optionalString(json, 'archiveRoot', path) ?? '',
      installSubdirectory:
          _optionalString(json, 'installSubdirectory', path) ?? '',
    );
  }

  RuntimeExecutable _readExecutable(Map<String, Object?> json, String path) {
    return RuntimeExecutable(
      platform: _enumValue(
        json,
        'platform',
        path,
        RuntimePlatform.values,
        (value) => value.jsonValue,
      ),
      architectures: _enumList(
        json,
        'architectures',
        path,
        RuntimeArchitecture.values,
        (value) => value.jsonValue,
      ),
      path: _requiredString(json, 'path', path) ?? '',
    );
  }

  RuntimeServiceMetadata _readService(Map<String, Object?> json, String path) {
    return RuntimeServiceMetadata(
      serviceName: _requiredString(json, 'serviceName', path) ?? '',
      defaultPort: _requiredInt(json, 'defaultPort', path) ?? -1,
      startAutomatically:
          _requiredBool(json, 'startAutomatically', path) ?? false,
      dataDirectory: _requiredString(json, 'dataDirectory', path) ?? '',
      healthCheckCommand: _stringList(json, 'healthCheckCommand', path),
    );
  }

  RuntimeAndroidSdkMetadata _readAndroidSdk(
    Map<String, Object?> json,
    String path,
  ) {
    final license = _optionalObject(json, 'license', path);
    return RuntimeAndroidSdkMetadata(
      packages: _stringList(json, 'packages', path),
      repositoryMirrorUrls: _optionalStringList(
        json,
        'repositoryMirrorUrls',
        path,
      ).map((value) => Uri.tryParse(value) ?? Uri()).toList(),
      license: license == null
          ? RuntimeLicenseMetadata(id: '', displayName: '', url: Uri())
          : _readLicense(license, '$path.license'),
    );
  }

  RuntimeLicenseMetadata _readLicense(Map<String, Object?> json, String path) {
    final url = _requiredString(json, 'url', path) ?? '';
    return RuntimeLicenseMetadata(
      id: _requiredString(json, 'id', path) ?? '',
      displayName: _requiredString(json, 'displayName', path) ?? '',
      url: Uri.tryParse(url) ?? Uri(),
    );
  }

  String? _requiredString(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value is String) {
      return value;
    }
    _typeError(path, key, 'a string', value);
    return null;
  }

  String? _optionalString(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value == null) return null;
    if (value is String) return value;
    _typeError(path, key, 'a string or null', value);
    return null;
  }

  int? _requiredInt(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    _typeError(path, key, 'an integer', value);
    return null;
  }

  bool? _requiredBool(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value is bool) {
      return value;
    }
    _typeError(path, key, 'a boolean', value);
    return null;
  }

  List<Map<String, Object?>> _objectList(
    Map<String, Object?> json,
    String key,
    String path,
  ) {
    final value = json[key];
    if (value is! List<Object?>) {
      _typeError(path, key, 'an array', value);
      return const [];
    }
    final result = <Map<String, Object?>>[];
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      if (item is Map<String, Object?>) {
        result.add(item);
      } else {
        errors.add(
          RuntimeManifestValidationError(
            '$path.$key[$index]',
            'must be an object',
          ),
        );
      }
    }
    return result;
  }

  Map<String, Object?>? _optionalObject(
    Map<String, Object?> json,
    String key,
    String path,
  ) {
    final value = json[key];
    if (value == null) {
      return null;
    }
    if (value is Map<String, Object?>) {
      return value;
    }
    _typeError(path, key, 'an object or null', value);
    return null;
  }

  List<String> _stringList(Map<String, Object?> json, String key, String path) {
    final value = json[key];
    if (value is! List<Object?>) {
      _typeError(path, key, 'an array', value);
      return const [];
    }
    final result = <String>[];
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      if (item is String) {
        result.add(item);
      } else {
        errors.add(
          RuntimeManifestValidationError(
            '$path.$key[$index]',
            'must be a string',
          ),
        );
      }
    }
    return result;
  }

  List<String> _optionalStringList(
    Map<String, Object?> json,
    String key,
    String path,
  ) {
    if (!json.containsKey(key)) return const [];
    return _stringList(json, key, path);
  }

  T _enumValue<T>(
    Map<String, Object?> json,
    String key,
    String path,
    List<T> values,
    String Function(T value) jsonValue,
  ) {
    final rawValue = _requiredString(json, key, path);
    for (final value in values) {
      if (jsonValue(value) == rawValue) {
        return value;
      }
    }
    if (rawValue != null) {
      errors.add(
        RuntimeManifestValidationError(
          '$path.$key',
          'must be one of ${values.map(jsonValue).join(', ')}',
        ),
      );
    }
    return values.first;
  }

  List<T> _enumList<T>(
    Map<String, Object?> json,
    String key,
    String path,
    List<T> values,
    String Function(T value) jsonValue,
  ) {
    final rawValues = _stringList(json, key, path);
    final result = <T>[];
    for (var index = 0; index < rawValues.length; index++) {
      final rawValue = rawValues[index];
      T? parsed;
      for (final value in values) {
        if (jsonValue(value) == rawValue) {
          parsed = value;
          break;
        }
      }
      if (parsed == null) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.$key[$index]',
            'must be one of ${values.map(jsonValue).join(', ')}',
          ),
        );
      } else {
        result.add(parsed);
      }
    }
    return result;
  }

  void _typeError(String path, String key, String expected, Object? value) {
    final actual = value == null ? 'missing' : value.runtimeType.toString();
    errors.add(
      RuntimeManifestValidationError(
        '$path.$key',
        'must be $expected (was $actual)',
      ),
    );
  }
}
