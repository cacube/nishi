import 'runtime_manifest_models.dart';

class RuntimeManifestValidationError {
  const RuntimeManifestValidationError(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

class RuntimeManifestValidationException implements Exception {
  RuntimeManifestValidationException(
    List<RuntimeManifestValidationError> errors,
  ) : errors = List.unmodifiable(errors);

  final List<RuntimeManifestValidationError> errors;

  @override
  String toString() => 'Invalid runtime manifest:\n${errors.join('\n')}';
}

class RuntimeManifestValidator {
  const RuntimeManifestValidator();

  static final RegExp _componentIdPattern = RegExp(r'^[a-z][a-z0-9_-]*$');
  static final RegExp _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');
  static final RegExp _androidPackagePattern = RegExp(
    r'^[A-Za-z0-9_.-]+(?:;[A-Za-z0-9_.-]+)*$',
  );

  List<RuntimeManifestValidationError> validate(RuntimeManifest manifest) {
    final errors = <RuntimeManifestValidationError>[];
    if (manifest.schemaVersion != 1) {
      errors.add(
        RuntimeManifestValidationError(
          r'$.schemaVersion',
          'unsupported schema version ${manifest.schemaVersion}; expected 1',
        ),
      );
    }
    if (manifest.components.isEmpty) {
      errors.add(
        const RuntimeManifestValidationError(
          r'$.components',
          'must contain at least one component',
        ),
      );
    }

    final componentPaths = <String, String>{};
    for (var index = 0; index < manifest.components.length; index++) {
      final component = manifest.components[index];
      final path = '\$.components[$index]';
      final previousPath = componentPaths[component.id];
      if (previousPath != null) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.id',
            'duplicates component id declared at $previousPath.id',
          ),
        );
      } else {
        componentPaths[component.id] = path;
      }
      _validateComponent(component, path, errors);
    }

