import 'dart:convert';
import 'dart:io';

import '../project_init/project_init_boundaries.dart';

abstract interface class LcProjectCommands {
  Future<int> run(
    List<String> arguments, {
    required String currentDirectory,
    required StringSink stdoutSink,
    required StringSink stderrSink,
  });
}

final class LcProjectCommandRunner implements LcProjectCommands {
  const LcProjectCommandRunner({
    required this.processes,
    required this.sourcePreference,
    required this.isWindows,
  });

  final ProjectProcessRunner processes;
  final ProjectSourcePreference sourcePreference;
  final bool isWindows;

  @override
  Future<int> run(
    List<String> arguments, {
    required String currentDirectory,
    required StringSink stdoutSink,
    required StringSink stderrSink,
  }) async {
    if (arguments.isEmpty ||
        !const {
          'dev',
          'deps',
          'build',
          'test',
          'clean',
          'doctor',
          'flutter',
          'go',
          'npm',
        }.contains(arguments.first)) {
      stderrSink.writeln('不支持的项目命令');
      return 2;
    }

    if (arguments.first == 'doctor') {
      if (arguments.length != 1) {
        stderrSink.writeln('用法: lc doctor');
        return 2;
      }
      return _runDoctor(stdoutSink, stderrSink);
    }

    try {
      final project = await _LcProject.discover(currentDirectory);
      if (arguments.first == 'deps') {
        return await _runDependencies(
          project,
          arguments.skip(1).toList(),
          stdoutSink,
          stderrSink,
        );
      }
      if (arguments.first == 'clean') {
        return await _runClean(
          project,
          arguments.skip(1).toList(),
          stdoutSink,
          stderrSink,
        );
      }
      final commands = switch (arguments.first) {
        'dev' => _devCommands(project, arguments.skip(1).toList()),
        'build' => [_buildCommand(project, arguments.skip(1).toList())],
        'test' => _testCommands(project, arguments.skip(1).toList()),
        'flutter' || 'go' || 'npm' => [
          _nativeCommand(project, arguments.first, arguments.skip(1).toList()),
        ],
        _ => throw StateError('unreachable'),
      };
      final results = await Future.wait(
        commands.map(
          (command) => processes.run(command, onOutput: stdoutSink.write),
        ),
      );
      return results.any((result) => result.exitCode != 0) ? 1 : 0;
    } on _LcProjectException catch (error) {
      stderrSink.writeln(error.message);
      return 1;
    } on ProcessException catch (error) {
      stderrSink.writeln('无法启动命令: ${error.message}');
      return 1;
    }
  }

