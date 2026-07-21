import 'dart:convert';
import 'dart:io';

import '../compatibility/gin_vue_admin_compatibility.dart';
import '../compatibility/version_output_parser.dart';
import 'project_init_boundaries.dart';
import 'project_init_spec.dart';
import 'project_name.dart';

typedef ProjectInitProgressCallback = void Function(String message);

final class ProjectInitRequest {
  const ProjectInitRequest({
    required this.requestedName,
    required this.parentDirectory,
  });

  final String requestedName;
  final String parentDirectory;

  @override
  bool operator ==(Object other) {
    return other is ProjectInitRequest &&
        other.requestedName == requestedName &&
        other.parentDirectory == parentDirectory;
  }

  @override
  int get hashCode => Object.hash(requestedName, parentDirectory);
}

final class ProjectInitResult {
  const ProjectInitResult({
    required this.projectDirectory,
    required this.packageName,
    required this.databaseName,
  });

  final String projectDirectory;
  final String packageName;
  final String databaseName;
}

abstract interface class ProjectInitializer {
  Future<ProjectInitResult> initialize(
    ProjectInitRequest request, {
    ProjectInitProgressCallback? onProgress,
  });
}

final class ProjectInitException implements Exception {
  const ProjectInitException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class IoProjectInitializer implements ProjectInitializer {
  IoProjectInitializer({
    required ProjectProcessRunner processes,
    required ProjectHost host,
    ProjectSourcePreference sourcePreference =
        ProjectSourcePreference.automatic,
    String Function()? stagingNonce,
    Future<void> Function(Directory staging, Directory target)? commitDirectory,
  }) : _processes = processes,
       _host = host,
       _sourcePreference = sourcePreference,
       _commitDirectory = commitDirectory ?? _renameDirectory,
       _stagingNonce =
           stagingNonce ??
           (() => '${pid}_${DateTime.now().microsecondsSinceEpoch}');

  final ProjectProcessRunner _processes;
  final ProjectHost _host;
  final ProjectSourcePreference _sourcePreference;
  final Future<void> Function(Directory staging, Directory target)
  _commitDirectory;
  final String Function() _stagingNonce;

  @override
  Future<ProjectInitResult> initialize(
    ProjectInitRequest request, {
    ProjectInitProgressCallback? onProgress,
  }) async {
    final ProjectName name;
    try {
      name = ProjectName.parse(request.requestedName);
    } on ProjectNameException catch (error) {
      throw ProjectInitException(error.message);
    }

    final parent = Directory(request.parentDirectory);
    final target = Directory(_join(parent.path, name.directoryName));
    final targetFile = File(target.path);
    if (await targetFile.exists()) {
      throw const ProjectInitException('目标路径已经存在，并且不是文件夹');
    }
    final targetAlreadyExists = await target.exists();
    if (targetAlreadyExists && !await target.list().isEmpty) {
      throw const ProjectInitException('目标文件夹不是空的，请换一个项目名');
    }

    await _verifyToolchain(onProgress);
    final staging = Directory(
      _join(
        parent.path,
        '.${name.directoryName}.lc-staging-${_stagingNonce()}',
      ),
    );
    if (await staging.exists() || await File(staging.path).exists()) {
      throw const ProjectInitException('项目暂存路径已存在，请重试');
    }

    await staging.create(recursive: true);
    var restoreEmptyTarget = false;
    try {
      await _createFlutterProject(staging, name, onProgress);
      await _cloneGinVueAdmin(staging, onProgress);
      await _verifyGinVueAdminCommit(staging);

      final nestedRepository = Directory(_join(staging.path, 'admin/.git'));
      if (await nestedRepository.exists()) {
        await nestedRepository.delete(recursive: true);
      }
      await _createLocalServerConfig(staging);
      await _prepareDependencies(staging, onProgress);
      await _writeMetadata(staging, name);
      await _runRequired(
        ProjectCommand(
          executable: _gitExecutable,
          arguments: const ['init'],
          workingDirectory: staging.path,
          runInShell: _runToolsInShell,
        ),
        '初始化项目版本库',
        onProgress,
      );

      if (targetAlreadyExists) {
        await target.delete();
        restoreEmptyTarget = true;
      }
      await _commitDirectory(staging, target);
      restoreEmptyTarget = false;
      return ProjectInitResult(
        projectDirectory: target.path,
        packageName: name.packageName,
        databaseName: name.databaseName,
      );
    } on ProjectInitException {
      await _deleteStaging(staging);
      await _restoreEmptyTarget(target, restoreEmptyTarget);
      rethrow;
    } on Object catch (error) {
      await _deleteStaging(staging);
      await _restoreEmptyTarget(target, restoreEmptyTarget);
      throw ProjectInitException('项目生成未完成: $error');
    }
  }

  Future<void> _verifyToolchain(ProjectInitProgressCallback? onProgress) async {
    onProgress?.call('正在检查 Flutter、Git、Go、Node.js 和 npm...');
    for (final check in <(String, List<String>, String)>[
      (_flutterExecutable, const ['--version'], 'Flutter'),
      (_gitExecutable, const ['--version'], 'Git'),
      (_goExecutable, const ['version'], 'Go'),
      (_nodeExecutable, const ['--version'], 'Node.js'),
      (_npmExecutable, const ['--version'], 'npm'),
    ]) {
      final result = await _runRequired(
        ProjectCommand(
          executable: check.$1,
          arguments: check.$2,
          runInShell: _runToolsInShell,
        ),
        '检查 ${check.$3}',
        onProgress,
      );
      _verifyCompatibleVersion(check.$3, result);
    }
  }

  void _verifyCompatibleVersion(String tool, ProjectProcessResult result) {
    final parser = const VersionOutputParser();
    final output = '${result.stdout}\n${result.stderr}';
    if (tool == 'Go') {
      final installed = parser.extract(SoftwareComponent.go, output);
      if (installed == null || !ginVueAdminGoIsCompatible(installed)) {
        throw const ProjectInitException('Go 版本不兼容，需要 1.24.2 或更高版本');
      }
    }
    if (tool == 'Node.js') {
      final installed = parser.extract(SoftwareComponent.node, output);
      if (installed == null || !ginVueAdminNodeIsCompatible(installed)) {
        throw const ProjectInitException(
          'Node.js 版本不兼容，需要 20.19.x 或 22.12.0 以上版本',
        );
      }
    }
  }

  Future<void> _createFlutterProject(
    Directory staging,
    ProjectName name,
    ProjectInitProgressCallback? onProgress,
  ) async {
    final platforms = ['android', 'web', 'windows'];
    if (_host.operatingSystem == ProjectHostOperatingSystem.macos &&
        _host.hasXcode) {
      platforms.addAll(['ios', 'macos']);
    }
    await _runRequired(
      ProjectCommand(
        executable: _flutterExecutable,
        arguments: [
          'create',
          '--no-pub',
          '--project-name',
          name.packageName,
          '--platforms',
          platforms.join(','),
          'client',
        ],
        workingDirectory: staging.path,
        runInShell: _runToolsInShell,
      ),
      '创建 Flutter 客户端',
      onProgress,
    );
  }

  Future<void> _cloneGinVueAdmin(
    Directory staging,
    ProjectInitProgressCallback? onProgress,
  ) async {
    ProjectProcessResult? lastResult;
    for (final repository in _repositories) {
      final admin = Directory(_join(staging.path, 'admin'));
      if (await admin.exists()) await admin.delete(recursive: true);
      onProgress?.call('正在获取 Gin-Vue-Admin $ginVueAdminTag...');
      lastResult = await _processes.run(
        ProjectCommand(
          executable: _gitExecutable,
          arguments: [
            'clone',
            '--depth',
            '1',
            '--branch',
            ginVueAdminTag,
            '--single-branch',
            repository,
            'admin',
          ],
          workingDirectory: staging.path,
          runInShell: _runToolsInShell,
        ),
        onOutput: onProgress,
      );
      if (lastResult.exitCode == 0) return;
    }
    throw ProjectInitException(
      '下载 Gin-Vue-Admin 失败: ${_failureText(lastResult!)}',
    );
  }

  Future<void> _verifyGinVueAdminCommit(Directory staging) async {
    final result = await _processes.run(
      ProjectCommand(
        executable: _gitExecutable,
        arguments: const ['rev-parse', 'HEAD'],
        workingDirectory: _join(staging.path, 'admin'),
        runInShell: _runToolsInShell,
      ),
    );
    if (result.exitCode != 0 || result.stdout.trim() != ginVueAdminCommit) {
      throw const ProjectInitException('Gin-Vue-Admin 版本校验失败，已停止生成项目');
    }
  }

  Future<void> _createLocalServerConfig(Directory staging) async {
    final server = Directory(_join(staging.path, 'admin/server'));
    final source = File(_join(server.path, 'config.yaml'));
    if (!await source.exists()) {
      throw const ProjectInitException('Gin-Vue-Admin 缺少 server/config.yaml');
    }
    await source.copy(_join(server.path, 'config.lc.local.yaml'));
  }

  Future<void> _prepareDependencies(
    Directory staging,
    ProjectInitProgressCallback? onProgress,
  ) async {
    await _runDependencyCommand(
      label: '安装 Flutter 依赖',
      command: (mirror) => ProjectCommand(
        executable: _flutterExecutable,
        arguments: const ['pub', 'get'],
        workingDirectory: _join(staging.path, 'client'),
        environment: _dependencyEnvironment(mirror: mirror),
        runInShell: _runToolsInShell,
      ),
      onProgress: onProgress,
    );
    await _runDependencyCommand(
      label: '安装 Go 依赖',
      command: (mirror) => ProjectCommand(
        executable: _goExecutable,
        arguments: const ['mod', 'download'],
        workingDirectory: _join(staging.path, 'admin/server'),
        environment: _dependencyEnvironment(mirror: mirror),
        runInShell: _runToolsInShell,
      ),
      onProgress: onProgress,
    );
    await _runDependencyCommand(
      label: '安装管理端依赖',
      command: (mirror) => ProjectCommand(
        executable: _npmExecutable,
        arguments: [
          'install',
          '--no-audit',
          '--no-fund',
          if (mirror) '--registry=https://registry.npmmirror.com',
        ],
        workingDirectory: _join(staging.path, 'admin/web'),
        runInShell: _runToolsInShell,
      ),
      beforeRetry: () => _clearNpmPartialInstall(staging),
      onProgress: onProgress,
    );
  }

  Future<void> _runDependencyCommand({
    required String label,
    required ProjectCommand Function(bool mirror) command,
    required ProjectInitProgressCallback? onProgress,
    Future<void> Function()? beforeRetry,
  }) async {
    ProjectProcessResult? lastResult;
    for (var index = 0; index < _dependencyMirrorOrder.length; index++) {
      final mirror = _dependencyMirrorOrder[index];
      onProgress?.call(
        index == 0 ? '$label...' : '$label：切换到${mirror ? '国内镜像' : '官方源'}重试...',
      );
      lastResult = await _processes.run(command(mirror), onOutput: onProgress);
      if (lastResult.exitCode == 0) return;
      if (index + 1 < _dependencyMirrorOrder.length && beforeRetry != null) {
        await beforeRetry();
      }
    }
    throw ProjectInitException('$label 失败: ${_failureText(lastResult!)}');
  }

  Future<void> _clearNpmPartialInstall(Directory staging) async {
    final web = Directory(_join(staging.path, 'admin/web'));
    final modules = Directory(_join(web.path, 'node_modules'));
    final lockFile = File(_join(web.path, 'package-lock.json'));
    if (await modules.exists()) await modules.delete(recursive: true);
    if (await lockFile.exists()) await lockFile.delete();
  }

  Future<void> _writeMetadata(Directory staging, ProjectName name) async {
    final metadata = <String, Object?>{
      'schemaVersion': 1,
      'name': name.directoryName,
      'packageName': name.packageName,
      'databaseName': name.databaseName,
      'clientPath': 'client',
      'adminPath': 'admin',
      'ginVueAdminTag': ginVueAdminTag,
      'ginVueAdminCommit': ginVueAdminCommit,
      'backend': {
        'workingDirectory': 'admin/server',
        'command': ['go', 'run', '.', '-c', 'config.lc.local.yaml'],
      },
      'frontend': {
        'workingDirectory': 'admin/web',
        'command': ['npm', 'run', 'serve'],
      },
    };
    const encoder = JsonEncoder.withIndent('  ');
    await File(
      _join(staging.path, 'lc-project.json'),
    ).writeAsString('${encoder.convert(metadata)}\n', flush: true);
  }

  Future<ProjectProcessResult> _runRequired(
    ProjectCommand command,
    String label,
    ProjectInitProgressCallback? onProgress,
  ) async {
    onProgress?.call('$label...');
    final result = await _processes.run(command, onOutput: onProgress);
    if (result.exitCode != 0) {
      throw ProjectInitException('$label 失败: ${_failureText(result)}');
    }
    return result;
  }

  Future<void> _deleteStaging(Directory staging) async {
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  Future<void> _restoreEmptyTarget(
    Directory target,
    bool restoreEmptyTarget,
  ) async {
    if (restoreEmptyTarget && !await target.exists()) {
      await target.create(recursive: true);
    }
  }

  List<String> get _repositories => switch (_sourcePreference) {
    ProjectSourcePreference.officialOnly => [ginVueAdminRepository],
    ProjectSourcePreference.mirrorFirst => [
      ginVueAdminChinaMirror,
      ginVueAdminRepository,
    ],
    ProjectSourcePreference.automatic => [
      ginVueAdminRepository,
      ginVueAdminChinaMirror,
    ],
  };

  List<bool> get _dependencyMirrorOrder => switch (_sourcePreference) {
    ProjectSourcePreference.officialOnly => const [false],
    ProjectSourcePreference.mirrorFirst => const [true, false],
    ProjectSourcePreference.automatic => const [false, true],
  };

  Map<String, String> _dependencyEnvironment({required bool mirror}) {
    if (!mirror) return const {};
    return const {
      'PUB_HOSTED_URL': 'https://pub.flutter-io.cn',
      'FLUTTER_STORAGE_BASE_URL': 'https://storage.flutter-io.cn',
      'GOPROXY': 'https://goproxy.cn,direct',
    };
  }

  bool get _runToolsInShell =>
      _host.operatingSystem == ProjectHostOperatingSystem.windows;
  String get _flutterExecutable => _runToolsInShell ? 'flutter.bat' : 'flutter';
  String get _gitExecutable => _runToolsInShell ? 'git.exe' : 'git';
  String get _goExecutable => _runToolsInShell ? 'go.exe' : 'go';
  String get _nodeExecutable => _runToolsInShell ? 'node.exe' : 'node';
  String get _npmExecutable => _runToolsInShell ? 'npm.cmd' : 'npm';
}

String _failureText(ProjectProcessResult result) {
  final stderr = result.stderr.trim();
  if (stderr.isNotEmpty) return stderr;
  final stdout = result.stdout.trim();
  if (stdout.isNotEmpty) return stdout;
  return '进程退出码 ${result.exitCode}';
}

String _join(String parent, String child) {
  if (parent.endsWith('/') || parent.endsWith(r'\')) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}

Future<void> _renameDirectory(Directory staging, Directory target) async {
  await staging.rename(target.path);
}
