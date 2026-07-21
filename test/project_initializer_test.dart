import 'dart:convert';
import 'dart:io';

import 'package:dev_environment_manager/src/project_init/project_init_boundaries.dart';
import 'package:dev_environment_manager/src/project_init/project_init_spec.dart';
import 'package:dev_environment_manager/src/project_init/project_initializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory parent;
  late _ScaffoldingRunner processes;

  setUp(() async {
    parent = await Directory.systemTemp.createTemp('lc_project_init_test_');
    processes = _ScaffoldingRunner();
  });

  tearDown(() => parent.delete(recursive: true));

  test('creates Flutter and pinned GVA as one transactional project', () async {
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.macos(hasXcode: true),
      stagingNonce: () => 'test',
    );

    final result = await initializer.initialize(
      ProjectInitRequest(
        requestedName: 'My Shop',
        parentDirectory: parent.path,
      ),
    );

    final project = Directory('${parent.path}/My Shop');
    expect(result.projectDirectory, project.path);
    expect(await Directory('${project.path}/client').exists(), isTrue);
    expect(await Directory('${project.path}/admin/server').exists(), isTrue);
    expect(await Directory('${project.path}/admin/web').exists(), isTrue);
    expect(await Directory('${project.path}/admin/.git').exists(), isFalse);
    expect(
      await File(
        '${project.path}/admin/server/config.lc.local.yaml',
      ).readAsString(),
      'blank config\n',
    );

    final metadata =
        jsonDecode(await File('${project.path}/lc-project.json').readAsString())
            as Map<String, Object?>;
    expect(metadata['schemaVersion'], 1);
    expect(metadata['name'], 'My Shop');
    expect(metadata['packageName'], 'my_shop');
    expect(metadata['databaseName'], 'my_shop');
    expect(metadata['ginVueAdminTag'], ginVueAdminTag);
    expect(metadata['ginVueAdminCommit'], ginVueAdminCommit);
    expect(jsonEncode(metadata), isNot(contains('password')));
    expect(jsonEncode(metadata), isNot(contains('secret')));

    final flutterCreate = processes.commands.firstWhere(
      (command) => command.arguments.contains('create'),
    );
    expect(
      flutterCreate.arguments,
      containsAllInOrder([
        'create',
        '--no-pub',
        '--project-name',
        'my_shop',
        '--platforms',
        'android,web,windows,ios,macos',
        'client',
      ]),
    );
    final clone = processes.commands.firstWhere(
      (command) => command.arguments.contains('clone'),
    );
    expect(clone.arguments, containsAll(['v3.0.0', 'admin']));
    expect(
      processes.commands.any(
        (command) =>
            command.executable == 'go' &&
            command.arguments.join(' ') == 'mod download' &&
            command.workingDirectory?.endsWith('/admin/server') == true,
      ),
      isTrue,
    );
    expect(
      processes.commands.any(
        (command) =>
            command.executable == 'npm' &&
            command.arguments.contains('install') &&
            command.workingDirectory?.endsWith('/admin/web') == true,
      ),
      isTrue,
    );
  });

  test('refuses a non-empty target before running subprocesses', () async {
    final target = Directory('${parent.path}/existing');
    await target.create();
    final sentinel = File('${target.path}/keep.txt');
    await sentinel.writeAsString('keep');
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.windows(),
      stagingNonce: () => 'test',
    );

    await expectLater(
      initializer.initialize(
        ProjectInitRequest(
          requestedName: 'existing',
          parentDirectory: parent.path,
        ),
      ),
      throwsA(isA<ProjectInitException>()),
    );

    expect(processes.commands, isEmpty);
    expect(await sentinel.readAsString(), 'keep');
  });

  test('rejects an unexpected GVA commit and removes staging', () async {
    processes.gvaCommit = '0000000000000000000000000000000000000000';
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.windows(),
      stagingNonce: () => 'test',
    );

    await expectLater(
      initializer.initialize(
        ProjectInitRequest(
          requestedName: 'broken',
          parentDirectory: parent.path,
        ),
      ),
      throwsA(
        isA<ProjectInitException>().having(
          (error) => error.message,
          'message',
          contains('版本校验失败'),
        ),
      ),
    );

    expect(await Directory('${parent.path}/broken').exists(), isFalse);
    expect(
      await Directory('${parent.path}/.broken.lc-staging-test').exists(),
      isFalse,
    );
    expect(
      processes.commands.any((command) => command.executable == 'go'),
      isFalse,
    );
    expect(
      processes.commands.any((command) => command.executable == 'npm'),
      isFalse,
    );
  });

  test('retries dependency download through the China mirror', () async {
    processes.npmFailuresRemaining = 1;
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.macos(hasXcode: false),
      stagingNonce: () => 'test',
    );

    await initializer.initialize(
      ProjectInitRequest(
        requestedName: 'fallback',
        parentDirectory: parent.path,
      ),
    );

    final npmCommands = processes.commands
        .where(
          (command) =>
              command.executable == 'npm' &&
              command.arguments.contains('install'),
        )
        .toList();
    expect(npmCommands, hasLength(2));
    expect(
      npmCommands.first.arguments,
      isNot(contains('--registry=https://registry.npmmirror.com')),
    );
    expect(
      npmCommands.last.arguments,
      contains('--registry=https://registry.npmmirror.com'),
    );
  });

  test('a dependency failure restores a pre-existing empty target', () async {
    final target = Directory('${parent.path}/empty');
    await target.create();
    processes.goFailuresRemaining = 2;
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.macos(hasXcode: false),
      stagingNonce: () => 'test',
    );

    await expectLater(
      initializer.initialize(
        ProjectInitRequest(
          requestedName: 'empty',
          parentDirectory: parent.path,
        ),
      ),
      throwsA(isA<ProjectInitException>()),
    );

    expect(await target.exists(), isTrue);
    expect(await target.list().isEmpty, isTrue);
    expect(
      await Directory('${parent.path}/.empty.lc-staging-test').exists(),
      isFalse,
    );
  });

  test(
    'rejects an incompatible Node version before creating staging',
    () async {
      processes.nodeVersion = 'v21.7.0';
      final initializer = IoProjectInitializer(
        processes: processes,
        host: const ProjectHost.macos(hasXcode: false),
        stagingNonce: () => 'test',
      );

      await expectLater(
        initializer.initialize(
          ProjectInitRequest(
            requestedName: 'old-node',
            parentDirectory: parent.path,
          ),
        ),
        throwsA(
          isA<ProjectInitException>().having(
            (error) => error.message,
            'message',
            contains('Node.js 版本不兼容'),
          ),
        ),
      );

      expect(await Directory('${parent.path}/old-node').exists(), isFalse);
      expect(
        processes.commands.any(
          (command) => command.arguments.contains('create'),
        ),
        isFalse,
      );
    },
  );

  test('Windows uses command shims and omits Apple platforms', () async {
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.windows(),
      stagingNonce: () => 'test',
    );

    await initializer.initialize(
      ProjectInitRequest(
        requestedName: 'windows-app',
        parentDirectory: parent.path,
      ),
    );

    final flutterCreate = processes.commands.firstWhere(
      (command) => command.arguments.contains('create'),
    );
    expect(flutterCreate.executable, 'flutter.bat');
    expect(flutterCreate.runInShell, isTrue);
    expect(
      flutterCreate.arguments,
      containsAllInOrder(['--platforms', 'android,web,windows']),
    );
    expect(flutterCreate.arguments.join(','), isNot(contains('ios')));
  });

  test('restores an existing empty target when final commit fails', () async {
    final target = Directory('${parent.path}/commit-failure');
    await target.create();
    final initializer = IoProjectInitializer(
      processes: processes,
      host: const ProjectHost.macos(hasXcode: false),
      stagingNonce: () => 'test',
      commitDirectory: (_, _) async =>
          throw const FileSystemException('rename failed'),
    );

    await expectLater(
      initializer.initialize(
        ProjectInitRequest(
          requestedName: 'commit-failure',
          parentDirectory: parent.path,
        ),
      ),
      throwsA(isA<ProjectInitException>()),
    );

    expect(await target.exists(), isTrue);
    expect(await target.list().isEmpty, isTrue);
    expect(
      await Directory(
        '${parent.path}/.commit-failure.lc-staging-test',
      ).exists(),
      isFalse,
    );
  });
}

