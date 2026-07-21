import 'dart:io';

import 'package:dev_environment_manager/src/cli/lc_cli.dart';
import 'package:dev_environment_manager/src/cli/lc_project_commands.dart';
import 'package:dev_environment_manager/src/project_init/project_init_boundaries.dart';
import 'package:dev_environment_manager/src/project_init/project_initializer.dart';
import 'package:dev_environment_manager/src/settings/settings_models.dart';
import 'package:dev_environment_manager/src/settings/settings_store.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runLc(
    arguments,
    currentDirectory: Directory.current.path,
    initializer: const _CurrentHostProjectInitializer(),
    projectCommands: const _CurrentHostProjectCommands(),
  );
}

final class _CurrentHostProjectCommands implements LcProjectCommands {
  const _CurrentHostProjectCommands();

  @override
  Future<int> run(
    List<String> arguments, {
    required String currentDirectory,
    required StringSink stdoutSink,
    required StringSink stderrSink,
  }) async {
    return LcProjectCommandRunner(
      processes: const IoProjectProcessRunner(),
      sourcePreference: await _loadSourcePreference(),
      isWindows: Platform.isWindows,
    ).run(
      arguments,
      currentDirectory: currentDirectory,
      stdoutSink: stdoutSink,
      stderrSink: stderrSink,
    );
  }
}

final class _CurrentHostProjectInitializer implements ProjectInitializer {
  const _CurrentHostProjectInitializer();

  @override
  Future<ProjectInitResult> initialize(
    ProjectInitRequest request, {
    ProjectInitProgressCallback? onProgress,
  }) async {
    const processes = IoProjectProcessRunner();
    try {
      final host = await ProjectHost.current(processes: processes);
      final sourcePreference = await _loadSourcePreference();
      return IoProjectInitializer(
        processes: processes,
        host: host,
        sourcePreference: sourcePreference,
      ).initialize(request, onProgress: onProgress);
    } on ProjectInitException {
      rethrow;
    } on Object catch (error) {
      throw ProjectInitException('无法启动项目生成器: $error');
    }
  }
}

Future<ProjectSourcePreference> _loadSourcePreference() async {
  try {
    final layout = RuntimeLayout.forCurrentUser();
    final settings = await JsonSettingsStore(
      File('${layout.root.path}${Platform.pathSeparator}settings.json'),
    ).load();
    return switch (settings.downloadSourcePreference) {
      DownloadSourcePreference.automatic => ProjectSourcePreference.automatic,
      DownloadSourcePreference.officialOnly =>
        ProjectSourcePreference.officialOnly,
      DownloadSourcePreference.mirrorFirst =>
        ProjectSourcePreference.mirrorFirst,
    };
  } on Object {
    return ProjectSourcePreference.automatic;
  }
}
