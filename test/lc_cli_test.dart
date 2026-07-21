import 'package:dev_environment_manager/src/cli/lc_cli.dart';
import 'package:dev_environment_manager/src/cli/lc_project_commands.dart';
import 'package:dev_environment_manager/src/project_init/project_initializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RecordingInitializer initializer;
  late _RecordingProjectCommands projectCommands;
  late StringBuffer output;
  late StringBuffer errors;

  setUp(() {
    initializer = _RecordingInitializer();
    projectCommands = _RecordingProjectCommands();
    output = StringBuffer();
    errors = StringBuffer();
  });

  Future<int> run(List<String> arguments) {
    return runLc(
      arguments,
      currentDirectory: '/workspace',
      initializer: initializer,
      projectCommands: projectCommands,
      stdoutSink: output,
      stderrSink: errors,
    );
  }

  test('init delegates one project name to the initializer', () async {
    final result = await run(['init', 'my-app']);

    expect(result, 0);
    expect(initializer.requests, [
      const ProjectInitRequest(
        requestedName: 'my-app',
        parentDirectory: '/workspace',
      ),
    ]);
    expect(output.toString(), contains('my-app'));
    expect(errors.toString(), isEmpty);
  });

  test('help and version do not initialize a project', () async {
    expect(await run(['--help']), 0);
    expect(output.toString(), contains('lc init <project-name>'));
    expect(output.toString(), contains('lc dev [all|client|server|admin]'));
    expect(output.toString(), contains('lc deps [all|client|server|admin]'));
    expect(output.toString(), contains('lc build <target>'));
    expect(output.toString(), contains('lc doctor'));
    expect(output.toString(), contains('lc flutter <args...>'));

    output.clear();
    expect(await run(['--version']), 0);
    expect(output.toString(), contains('lc 1.0.0'));
    expect(initializer.requests, isEmpty);
    expect(projectCommands.arguments, isEmpty);
  });

  test('development commands delegate to the project command runner', () async {
    expect(await run(['dev', 'server']), 0);

    expect(projectCommands.arguments, [
      ['dev', 'server'],
    ]);
    expect(projectCommands.currentDirectories, ['/workspace']);
    expect(initializer.requests, isEmpty);
  });

  test('invalid command syntax returns a usage error', () async {
    for (final arguments in <List<String>>[
      const [],
      const ['init'],
      const ['init', 'one', 'two'],
      const ['unknown'],
    ]) {
      expect(await run(arguments), 2);
    }

    expect(initializer.requests, isEmpty);
    expect(errors.toString(), contains('用法'));
  });
}

final class _RecordingInitializer implements ProjectInitializer {
  final List<ProjectInitRequest> requests = [];

  @override
  Future<ProjectInitResult> initialize(
    ProjectInitRequest request, {
    ProjectInitProgressCallback? onProgress,
  }) async {
    requests.add(request);
    onProgress?.call('正在创建 ${request.requestedName}');
    return ProjectInitResult(
      projectDirectory: '${request.parentDirectory}/${request.requestedName}',
      packageName: 'my_app',
      databaseName: 'my_app',
    );
  }
}

final class _RecordingProjectCommands implements LcProjectCommands {
  final List<List<String>> arguments = [];
  final List<String> currentDirectories = [];

  @override
  Future<int> run(
    List<String> arguments, {
    required String currentDirectory,
    required StringSink stdoutSink,
    required StringSink stderrSink,
  }) async {
    this.arguments.add(arguments);
    currentDirectories.add(currentDirectory);
    return 0;
  }
}
