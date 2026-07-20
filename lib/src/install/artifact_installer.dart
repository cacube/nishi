import 'dart:io';

import '../runtime_manifest/runtime_manifest_models.dart';
import '../storage/runtime_layout.dart';

abstract interface class ProcessRunner {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

final class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }
}

enum ArtifactInstallStatus { activated, userActionRequired }

final class InstallerCommand {
  const InstallerCommand({
    required this.executable,
    required this.arguments,
    required this.requiresUserConfirmation,
    required this.requiresElevation,
  });

  final String executable;
  final List<String> arguments;
  final bool requiresUserConfirmation;
  final bool requiresElevation;
}

final class ArtifactInstallResult {
  const ArtifactInstallResult._({
    required this.status,
    this.activeDirectory,
    this.installerCommand,
  });

  factory ArtifactInstallResult.activated(Directory activeDirectory) {
    return ArtifactInstallResult._(
      status: ArtifactInstallStatus.activated,
      activeDirectory: activeDirectory,
    );
  }

  factory ArtifactInstallResult.userActionRequired(InstallerCommand command) {
    return ArtifactInstallResult._(
      status: ArtifactInstallStatus.userActionRequired,
      installerCommand: command,
    );
  }

  final ArtifactInstallStatus status;
  final Directory? activeDirectory;
  final InstallerCommand? installerCommand;
}

final class ArtifactInstaller {
  ArtifactInstaller({
    required RuntimeLayout layout,
    ProcessRunner processRunner = const SystemProcessRunner(),
  }) : _layout = layout,
       _processRunner = processRunner;

  final RuntimeLayout _layout;
  final ProcessRunner _processRunner;

  Future<ArtifactInstallResult> install({
    required RuntimeComponent component,
    required RuntimeArtifact artifact,
    required File artifactFile,
  }) async {
    if (!await artifactFile.exists()) {
      throw ArtifactInstallException(
        'Artifact does not exist: ${artifactFile.path}',
      );
    }

    if (_isInteractiveInstaller(artifact.archiveType)) {
      return ArtifactInstallResult.userActionRequired(
        commandForInteractiveInstaller(artifact: artifact, file: artifactFile),
      );
    }

    final staging = _layout.componentStaging(component.id, component.version);
    try {
      await _deleteIfExists(staging);
      await staging.create(recursive: true);

      switch (artifact.archiveType) {
        case RuntimeArchiveType.zip:
        case RuntimeArchiveType.tarGz:
          await _extractArchive(artifactFile, staging);
        case RuntimeArchiveType.raw:
          await _copyRaw(component, artifact, artifactFile, staging);
        case RuntimeArchiveType.dmg:
        case RuntimeArchiveType.pkg:
        case RuntimeArchiveType.msi:
        case RuntimeArchiveType.exe:
          throw StateError('Interactive installers are handled before staging');
      }

      await _validateExtractedTree(staging);
      await _validateExecutables(component, artifact, staging);
      final active = await _activate(component, staging);
      return ArtifactInstallResult.activated(active);
    } on Object {
      await _deleteIfExists(staging);
      rethrow;
    }
  }

  InstallerCommand commandForInteractiveInstaller({
    required RuntimeArtifact artifact,
    required File file,
  }) {
    final path = file.absolute.path;
    return switch ((artifact.platform, artifact.archiveType)) {
      (RuntimePlatform.macos, RuntimeArchiveType.dmg) => InstallerCommand(
        executable: 'open',
        arguments: [path],
        requiresUserConfirmation: true,
        requiresElevation: false,
      ),
      (RuntimePlatform.macos, RuntimeArchiveType.pkg) => InstallerCommand(
        executable: 'open',
        arguments: [path],
        requiresUserConfirmation: true,
        requiresElevation: true,
      ),
      (RuntimePlatform.windows, RuntimeArchiveType.msi) => InstallerCommand(
        executable: 'msiexec.exe',
        arguments: ['/i', path],
        requiresUserConfirmation: true,
        requiresElevation: true,
      ),
      (RuntimePlatform.windows, RuntimeArchiveType.exe) => InstallerCommand(
        executable: path,
        arguments: const [],
        requiresUserConfirmation: true,
        requiresElevation: true,
      ),
      (
        _,
        RuntimeArchiveType.dmg ||
            RuntimeArchiveType.pkg ||
            RuntimeArchiveType.msi ||
            RuntimeArchiveType.exe,
      ) =>
        throw ArtifactInstallException(
          '${artifact.archiveType.jsonValue} is not supported on '
          '${artifact.platform.jsonValue}',
        ),
      _ => throw ArtifactInstallException(
        '${artifact.archiveType.jsonValue} is not an interactive installer',
      ),
    };
  }

  Future<void> _extractArchive(File archive, Directory staging) async {
    final listResult = await _processRunner.run('tar', ['-tf', archive.path]);
    if (listResult.exitCode != 0) {
      throw ArtifactInstallException(
        'Unable to inspect archive: ${listResult.stderr}',
      );
    }
    for (final entry in _lines(listResult.stdout)) {
      _validateRelativePath(entry, context: 'Archive entry');
    }

    final extractResult = await _processRunner.run('tar', [
      '-xf',
      archive.path,
      '-C',
      staging.path,
    ]);
    if (extractResult.exitCode != 0) {
      throw ArtifactInstallException(
        'Unable to extract archive: ${extractResult.stderr}',
      );
    }
  }

