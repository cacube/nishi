import 'dart:convert';
import 'dart:io';

import 'package:dev_environment_manager/src/cli/lc_project_commands.dart';
import 'package:dev_environment_manager/src/project_init/project_init_boundaries.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory project;
  late _RecordingProcesses processes;
  late StringBuffer output;
  late StringBuffer errors;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('lc-commands-');
    await Directory('${project.path}/client').create();
    await Directory('${project.path}/admin/server').create(recursive: true);
    await Directory('${project.path}/admin/web').create(recursive: true);
    await File('${project.path}/lc-project.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'name': 'demo',
        'clientPath': 'client',
        'adminPath': 'admin',
        'backend': {
          'workingDirectory': 'admin/server',
          'command': ['go', 'run', '.', '-c', 'config.lc.local.yaml'],
        },
        'frontend': {
          'workingDirectory': 'admin/web',
          'command': ['npm', 'run', 'serve'],
        },
      }),
    );
    processes = _RecordingProcesses();
    output = StringBuffer();
    errors = StringBuffer();
  });

  tearDown(() async {
    await project.delete(recursive: true);
  });

  test('dev discovers the project root and starts all three modules', () async {
    final runner = LcProjectCommandRunner(
      processes: processes,
      sourcePreference: ProjectSourcePreference.automatic,
      isWindows: false,
    );

    final result = await runner.run(
      const ['dev'],
      currentDirectory: '${project.path}/admin/server',
      stdoutSink: output,
      stderrSink: errors,
    );

    expect(result, 0);
    expect(processes.commands, hasLength(3));
    expect(processes.commands[0].executable, 'flutter');
    expect(processes.commands[0].arguments, ['run']);
    expect(processes.commands[0].workingDirectory, '${project.path}/client');
    expect(processes.commands[1].executable, 'go');
    expect(processes.commands[1].arguments, [
      'run',
      '.',
      '-c',
      'config.lc.local.yaml',
    ]);
    expect(
      processes.commands[1].workingDirectory,
      '${project.path}/admin/server',
    );
    expect(processes.commands[2].executable, 'npm');
    expect(processes.commands[2].arguments, ['run', 'serve']);
    expect(processes.commands[2].workingDirectory, '${project.path}/admin/web');
    expect(errors.toString(), isEmpty);
  });

  test(
    'dev client forwards Flutter arguments with Windows tool names',
    () async {
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: true,
      );

      final result = await runner.run(
        const ['dev', 'client', '-d', 'chrome'],
        currentDirectory: project.path,
        stdoutSink: output,
        stderrSink: errors,
      );

      expect(result, 0);
      expect(processes.commands, hasLength(1));
      expect(processes.commands.single.executable, 'flutter.bat');
      expect(processes.commands.single.arguments, ['run', '-d', 'chrome']);
      expect(processes.commands.single.runInShell, isTrue);
      expect(processes.commands.single.forwardStdin, isTrue);
    },
  );

  test(
    'native wrappers forward every argument from the correct module',
    () async {
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: false,
      );

      for (final arguments in <List<String>>[
        ['flutter', 'pub', 'add', 'dio'],
        ['go', 'generate', './...'],
        ['npm', 'run', 'lint', '--', '--fix'],
      ]) {
        expect(
          await runner.run(
            arguments,
            currentDirectory: '${project.path}/client',
            stdoutSink: output,
            stderrSink: errors,
          ),
          0,
        );
      }

      expect(processes.commands.map((command) => command.executable), [
        'flutter',
        'go',
        'npm',
      ]);
      expect(processes.commands[0].arguments, ['pub', 'add', 'dio']);
      expect(processes.commands[0].forwardStdin, isTrue);
      expect(processes.commands[0].workingDirectory, '${project.path}/client');
      expect(processes.commands[1].arguments, ['generate', './...']);
      expect(
        processes.commands[1].workingDirectory,
        '${project.path}/admin/server',
      );
      expect(processes.commands[2].arguments, ['run', 'lint', '--', '--fix']);
      expect(
        processes.commands[2].workingDirectory,
        '${project.path}/admin/web',
      );
    },
  );

  test('build maps platform, server, and admin targets', () async {
    final runner = LcProjectCommandRunner(
      processes: processes,
      sourcePreference: ProjectSourcePreference.automatic,
      isWindows: false,
    );

    for (final arguments in <List<String>>[
      ['build', 'web', '--release'],
      ['build', 'server', '--tags', 'production'],
      ['build', 'admin', '--mode', 'production'],
    ]) {
      expect(
        await runner.run(
          arguments,
          currentDirectory: project.path,
          stdoutSink: output,
          stderrSink: errors,
        ),
        0,
      );
    }

    expect(processes.commands[0].executable, 'flutter');
    expect(processes.commands[0].arguments, ['build', 'web', '--release']);
    expect(processes.commands[1].executable, 'go');
    expect(processes.commands[1].arguments, [
      'build',
      '--tags',
      'production',
      '.',
    ]);
    expect(processes.commands[2].executable, 'npm');
    expect(processes.commands[2].arguments, [
      'run',
      'build',
      '--',
      '--mode',
      'production',
    ]);
  });

  test(
    'deps retries each failed official source with its China mirror',
    () async {
      processes.exitCodesByTool.addAll({
        'flutter': [1, 0],
        'go': [1, 0],
        'npm': [1, 0],
      });
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: false,
      );

      final result = await runner.run(
        const ['deps'],
        currentDirectory: project.path,
        stdoutSink: output,
        stderrSink: errors,
      );

      expect(result, 0);
      expect(processes.commands, hasLength(6));
      expect(processes.commands[0].arguments, ['pub', 'get']);
      expect(processes.commands[0].environment, isEmpty);
      expect(
        processes.commands[1].environment['PUB_HOSTED_URL'],
        'https://pub.flutter-io.cn',
      );
      expect(processes.commands[2].arguments, ['mod', 'download']);
      expect(processes.commands[2].environment, isEmpty);
      expect(
        processes.commands[3].environment['GOPROXY'],
        'https://goproxy.cn,direct',
      );
      expect(processes.commands[4].arguments, ['install']);
      expect(processes.commands[5].arguments, [
        'install',
        '--registry=https://registry.npmmirror.com',
      ]);
    },
  );

  test('test runs Flutter and Go suites by default', () async {
    final runner = LcProjectCommandRunner(
      processes: processes,
      sourcePreference: ProjectSourcePreference.automatic,
      isWindows: false,
    );

    final result = await runner.run(
      const ['test'],
      currentDirectory: project.path,
      stdoutSink: output,
      stderrSink: errors,
    );

    expect(result, 0);
    expect(processes.commands, hasLength(2));
    expect(processes.commands[0].executable, 'flutter');
    expect(processes.commands[0].arguments, ['test']);
    expect(processes.commands[1].executable, 'go');
    expect(processes.commands[1].arguments, ['test', './...']);
  });

  test(
    'doctor checks the full toolchain without requiring a project',
    () async {
      final outsideProject = await Directory.systemTemp.createTemp(
        'lc-doctor-',
      );
      addTearDown(() => outsideProject.delete(recursive: true));
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: false,
      );

      final result = await runner.run(
        const ['doctor'],
        currentDirectory: outsideProject.path,
        stdoutSink: output,
        stderrSink: errors,
      );

      expect(result, 0);
      expect(processes.commands.map((command) => command.executable), [
        'flutter',
        'java',
        'adb',
        'go',
        'node',
        'npm',
        'mysql',
        'git',
        'redis-server',
        'xcodebuild',
      ]);
      expect(processes.commands.first.arguments, ['doctor', '-v']);
    },
  );

  test(
    'project metadata cannot redirect commands outside the project',
    () async {
      await File('${project.path}/lc-project.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'clientPath': 'client',
          'backend': {
            'workingDirectory': '../',
            'command': ['go', 'run', '.'],
          },
          'frontend': {
            'workingDirectory': 'admin/web',
            'command': ['npm', 'run', 'serve'],
          },
        }),
      );
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: false,
      );

      final result = await runner.run(
        const ['dev', 'server'],
        currentDirectory: project.path,
        stdoutSink: output,
        stderrSink: errors,
      );

      expect(result, 1);
      expect(processes.commands, isEmpty);
      expect(errors.toString(), contains('lc-project.json'));
    },
  );

  test(
    'clean removes generated outputs but preserves installed dependencies',
    () async {
      final dist = Directory('${project.path}/admin/web/dist');
      final modules = Directory('${project.path}/admin/web/node_modules');
      await dist.create();
      await modules.create();
      await File('${dist.path}/index.html').writeAsString('generated');
      final runner = LcProjectCommandRunner(
        processes: processes,
        sourcePreference: ProjectSourcePreference.automatic,
        isWindows: false,
      );

      final result = await runner.run(
        const ['clean'],
        currentDirectory: project.path,
        stdoutSink: output,
        stderrSink: errors,
      );

      expect(result, 0);
      expect(processes.commands, hasLength(2));
      expect(processes.commands[0].arguments, ['clean']);
      expect(processes.commands[1].arguments, ['clean']);
      expect(await dist.exists(), isFalse);
      expect(await modules.exists(), isTrue);
    },
  );
}

final class _RecordingProcesses implements ProjectProcessRunner {
  final List<ProjectCommand> commands = [];
  final Map<String, List<int>> exitCodesByTool = {};

  @override
  Future<ProjectProcessResult> run(
    ProjectCommand command, {
    ProjectOutputCallback? onOutput,
  }) async {
    commands.add(command);
    final exitCodes = exitCodesByTool[command.executable];
    final exitCode = exitCodes == null || exitCodes.isEmpty
        ? 0
        : exitCodes.removeAt(0);
    return ProjectProcessResult(exitCode: exitCode);
  }
}
