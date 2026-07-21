import 'dart:io';

import '../app_brand.dart';
import '../project_init/project_initializer.dart';
import 'lc_project_commands.dart';

const _projectCommands = {
  'dev',
  'deps',
  'build',
  'test',
  'clean',
  'doctor',
  'flutter',
  'go',
  'npm',
};

const _usage = '''用法:
  lc init <project-name>  创建 Flutter + Gin-Vue-Admin 项目
  lc dev [all|client|server|admin]
                          启动整套项目或指定模块
  lc deps [all|client|server|admin]
                          安装依赖，失败时按设置切换下载源
  lc build <target>       构建 Flutter 平台、server 或 admin
  lc test [all|client|server]
                          运行 Flutter / Go 测试
  lc clean [all|client|server|admin]
                          清理构建产物
  lc doctor               检查完整开发环境
  lc flutter <args...>    在 client 中运行 Flutter 命令
  lc go <args...>         在 admin/server 中运行 Go 命令
  lc npm <args...>        在 admin/web 中运行 npm 命令
  lc --version            显示版本
  lc --help               显示帮助
''';

Future<int> runLc(
  List<String> arguments, {
  required String currentDirectory,
  required ProjectInitializer initializer,
  required LcProjectCommands projectCommands,
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) async {
  final output = stdoutSink ?? stdout;
  final errors = stderrSink ?? stderr;

  if (arguments.length == 1 &&
      (arguments.single == '--help' || arguments.single == '-h')) {
    output.write(_usage);
    return 0;
  }
  if (arguments.length == 1 && arguments.single == '--version') {
    output.writeln('$applicationName $applicationVersion');
    return 0;
  }
  if (arguments.isNotEmpty && _projectCommands.contains(arguments.first)) {
    return projectCommands.run(
      arguments,
      currentDirectory: currentDirectory,
      stdoutSink: output,
      stderrSink: errors,
    );
  }
  if (arguments.length != 2 || arguments.first != 'init') {
    errors.write(_usage);
    return 2;
  }

  try {
    final result = await initializer.initialize(
      ProjectInitRequest(
        requestedName: arguments[1],
        parentDirectory: currentDirectory,
      ),
      onProgress: output.writeln,
    );
    output.writeln('项目已创建: ${result.projectDirectory}');
    return 0;
  } on ProjectInitException catch (error) {
    errors.writeln('创建失败: ${error.message}');
    return 1;
  }
}
