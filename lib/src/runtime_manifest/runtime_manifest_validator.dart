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
      if (artifact.officialUrl.scheme != 'https' ||
          artifact.officialUrl.host.isEmpty) {
        errors.add(
          RuntimeManifestValidationError(
            '$artifactPath.officialUrl',
            'must be an absolute HTTPS URL',
          ),
        );
      }
      if (artifact.officialUrl.hasFragment ||
          artifact.officialUrl.userInfo.isNotEmpty) {
        errors.add(
          RuntimeManifestValidationError(
            '$artifactPath.officialUrl',
            'must not contain credentials or a fragment',
          ),
        );
      }
      if (!_sha256Pattern.hasMatch(artifact.sha256)) {
        errors.add(
          RuntimeManifestValidationError(
            '$artifactPath.sha256',
            'must contain exactly 64 hexadecimal characters',
          ),
        );
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
}
