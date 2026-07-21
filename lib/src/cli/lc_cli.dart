import 'dart:io';

import '../app_brand.dart';
import '../project_init/project_initializer.dart';

const _usage = '''用法:
  lc init <project-name>  创建 Flutter + Gin-Vue-Admin 项目
  lc --version            显示版本
  lc --help               显示帮助
''';

Future<int> runLc(
  List<String> arguments, {
  required String currentDirectory,
  required ProjectInitializer initializer,
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