  Future<int> _runClean(
    _LcProject project,
    List<String> arguments,
    StringSink output,
    StringSink errors,
  ) async {
    if (arguments.length > 1) {
      throw const _LcProjectException('用法: lc clean [all|client|server|admin]');
    }
    final target = arguments.isEmpty ? 'all' : arguments.single;
    if (!const {'all', 'client', 'server', 'admin'}.contains(target)) {
      throw _LcProjectException('未知清理目标: $target');
    }
    final commands = <ProjectCommand>[
      if (target == 'all' || target == 'client')
        ProjectCommand(
          executable: _tool('flutter'),
          arguments: const ['clean'],
          workingDirectory: project.clientDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
      if (target == 'all' || target == 'server')
        ProjectCommand(
          executable: 'go',
          arguments: const ['clean'],
          workingDirectory: project.backendDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
    ];
    final results = await Future.wait(
      commands.map((command) => processes.run(command, onOutput: output.write)),
    );
    if (target == 'all' || target == 'admin') {
      final dist = Directory(
        '${project.frontendDirectory}${Platform.pathSeparator}dist',
      );
      if (await dist.exists()) await dist.delete(recursive: true);
      output.writeln('已清理 admin 构建产物。');
    }
    if (results.any((result) => result.exitCode != 0)) {
      errors.writeln('清理命令执行失败。');
      return 1;
    }
    return 0;
  }

  Future<int> _runDoctor(StringSink output, StringSink errors) async {
    final probes = <({String label, ProjectCommand command, bool required})>[
      (
        label: 'Flutter / Android',
        command: ProjectCommand(
          executable: _tool('flutter'),
          arguments: const ['doctor', '-v'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'JDK',
        command: ProjectCommand(
          executable: 'java',
          arguments: const ['-version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'Android SDK',
        command: ProjectCommand(
          executable: 'adb',
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'Go',
        command: ProjectCommand(
          executable: 'go',
          arguments: const ['version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'Node.js',
        command: ProjectCommand(
          executable: 'node',
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'npm',
        command: ProjectCommand(
          executable: _tool('npm'),
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'MySQL',
        command: ProjectCommand(
          executable: 'mysql',
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'Git',
        command: ProjectCommand(
          executable: 'git',
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: true,
      ),
      (
        label: 'Redis（可选）',
        command: ProjectCommand(
          executable: 'redis-server',
          arguments: const ['--version'],
          runInShell: isWindows,
          captureOutput: false,
        ),
        required: false,
      ),
      if (!isWindows)
        (
          label: 'Xcode（可选）',
          command: const ProjectCommand(
            executable: 'xcodebuild',
            arguments: ['-version'],
            captureOutput: false,
          ),
          required: false,
        ),
    ];

    var failedRequiredProbe = false;
    for (final probe in probes) {
      output.writeln('\n[${probe.label}]');
      try {
        final result = await processes.run(
          probe.command,
          onOutput: output.write,
        );
        if (result.exitCode != 0) {
          if (probe.required) failedRequiredProbe = true;
          errors.writeln('${probe.label} 检查失败。');
        }
      } on ProcessException catch (error) {
        if (probe.required) failedRequiredProbe = true;
        errors.writeln('${probe.label} 未找到: ${error.message}');
      }
    }
    if (!failedRequiredProbe) output.writeln('\n开发环境检查完成。');
    return failedRequiredProbe ? 1 : 0;
  }

  List<ProjectCommand> _testCommands(
    _LcProject project,
    List<String> arguments,
  ) {
    final target = arguments.isEmpty ? 'all' : arguments.first;
    final extraArguments = arguments.isEmpty
        ? const <String>[]
        : arguments.sublist(1);
    if (target == 'all' && extraArguments.isNotEmpty) {
      throw const _LcProjectException(
        'lc test all 不能共用额外参数，请分别运行 client 或 server 测试。',
      );
    }
    if (!const {'all', 'client', 'server'}.contains(target)) {
      throw _LcProjectException('未知测试目标: $target');
    }
    return [
      if (target == 'all' || target == 'client')
        ProjectCommand(
          executable: _tool('flutter'),
          arguments: ['test', if (target == 'client') ...extraArguments],
          workingDirectory: project.clientDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
      if (target == 'all' || target == 'server')
        ProjectCommand(
          executable: 'go',
          arguments: [
            'test',
            if (target == 'server') ...extraArguments,
            './...',
          ],
          workingDirectory: project.backendDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
    ];
  }

  Future<int> _runDependencies(
    _LcProject project,
    List<String> arguments,
    StringSink output,
    StringSink errors,
  ) async {
    if (arguments.length > 1) {
      throw const _LcProjectException('用法: lc deps [all|client|server|admin]');
    }
    final target = arguments.isEmpty ? 'all' : arguments.single;
    if (!const {'all', 'client', 'server', 'admin'}.contains(target)) {
      throw _LcProjectException('未知依赖目标: $target');
    }
    final targets = target == 'all'
        ? const ['client', 'server', 'admin']
        : [target];
    for (final current in targets) {
      final succeeded = await _runDependencyTarget(project, current, output);
      if (!succeeded) {
        errors.writeln('$current 依赖安装失败。');
        return 1;
      }
    }
    return 0;
  }

  Future<bool> _runDependencyTarget(
    _LcProject project,
    String target,
    StringSink output,
  ) async {
    final sourceOrder = switch (sourcePreference) {
      ProjectSourcePreference.automatic => const [false, true],
      ProjectSourcePreference.officialOnly => const [false],
      ProjectSourcePreference.mirrorFirst => const [true, false],
    };
    for (var index = 0; index < sourceOrder.length; index++) {
      final useMirror = sourceOrder[index];
      output.writeln(
        index == 0
            ? '正在安装 $target 依赖...'
            : '正在切换到${useMirror ? '国内镜像' : '官方源'}重试 $target...',
      );
      final result = await processes.run(
        _dependencyCommand(project, target, useMirror),
        onOutput: output.write,
      );
      if (result.exitCode == 0) return true;
    }
    return false;
  }

  ProjectCommand _dependencyCommand(
    _LcProject project,
    String target,
    bool useMirror,
  ) {
    return switch (target) {
      'client' => ProjectCommand(
        executable: _tool('flutter'),
        arguments: const ['pub', 'get'],
        workingDirectory: project.clientDirectory,
        environment: useMirror
            ? const {
                'PUB_HOSTED_URL': 'https://pub.flutter-io.cn',
                'FLUTTER_STORAGE_BASE_URL': 'https://storage.flutter-io.cn',
              }
            : const {},
        runInShell: isWindows,
        captureOutput: false,
      ),
      'server' => ProjectCommand(
        executable: 'go',
        arguments: const ['mod', 'download'],
        workingDirectory: project.backendDirectory,
        environment: useMirror
            ? const {'GOPROXY': 'https://goproxy.cn,direct'}
            : const {},
        runInShell: isWindows,
        captureOutput: false,
      ),
      'admin' => ProjectCommand(
        executable: _tool('npm'),
        arguments: [
          'install',
          if (useMirror) '--registry=https://registry.npmmirror.com',
        ],
        workingDirectory: project.frontendDirectory,
        runInShell: isWindows,
        captureOutput: false,
      ),
      _ => throw StateError('unsupported dependency target'),
    };
  }

  ProjectCommand _buildCommand(_LcProject project, List<String> arguments) {
    if (arguments.isEmpty) {
      throw const _LcProjectException(
        '请指定构建目标：android、apk、appbundle、web、windows、macos、ios、server 或 admin。',
      );
    }
    final target = arguments.first;
    final extraArguments = arguments.sublist(1);
    if (const {
      'android',
      'apk',
      'appbundle',
      'web',
      'windows',
      'macos',
      'ios',
    }.contains(target)) {
      final flutterTarget = target == 'android' ? 'apk' : target;
      return ProjectCommand(
        executable: _tool('flutter'),
        arguments: ['build', flutterTarget, ...extraArguments],
        workingDirectory: project.clientDirectory,
        runInShell: isWindows,
        captureOutput: false,
      );
    }
    if (target == 'server') {
      return ProjectCommand(
        executable: 'go',
        arguments: ['build', ...extraArguments, '.'],
        workingDirectory: project.backendDirectory,
        runInShell: isWindows,
        captureOutput: false,
      );
    }
    if (target == 'admin') {
      return ProjectCommand(
        executable: _tool('npm'),
        arguments: [
          'run',
          'build',
          if (extraArguments.isNotEmpty) '--',
          ...extraArguments,
        ],
        workingDirectory: project.frontendDirectory,
        runInShell: isWindows,
        captureOutput: false,
      );
    }
    throw _LcProjectException('未知构建目标: $target');
  }

  ProjectCommand _nativeCommand(
    _LcProject project,
    String tool,
    List<String> arguments,
  ) {
    final workingDirectory = switch (tool) {
      'flutter' => project.clientDirectory,
      'go' => project.backendDirectory,
      'npm' => project.frontendDirectory,
      _ => throw StateError('unsupported native tool'),
    };
    return ProjectCommand(
      executable: _tool(tool),
      arguments: arguments,
      workingDirectory: workingDirectory,
      runInShell: isWindows,
      captureOutput: false,
      forwardStdin: true,
    );
  }

  List<ProjectCommand> _devCommands(
    _LcProject project,
    List<String> arguments,
  ) {
    final target = arguments.isEmpty ? 'all' : arguments.first;
    final extraArguments = arguments.isEmpty
        ? const <String>[]
        : arguments.sublist(1);
    if (target == 'all' && extraArguments.isNotEmpty) {
      throw const _LcProjectException(
        'lc dev all 不能附带模块参数，请改用 lc dev client、server 或 admin。',
      );
    }

    final commands = <ProjectCommand>[
      if (target == 'all' || target == 'client')
        ProjectCommand(
          executable: _tool('flutter'),
          arguments: ['run', if (target == 'client') ...extraArguments],
          workingDirectory: project.clientDirectory,
          runInShell: isWindows,
          captureOutput: false,
          forwardStdin: true,
        ),
      if (target == 'all' || target == 'server')
        ProjectCommand(
          executable: 'go',
          arguments: [
            ...project.backendCommand.sublist(1),
            if (target == 'server') ...extraArguments,
          ],
          workingDirectory: project.backendDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
      if (target == 'all' || target == 'admin')
        ProjectCommand(
          executable: _tool('npm'),
          arguments: [
            ...project.frontendCommand.sublist(1),
            if (target == 'admin' && extraArguments.isNotEmpty) '--',
            if (target == 'admin') ...extraArguments,
          ],
          workingDirectory: project.frontendDirectory,
          runInShell: isWindows,
          captureOutput: false,
        ),
    ];
    if (commands.isEmpty) {
      throw const _LcProjectException('未知启动目标，只能使用 all、client、server 或 admin。');
    }
    return commands;
  }

  String _tool(String executable) {
    if (!isWindows) return executable;
    return switch (executable) {
      'flutter' => 'flutter.bat',
      'npm' => 'npm.cmd',
      _ => executable,
    };
  }
}

final class _LcProject {
  const _LcProject({
    required this.clientDirectory,
    required this.backendDirectory,
    required this.frontendDirectory,
    required this.backendCommand,
    required this.frontendCommand,
  });

  final String clientDirectory;
  final String backendDirectory;
  final String frontendDirectory;
  final List<String> backendCommand;
  final List<String> frontendCommand;

  static Future<_LcProject> discover(String currentDirectory) async {
    var directory = Directory(currentDirectory).absolute;
    while (true) {
      final metadata = File(
        '${directory.path}${Platform.pathSeparator}lc-project.json',
      );
      if (await metadata.exists()) return _read(directory, metadata);
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw const _LcProjectException(
          '当前目录不在 lc 项目中，请先进入包含 lc-project.json 的项目目录。',
        );
      }
      directory = parent;
    }
  }

  static Future<_LcProject> _read(Directory root, File metadata) async {
    try {
      final document = jsonDecode(await metadata.readAsString());
      if (document is! Map<String, dynamic> || document['schemaVersion'] != 1) {
        throw const FormatException('unsupported schema');
      }
      final backend = document['backend'];
      final frontend = document['frontend'];
      if (backend is! Map<String, dynamic> ||
          frontend is! Map<String, dynamic>) {
        throw const FormatException('missing modules');
      }
      final backendCommand = _stringList(backend, 'command');
      final frontendCommand = _stringList(frontend, 'command');
      if (backendCommand.first != 'go' || frontendCommand.first != 'npm') {
        throw const FormatException('unexpected module command');
      }
      return _LcProject(
        clientDirectory: await _safeDirectory(
          root,
          _string(document, 'clientPath'),
        ),
        backendDirectory: await _safeDirectory(
          root,
          _string(backend, 'workingDirectory'),
        ),
        frontendDirectory: await _safeDirectory(
          root,
          _string(frontend, 'workingDirectory'),
        ),
        backendCommand: backendCommand,
        frontendCommand: frontendCommand,
      );
    } on _LcProjectException {
      rethrow;
    } on Object {
      throw const _LcProjectException('lc-project.json 已损坏或版本不受支持。');
    }
  }

  static String _string(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('invalid $key');
    }
    return value;
  }

  static List<String> _stringList(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is! List ||
        value.isEmpty ||
        value.any((element) => element is! String || element.isEmpty)) {
      throw FormatException('invalid $key');
    }
    return value.cast<String>();
  }

  static Future<String> _safeDirectory(Directory root, String relative) async {
    final portable = relative.replaceAll('\\', '/');
    final segments = portable.split('/');
    if (portable.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(portable) ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      throw const FormatException('unsafe project path');
    }
    final target = Directory(_join(root.path, portable));
    if (!await target.exists()) {
      throw const FormatException('missing project directory');
    }
    final resolvedRoot = await root.resolveSymbolicLinks();
    final resolvedTarget = await target.resolveSymbolicLinks();
    if (!resolvedTarget.startsWith('$resolvedRoot${Platform.pathSeparator}')) {
      throw const FormatException('project path escapes root');
    }
    return target.path;
  }

  static String _join(String root, String relative) =>
      '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
}

final class _LcProjectException implements Exception {
  const _LcProjectException(this.message);

  final String message;
}
