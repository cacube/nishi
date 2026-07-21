import 'package:dev_environment_manager/src/cli/lc_cli.dart';
import 'package:dev_environment_manager/src/project_init/project_initializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RecordingInitializer initializer;
  late StringBuffer output;
  late StringBuffer errors;

  setUp(() {
    initializer = _RecordingInitializer();
    output = StringBuffer();
    errors = StringBuffer();
  });

  Future<int> run(List<String> arguments) {
    return runLc(
      arguments,
      currentDirectory: '/workspace',
      initializer: initializer,
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

    output.clear();
    expect(await run(['--version']), 0);
    expect(output.toString(), contains('lc 1.0.0'));
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
