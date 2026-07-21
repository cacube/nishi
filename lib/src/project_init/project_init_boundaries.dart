import 'dart:convert';
import 'dart:io';

typedef ProjectOutputCallback = void Function(String output);

final class ProjectCommand {
  const ProjectCommand({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.runInShell = false,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final bool runInShell;
}

final class ProjectProcessResult {
  const ProjectProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class ProjectProcessRunner {
  Future<ProjectProcessResult> run(
    ProjectCommand command, {
    ProjectOutputCallback? onOutput,
  });
}

final class IoProjectProcessRunner implements ProjectProcessRunner {
  const IoProjectProcessRunner();

  @override
  Future<ProjectProcessResult> run(
    ProjectCommand command, {
    ProjectOutputCallback? onOutput,
  }) async {
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      environment: command.environment.isEmpty ? null : command.environment,
      runInShell: command.runInShell,
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          stdoutBuffer.write(chunk);
          onOutput?.call(chunk);
        });
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          stderrBuffer.write(chunk);
          onOutput?.call(chunk);
        });
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    return ProjectProcessResult(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
    );
  }
}

enum ProjectHostOperatingSystem { windows, macos }

final class ProjectHost {
  const ProjectHost.windows()
    : operatingSystem = ProjectHostOperatingSystem.windows,
      hasXcode = false;

  const ProjectHost.macos({required this.hasXcode})
    : operatingSystem = ProjectHostOperatingSystem.macos;

  final ProjectHostOperatingSystem operatingSystem;
  final bool hasXcode;

  static Future<ProjectHost> current({
    ProjectProcessRunner processes = const IoProjectProcessRunner(),
  }) async {
    if (Platform.isWindows) return const ProjectHost.windows();
    if (!Platform.isMacOS) {
      throw UnsupportedError('lc CLI 仅支持 Windows 和 macOS');
    }
    final result = await processes.run(
      const ProjectCommand(
        executable: '/usr/bin/xcode-select',
        arguments: ['-p'],
      ),
    );
    return ProjectHost.macos(
      hasXcode: result.exitCode == 0 && result.stdout.trim().isNotEmpty,
    );
  }
}

enum ProjectSourcePreference { automatic, officialOnly, mirrorFirst }
