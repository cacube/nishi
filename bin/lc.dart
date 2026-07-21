import 'dart:io';

import 'package:dev_environment_manager/src/cli/lc_cli.dart';
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
  );
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
}