final class _ScaffoldingRunner implements ProjectProcessRunner {
  final List<ProjectCommand> commands = [];
  String gvaCommit = ginVueAdminCommit;
  int npmFailuresRemaining = 0;
  int goFailuresRemaining = 0;
  String nodeVersion = 'v24.18.0';

  @override
  Future<ProjectProcessResult> run(
    ProjectCommand command, {
    ProjectOutputCallback? onOutput,
  }) async {
    commands.add(command);
    onOutput?.call('running ${command.executable}');

    if (command.executable.startsWith('go') &&
        command.arguments.join(' ') == 'version') {
      return const ProjectProcessResult(
        exitCode: 0,
        stdout: 'go version go1.26.5 darwin/arm64\n',
      );
    }
    if (command.executable.startsWith('node') &&
        command.arguments.contains('--version')) {
      return ProjectProcessResult(exitCode: 0, stdout: '$nodeVersion\n');
    }

    if (command.executable == 'npm' &&
        command.arguments.contains('install') &&
        npmFailuresRemaining > 0) {
      npmFailuresRemaining--;
      return const ProjectProcessResult(
        exitCode: 1,
        stderr: 'npm registry unavailable',
      );
    }
    if (command.executable == 'go' &&
        command.arguments.contains('mod') &&
        goFailuresRemaining > 0) {
      goFailuresRemaining--;
      return const ProjectProcessResult(
        exitCode: 1,
        stderr: 'go proxy unavailable',
      );
    }

    if (command.executable.startsWith('git') &&
        command.arguments.length >= 2 &&
        command.arguments[0] == 'rev-parse') {
      return ProjectProcessResult(exitCode: 0, stdout: '$gvaCommit\n');
    }
    if (command.arguments.contains('create')) {
      await Directory(
        '${command.workingDirectory}/client',
      ).create(recursive: true);
    }
    if (command.arguments.contains('clone')) {
      final admin = Directory('${command.workingDirectory}/admin');
      await Directory('${admin.path}/.git').create(recursive: true);
      await Directory('${admin.path}/server').create(recursive: true);
      await Directory('${admin.path}/web').create(recursive: true);
      await File(
        '${admin.path}/server/config.yaml',
      ).writeAsString('blank config\n');
    }
    return const ProjectProcessResult(exitCode: 0);
  }
}