  Future<void> _copyRaw(
    RuntimeComponent component,
    RuntimeArtifact artifact,
    File source,
    Directory staging,
  ) async {
    final executables = _applicableExecutables(component, artifact);
    if (executables.length != 1) {
      throw ArtifactInstallException(
        'A raw artifact must declare exactly one executable for its target',
      );
    }
    final relativePath = _validateRelativePath(
      executables.single.path,
      context: 'Executable path',
    );
    final destination = File(_resolveInside(staging, relativePath));
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.partial');
    await source.copy(partial.path);
    await partial.rename(destination.path);
  }

  Future<void> _validateExtractedTree(Directory staging) async {
    final stagingPath = _normalizedAbsolute(staging.path);
    await for (final entity in staging.list(
      recursive: true,
      followLinks: false,
    )) {
      final entityPath = _normalizedAbsolute(entity.path);
      if (!_isWithin(stagingPath, entityPath)) {
        throw ArtifactInstallException(
          'Extracted path escapes staging: ${entity.path}',
        );
      }
      if (entity is Link) {
        final target = await entity.target();
        if (_isAbsolutePortable(target)) {
          throw ArtifactInstallException(
            'Extracted link has an absolute target: ${entity.path}',
          );
        }
        final resolvedTarget = _normalizedAbsolute(
          '${entity.parent.path}${Platform.pathSeparator}$target',
        );
        if (!_isWithin(stagingPath, resolvedTarget)) {
          throw ArtifactInstallException(
            'Extracted link escapes staging: ${entity.path}',
          );
        }
      }
    }
  }

  Future<void> _validateExecutables(
    RuntimeComponent component,
    RuntimeArtifact artifact,
    Directory staging,
  ) async {
    final executables = _applicableExecutables(component, artifact);
    if (executables.isEmpty) {
      throw ArtifactInstallException(
        'No executable is declared for ${artifact.targetKey}',
      );
    }
    for (final executable in executables) {
      final relativePath = _validateRelativePath(
        executable.path,
        context: 'Executable path',
      );
      final file = File(_resolveInside(staging, relativePath));
      if (!await file.exists()) {
        throw ArtifactInstallException(
          'Declared executable is missing: ${executable.path}',
        );
      }
    }
  }

  List<RuntimeExecutable> _applicableExecutables(
    RuntimeComponent component,
    RuntimeArtifact artifact,
  ) {
    return component.executables
        .where((executable) {
          return executable.platform == artifact.platform &&
              executable.architectures.contains(artifact.architecture);
        })
        .toList(growable: false);
  }

  Future<Directory> _activate(
    RuntimeComponent component,
    Directory staging,
  ) async {
    final target = _layout.componentVersion(component.id, component.version);
    final backup = Directory('${target.path}.backup');
    await target.parent.create(recursive: true);
    await _deleteIfExists(backup);
    final hadExistingVersion = await target.exists();

    if (hadExistingVersion) {
      await target.rename(backup.path);
    }
    try {
      await staging.rename(target.path);
    } on Object {
      if (hadExistingVersion &&
          await backup.exists() &&
          !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    await _deleteIfExists(backup);
    return target;
  }
}

final class ArtifactInstallException implements Exception {
  const ArtifactInstallException(this.message);

  final String message;

  @override
  String toString() => 'ArtifactInstallException: $message';
}

bool _isInteractiveInstaller(RuntimeArchiveType type) {
  return switch (type) {
    RuntimeArchiveType.dmg ||
    RuntimeArchiveType.pkg ||
    RuntimeArchiveType.msi ||
    RuntimeArchiveType.exe => true,
    _ => false,
  };
}

Iterable<String> _lines(Object? output) sync* {
  for (final line in (output?.toString() ?? '').split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) yield trimmed;
  }
}

String _validateRelativePath(String path, {required String context}) {
  if (path.contains('\u0000') || _isAbsolutePortable(path)) {
    throw ArtifactInstallException('$context is not relative: $path');
  }
  final segments = path.replaceAll(r'\', '/').split('/');
  if (segments.any((segment) => segment == '..')) {
    throw ArtifactInstallException('$context contains path traversal: $path');
  }
  final clean = segments.where(
    (segment) => segment.isNotEmpty && segment != '.',
  );
  if (clean.isEmpty) {
    throw ArtifactInstallException('$context is empty');
  }
  return clean.join(Platform.pathSeparator);
}

bool _isAbsolutePortable(String path) {
  final portable = path.replaceAll(r'\', '/');
  return portable.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(portable);
}

String _resolveInside(Directory root, String relativePath) {
  final rootPath = _normalizedAbsolute(root.path);
  final resolved = _normalizedAbsolute(
    '$rootPath${Platform.pathSeparator}$relativePath',
  );
  if (!_isWithin(rootPath, resolved)) {
    throw ArtifactInstallException('Path escapes staging: $relativePath');
  }
  return resolved;
}

String _normalizedAbsolute(String path) {
  final absolute = File(path).absolute.path.replaceAll(r'\', '/');
  final prefix = absolute.startsWith('/') ? '/' : '';
  final segments = <String>[];
  for (final segment in absolute.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  return '$prefix${segments.join('/')}';
}

bool _isWithin(String root, String candidate) {
  return candidate == root || candidate.startsWith('$root/');
}

Future<void> _deleteIfExists(Directory directory) async {
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}
