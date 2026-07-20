import 'dart:io';
import 'dart:typed_data';

enum ElevationRequirement { none, required }

final class ActivationCommand {
  const ActivationCommand({
    required this.executable,
    this.arguments = const [],
    this.environment = const {},
    this.workingDirectory,
    this.elevation = ElevationRequirement.none,
    this.acceptedExitCodes = const {0},
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
  final ElevationRequirement elevation;
  final Set<int> acceptedExitCodes;
}

final class ActivationCommandResult {
  const ActivationCommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class ActivationProcessRunner {
  Future<ActivationCommandResult> run(ActivationCommand command);
}

final class IoActivationProcessRunner implements ActivationProcessRunner {
  const IoActivationProcessRunner();

  @override
  Future<ActivationCommandResult> run(ActivationCommand command) async {
    if (command.elevation == ElevationRequirement.required) {
      throw StateError(
        'Command requires an explicitly elevated process: '
        '${command.executable}',
      );
    }
    final result = await Process.run(
      command.executable,
      command.arguments,
      environment: command.environment.isEmpty ? null : command.environment,
      workingDirectory: command.workingDirectory,
    );
    return ActivationCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}

abstract interface class ActivationFileStore {
  Future<Uint8List?> read(String path);

  Future<void> writeAtomically(String path, Uint8List contents);

  Future<void> delete(String path);
}

final class IoActivationFileStore implements ActivationFileStore {
  const IoActivationFileStore();

  @override
  Future<Uint8List?> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> writeAtomically(String path, Uint8List contents) async {
    final destination = File(path);
    await destination.parent.create(recursive: true);
    final nonce = '${pid.toString()}.${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File('$path.$nonce.tmp');
    final backup = File('$path.$nonce.backup');
    try {
      await temporary.writeAsBytes(contents, flush: true);
      try {
        await temporary.rename(path);
      } on FileSystemException {
        // Windows cannot consistently rename over an existing destination.
        // Keep the old document recoverable until the replacement is in place.
        if (!await destination.exists()) rethrow;
        await destination.rename(backup.path);
        try {
          await temporary.rename(path);
          await backup.delete();
        } on Object {
          if (await destination.exists()) await destination.delete();
          await backup.rename(path);
          rethrow;
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