    _validateDependencies(manifest, componentPaths, errors);
    return List.unmodifiable(errors);
  }

  void validateOrThrow(RuntimeManifest manifest) {
    final errors = validate(manifest);
    if (errors.isNotEmpty) {
      throw RuntimeManifestValidationException(errors);
    }
  }

  void _validateComponent(
    RuntimeComponent component,
    String path,
    List<RuntimeManifestValidationError> errors,
  ) {
    if (!_componentIdPattern.hasMatch(component.id)) {
      errors.add(
        RuntimeManifestValidationError(
          '$path.id',
          'must match ${_componentIdPattern.pattern}',
        ),
      );
    }
    _requireNonBlank(component.displayName, '$path.displayName', errors);
    _requireNonBlank(component.version, '$path.version', errors);
    _requireNonBlank(
      component.minimumCompatibleVersion,
      '$path.minimumCompatibleVersion',
      errors,
    );

    if (component.isManaged && component.artifacts.isEmpty) {
      errors.add(
        RuntimeManifestValidationError(
          '$path.artifacts',
          'managed components require at least one artifact',
        ),
      );
    }
    if (component.isExternal && component.artifacts.isNotEmpty) {
      errors.add(
        RuntimeManifestValidationError(
          '$path.artifacts',
          'external components cannot declare managed artifacts',
        ),
      );
    }
    if (component.executables.isEmpty) {
      errors.add(
        RuntimeManifestValidationError(
          '$path.executables',
          'must contain at least one executable path',
        ),
      );
    }

    final artifactTargets = <String>{};
    for (var index = 0; index < component.artifacts.length; index++) {
      final artifact = component.artifacts[index];
      final artifactPath = '$path.artifacts[$index]';
      if (!artifactTargets.add(artifact.targetKey)) {
        errors.add(
          RuntimeManifestValidationError(
            artifactPath,
            'duplicates artifact target ${artifact.targetKey}',
          ),
        );
      }
      _validateDownloadUrl(
        artifact.officialUrl,
        '$artifactPath.officialUrl',
        errors,
      );
      final downloadUrls = <Uri>{artifact.officialUrl};
      for (
        var mirrorIndex = 0;
        mirrorIndex < artifact.mirrorUrls.length;
        mirrorIndex++
      ) {
        final mirror = artifact.mirrorUrls[mirrorIndex];
        final mirrorPath = '$artifactPath.mirrorUrls[$mirrorIndex]';
        _validateDownloadUrl(mirror, mirrorPath, errors);
        if (!downloadUrls.add(mirror)) {
          errors.add(
            RuntimeManifestValidationError(
              mirrorPath,
              'duplicates another download URL for this artifact',
            ),
          );
        }
      }
      if (!_sha256Pattern.hasMatch(artifact.sha256)) {
        errors.add(
          RuntimeManifestValidationError(
            '$artifactPath.sha256',
            'must contain exactly 64 hexadecimal characters',
          ),
        );
      }
      if (artifact.archiveRoot.isNotEmpty) {
        if (!_isSafeRelativePath(artifact.archiveRoot)) {
          errors.add(
            RuntimeManifestValidationError(
              '$artifactPath.archiveRoot',
              'must be a safe relative path inside the archive',
            ),
          );
        }
        if (artifact.archiveType != RuntimeArchiveType.zip &&
            artifact.archiveType != RuntimeArchiveType.tarGz) {
          errors.add(
            RuntimeManifestValidationError(
              '$artifactPath.archiveRoot',
              'is only supported for zip and tar.gz artifacts',
            ),
          );
        }
      }
      if (artifact.installSubdirectory.isNotEmpty) {
        if (!_isSafeRelativePath(artifact.installSubdirectory)) {
          errors.add(
            RuntimeManifestValidationError(
              '$artifactPath.installSubdirectory',
              'must be a safe relative path inside the managed runtime',
            ),
          );
        }
        if (artifact.archiveType != RuntimeArchiveType.zip &&
            artifact.archiveType != RuntimeArchiveType.tarGz) {
          errors.add(
            RuntimeManifestValidationError(
              '$artifactPath.installSubdirectory',
              'is only supported for zip and tar.gz artifacts',
            ),
          );
        }
      }
    }

    final executableKeys = <String>{};
    for (var index = 0; index < component.executables.length; index++) {
      final executable = component.executables[index];
      final executablePath = '$path.executables[$index]';
      _requireNonBlank(executable.path, '$executablePath.path', errors);
      if (executable.architectures.isEmpty) {
        errors.add(
          RuntimeManifestValidationError(
            '$executablePath.architectures',
            'must contain at least one architecture',
          ),
        );
      }
      final architectures = <RuntimeArchitecture>{};
      for (final architecture in executable.architectures) {
        if (!architectures.add(architecture)) {
          errors.add(
            RuntimeManifestValidationError(
              '$executablePath.architectures',
              'contains duplicate ${architecture.jsonValue}',
            ),
          );
        }
        final key =
            '${executable.platform.jsonValue}/'
            '${architecture.jsonValue}/${executable.path}';
        if (!executableKeys.add(key)) {
          errors.add(
            RuntimeManifestValidationError(
              executablePath,
              'duplicates executable $key',
            ),
          );
        }
      }
    }

    final dependencies = <String>{};
    for (var index = 0; index < component.dependencies.length; index++) {
      final dependency = component.dependencies[index];
      if (!dependencies.add(dependency)) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.dependencies[$index]',
            'duplicates dependency $dependency',
          ),
        );
      }
      if (dependency == component.id) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.dependencies[$index]',
            'component cannot depend on itself',
          ),
        );
      }
    }

    final service = component.service;
    if (service != null) {
      _requireNonBlank(
        service.serviceName,
        '$path.service.serviceName',
        errors,
      );
      if (service.defaultPort < 1 || service.defaultPort > 65535) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.service.defaultPort',
            'must be between 1 and 65535',
          ),
        );
      }
      _requireNonBlank(
        service.dataDirectory,
        '$path.service.dataDirectory',
        errors,
      );
      if (service.healthCheckCommand.isEmpty ||
          service.healthCheckCommand.any((part) => part.trim().isEmpty)) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.service.healthCheckCommand',
            'must contain non-blank command parts',
          ),
        );
      }
    }

    final androidSdk = component.androidSdk;
    if (androidSdk != null) {
      final metadataPath = '$path.androidSdk';
      if (!component.isManaged) {
        errors.add(
          RuntimeManifestValidationError(
            metadataPath,
            'requires a managed component',
          ),
        );
      }
      if (!component.dependencies.contains('jdk')) {
        errors.add(
          RuntimeManifestValidationError(
            '$path.dependencies',
            'Android SDK setup requires the jdk dependency',
          ),
        );
      }
      final packages = <String>{};
      for (var index = 0; index < androidSdk.packages.length; index++) {
        final package = androidSdk.packages[index];
        if (!packages.add(package)) {
          errors.add(
            RuntimeManifestValidationError(
              '$metadataPath.packages[$index]',
              'duplicates package $package',
            ),
          );
        }
        if (!_androidPackagePattern.hasMatch(package)) {
          errors.add(
            RuntimeManifestValidationError(
              '$metadataPath.packages[$index]',
              'contains an invalid Android SDK package identifier',
            ),
          );
        }
      }
      if (!packages.contains('platform-tools') ||
          !packages.any((value) => value.startsWith('platforms;android-')) ||
          !packages.any((value) => value.startsWith('build-tools;'))) {
        errors.add(
          RuntimeManifestValidationError(
            '$metadataPath.packages',
            'must include platform-tools, an Android platform, and build-tools',
          ),
        );
      }
      final repositoryMirrors = <Uri>{_androidOfficialRepositoryUrl};
      for (
        var index = 0;
        index < androidSdk.repositoryMirrorUrls.length;
        index++
      ) {
        final mirror = androidSdk.repositoryMirrorUrls[index];
        final mirrorPath = '$metadataPath.repositoryMirrorUrls[$index]';
        _validateDownloadUrl(mirror, mirrorPath, errors);
        if (mirror.query.isNotEmpty || !mirror.path.endsWith('/')) {
          errors.add(
            RuntimeManifestValidationError(
              mirrorPath,
              'must be a repository base URL ending in / without a query',
            ),
          );
        }
        if (!repositoryMirrors.add(mirror)) {
          errors.add(
            RuntimeManifestValidationError(
              mirrorPath,
              'duplicates another Android repository mirror URL',
            ),
          );
        }
      }
      final license = androidSdk.license;
      if (!_componentIdPattern.hasMatch(license.id)) {
        errors.add(
          RuntimeManifestValidationError(
            '$metadataPath.license.id',
            'must match ${_componentIdPattern.pattern}',
          ),
        );
      }
      _requireNonBlank(
        license.displayName,
        '$metadataPath.license.displayName',
        errors,
      );
      if (license.url.scheme != 'https' ||
          license.url.host.isEmpty ||
          license.url.userInfo.isNotEmpty ||
          license.url.hasFragment) {
        errors.add(
          RuntimeManifestValidationError(
            '$metadataPath.license.url',
            'must be an absolute HTTPS URL without credentials or a fragment',
          ),
        );
      }
    }
  }

  static final Uri _androidOfficialRepositoryUrl = Uri.parse(
    'https://dl.google.com/android/repository/',
  );

  void _validateDownloadUrl(
    Uri url,
    String path,
    List<RuntimeManifestValidationError> errors,
  ) {
    if (url.scheme != 'https' || url.host.isEmpty) {
      errors.add(
        RuntimeManifestValidationError(path, 'must be an absolute HTTPS URL'),
      );
    }
    if (url.hasFragment || url.userInfo.isNotEmpty) {
      errors.add(
        RuntimeManifestValidationError(
          path,
          'must not contain credentials or a fragment',
        ),
      );
    }
  }

  void _validateDependencies(
    RuntimeManifest manifest,
    Map<String, String> componentPaths,
    List<RuntimeManifestValidationError> errors,
  ) {
    final components = <String, RuntimeComponent>{};
    for (final component in manifest.components) {
      components.putIfAbsent(component.id, () => component);
    }

    for (var index = 0; index < manifest.components.length; index++) {
      final component = manifest.components[index];
      for (
        var dependencyIndex = 0;
        dependencyIndex < component.dependencies.length;
        dependencyIndex++
      ) {
        final dependency = component.dependencies[dependencyIndex];
        if (!components.containsKey(dependency)) {
          errors.add(
            RuntimeManifestValidationError(
              '\$.components[$index].dependencies[$dependencyIndex]',
              'references unknown component $dependency',
            ),
          );
        }
      }
    }

    final visiting = <String>{};
    final visited = <String>{};
    final reportedCycles = <String>{};

    void visit(String id, List<String> chain) {
      if (visited.contains(id)) {
        return;
      }
      if (!visiting.add(id)) {
        final cycleStart = chain.indexOf(id);
        final cycle = [...chain.sublist(cycleStart), id];
        final cycleText = cycle.join(' -> ');
        if (reportedCycles.add(cycleText)) {
          errors.add(
            RuntimeManifestValidationError(
              '${componentPaths[id] ?? r'$.components'}.dependencies',
              'dependency cycle detected: $cycleText',
            ),
          );
        }
        return;
      }

      final component = components[id];
      if (component != null) {
        for (final dependency in component.dependencies) {
          if (components.containsKey(dependency) && dependency != id) {
            visit(dependency, [...chain, id]);
          }
        }
      }
      visiting.remove(id);
      visited.add(id);
    }

    for (final id in components.keys) {
      visit(id, const []);
    }
  }

  void _requireNonBlank(
    String value,
    String path,
    List<RuntimeManifestValidationError> errors,
  ) {
    if (value.trim().isEmpty) {
      errors.add(RuntimeManifestValidationError(path, 'must not be blank'));
    }
  }

  bool _isSafeRelativePath(String value) {
    if (value.contains('\u0000') ||
        value.startsWith('/') ||
        value.startsWith(r'\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      return false;
    }
    final segments = value.replaceAll(r'\', '/').split('/');
    return segments.every(
      (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
    );
  }
}
