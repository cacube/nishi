import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dev_environment_manager/src/activation/activation_boundaries.dart';
import 'package:dev_environment_manager/src/activation/autostart_coordinator.dart';
import 'package:dev_environment_manager/src/activation/autostart_plans.dart';
import 'package:dev_environment_manager/src/activation/environment_activation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('environment activation', () {
    test(
      'writes managed and launcher environments without touching profiles',
      () async {
        final files = _MemoryFileStore();
        final activator = EnvironmentActivator(files: files);
        const paths = EnvironmentActivationPaths(
          managedEnvironment: '/managed/environment.json',
          launcherEnvironment: '/managed/launcher-environment.json',
        );

        await activator.activate(
          paths: paths,
          toolchain: _macToolchain(inheritedPath: '/usr/bin:/bin'),
        );

        expect(files.atomicWrites, [
          paths.managedEnvironment,
          paths.launcherEnvironment,
        ]);
        final managed = _decode(files.contents[paths.managedEnvironment]!);
        final launcher = _decode(files.contents[paths.launcherEnvironment]!);
        final environment = managed['environment']! as Map<String, dynamic>;
        expect(managed['kind'], 'managed-environment');
        expect(launcher['kind'], 'launcher-environment');
        expect(environment['JAVA_HOME'], '/managed/jdk');
        expect(environment['ANDROID_SDK_ROOT'], '/managed/android');
        expect(environment['ANDROID_HOME'], '/managed/android');
        expect(
          environment['PATH'],
          startsWith('/managed/flutter/bin:/managed/jdk/bin:'),
        );
        expect(environment['PATH'], endsWith('/usr/bin:/bin'));
        expect(files.contents.keys, isNot(contains(contains('.zshrc'))));
      },
    );

    test('rolls back both documents when an atomic write fails', () async {
      final files = _MemoryFileStore(
        initial: {
          '/managed/environment.json': utf8.encode('old-managed'),
          '/managed/launcher.json': utf8.encode('old-launcher'),
        },
        failWriteNumber: 2,
      );
      final activator = EnvironmentActivator(files: files);

      await expectLater(
        activator.activate(
          paths: const EnvironmentActivationPaths(
            managedEnvironment: '/managed/environment.json',
            launcherEnvironment: '/managed/launcher.json',
          ),
          toolchain: _macToolchain(),
        ),
        throwsStateError,
      );

      expect(
        utf8.decode(files.contents['/managed/environment.json']!),
        'old-managed',
      );
      expect(
        utf8.decode(files.contents['/managed/launcher.json']!),
        'old-launcher',
      );
    });

    test(
      'IO store replaces through a temporary sibling and leaves no residue',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'activation-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final destination = '${directory.path}/environment.json';
        const files = IoActivationFileStore();

        await files.writeAtomically(
          destination,
          Uint8List.fromList(utf8.encode('first')),
        );
        await files.writeAtomically(
          destination,
          Uint8List.fromList(utf8.encode('second')),
        );

        expect(await File(destination).readAsString(), 'second');
        expect(
          directory.listSync().where(
            (entry) =>
                entry.path.endsWith('.tmp') || entry.path.endsWith('.backup'),
          ),
          isEmpty,
        );
      },
    );
  });

  group('macOS LaunchAgent', () {
    test(
      'escapes plist values and builds bootstrap and kickstart arguments',
      () {
        final plan = MacOsLaunchAgentPlan.build(
          userId: 501,
          label: 'com.example.a&b',
          plistPath: '/Users/a & b/Library/LaunchAgents/service.plist',
          executable: '/runtime/a&b/mysqld',
          arguments: const ['--name=<mysql>', '--quote="value"'],
          stdoutPath: '/logs/a>b.out',
          stderrPath: "/logs/a'b.err",
          environment: const {'A_VALUE': 'x&<y>'},
        );
        final plist = utf8.decode(plan.artifacts.single.contents);

        expect(plist, contains('com.example.a&amp;b'));
        expect(plist, contains('/runtime/a&amp;b/mysqld'));
        expect(plist, contains('--name=&lt;mysql&gt;'));
        expect(plist, contains('--quote=&quot;value&quot;'));
        expect(plist, contains('x&amp;&lt;y&gt;'));
        expect(plist, contains('/logs/a&apos;b.err'));
        expect(plan.enableCommands.first.arguments, [
          'enable',
          'gui/501/com.example.a&b',
        ]);
        expect(plan.enableCommands[1].arguments, [
          'bootstrap',
          'gui/501',
          '/Users/a & b/Library/LaunchAgents/service.plist',
        ]);
        expect(plan.enableCommands.last.arguments, [
          'kickstart',
          '-k',
          'gui/501/com.example.a&b',
        ]);
      },
    );

    test(
      'mysql plan keeps managed data and log paths in separate arguments',
      () {
        final plan = MacOsLaunchAgentPlan.mysql(
          userId: 501,
          plistPath: '/agents/mysql.plist',
          mysqlRoot: '/runtime/mysql 8',
          dataDirectory: '/managed/data/mysql',
          logDirectory: '/managed/logs/mysql',
        );
        final plist = utf8.decode(plan.artifacts.single.contents);

        expect(plist, contains('/runtime/mysql 8/bin/mysqld'));
        expect(plist, contains('--datadir=/managed/data/mysql'));
        expect(
          plist,
          contains('--log-error=/managed/logs/mysql/mysql-error.log'),
        );
      },
    );
  });

  group('Windows auto-start', () {
    test('user task passes one correctly quoted task command argument', () {
      final plan = WindowsAutoStartPlan.mysqlUserTask(
        mysqlRoot: r'C:\Program Data\Managed MySQL',
        dataDirectory: r'C:\Managed Data\mysql',
        logDirectory: r'C:\Managed Logs\mysql',
      );
      final command = plan.enableCommands.single;
      final taskRunIndex = command.arguments.indexOf('/TR') + 1;

      expect(command.executable, 'schtasks.exe');
      expect(command.elevation, ElevationRequirement.none);
      expect(command.arguments, containsAllInOrder(['/SC', 'ONLOGON']));
      expect(
        command.arguments[taskRunIndex],
        startsWith(r'"C:\Program Data\Managed MySQL\bin\mysqld.exe"'),
      );
      expect(
        command.arguments[taskRunIndex],
        contains(r'"--datadir=C:\Managed Data\mysql"'),
      );
    });

    test('Memurai config owns its data and log directories', () {
      final plan = WindowsAutoStartPlan.memuraiUserTask(
        memuraiRoot: r'C:\Managed\Memurai',
        dataDirectory: r'C:\Managed Data\memurai',
        logDirectory: r'C:\Managed Logs\memurai',
        configPath: r'C:\Managed\config\memurai.conf',
      );
      final config = utf8.decode(plan.artifacts.single.contents);

      expect(config, contains(r'dir "C:\\Managed Data\\memurai"'));
      expect(
        config,
        contains(r'logfile "C:\\Managed Logs\\memurai\\memurai.log"'),
      );
    });

    test('system service commands explicitly require elevation', () {
      final plan = WindowsAutoStartPlan.memuraiSystemService(
        memuraiRoot: r'C:\Managed\Memurai',
        configPath: r'C:\Managed\memurai.conf',
        dataDirectory: r'C:\Managed\data\memurai',
        logDirectory: r'C:\Managed\logs\memurai',
      );

      expect(
        [
          ...plan.enableCommands,
          ...plan.updateCommands,
          ...plan.disableCommands,
          ...plan.uninstallCommands,
        ].map((command) => command.elevation),
        everyElement(ElevationRequirement.required),
      );
      expect(plan.artifacts.single.path, r'C:\Managed\memurai.conf');
      expect(
        () => const IoActivationProcessRunner().run(plan.enableCommands.first),
        throwsStateError,
      );
    });
  });

  group('auto-start coordinator', () {
    test(
      'disable executes only disable commands and preserves artifacts',
      () async {
        final plan = MacOsLaunchAgentPlan.mysql(
          userId: 501,
          plistPath: '/agents/mysql.plist',
          mysqlRoot: '/runtime/mysql',
          dataDirectory: '/data/mysql',
          logDirectory: '/logs/mysql',
        );
        final files = _MemoryFileStore(
          initial: {'/agents/mysql.plist': utf8.encode('installed')},
        );
        final processes = _RecordingProcessRunner();
        final coordinator = AutoStartCoordinator(
          files: files,
          processes: processes,
        );

        final result = await coordinator.disable(plan);

        expect(result.operation, AutoStartOperation.disable);
        expect(processes.commands, hasLength(2));
        expect(processes.commands.first.arguments.first, 'bootout');
        expect(processes.commands.last.arguments, [
          'disable',
          'gui/501/com.devenvironmentmanager.mysql',
        ]);
        expect(files.contents, contains('/agents/mysql.plist'));
      },
    );

    test('failed update restores the previous artifact', () async {
      final plan = MacOsLaunchAgentPlan.mysql(
        userId: 501,
        plistPath: '/agents/mysql.plist',
        mysqlRoot: '/runtime/mysql-new',
        dataDirectory: '/data/mysql',
        logDirectory: '/logs/mysql',
      );
      final files = _MemoryFileStore(
        initial: {'/agents/mysql.plist': utf8.encode('previous-plist')},
      );
      final coordinator = AutoStartCoordinator(
        files: files,
        processes: _RecordingProcessRunner(exitCodes: [0, 0, 1]),
      );

      await expectLater(
        coordinator.update(plan),
        throwsA(isA<AutoStartCommandException>()),
      );
      expect(
        utf8.decode(files.contents['/agents/mysql.plist']!),
        'previous-plist',
      );
    });

    test(
      'uninstall removes the registered artifact after command success',
      () async {
        final plan = WindowsAutoStartPlan.memuraiUserTask(
          memuraiRoot: r'C:\Managed\Memurai',
          dataDirectory: r'C:\Data\Memurai',
          logDirectory: r'C:\Logs\Memurai',
          configPath: r'C:\Managed\memurai.conf',
        );
        final files = _MemoryFileStore(
          initial: {plan.artifacts.single.path: plan.artifacts.single.contents},
        );
        final coordinator = AutoStartCoordinator(
          files: files,
          processes: _RecordingProcessRunner(),
        );

        await coordinator.uninstall(plan);

        expect(files.contents, isNot(contains(plan.artifacts.single.path)));
      },
    );
  });
}

ToolchainEnvironment _macToolchain({String? inheritedPath}) {
  return ToolchainEnvironment(
    host: ActivationHost.macos,
    managerRoot: '/managed',
    javaHome: '/managed/jdk',
    androidSdkRoot: '/managed/android',
    flutterRoot: '/managed/flutter',
    goRoot: '/managed/go',
    nodeRoot: '/managed/node',
    mysqlRoot: '/managed/mysql',
    redisRoot: '/managed/redis/bin',
    inheritedPath: inheritedPath,
  );
}

Map<String, dynamic> _decode(Uint8List value) {
  return jsonDecode(utf8.decode(value))! as Map<String, dynamic>;
}

final class _MemoryFileStore implements ActivationFileStore {
  _MemoryFileStore({
    Map<String, List<int>> initial = const {},
    this.failWriteNumber,
  }) : contents = {
         for (final entry in initial.entries)
           entry.key: Uint8List.fromList(entry.value),
       };

  final Map<String, Uint8List> contents;
  final int? failWriteNumber;
  final List<String> atomicWrites = [];
  int _writeCount = 0;

  @override
  Future<void> delete(String path) async {
    contents.remove(path);
  }

  @override
  Future<Uint8List?> read(String path) async {
    final value = contents[path];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> writeAtomically(String path, Uint8List value) async {
    _writeCount++;
    if (_writeCount == failWriteNumber) throw StateError('write failed');
    atomicWrites.add(path);
    contents[path] = Uint8List.fromList(value);
  }
}

final class _RecordingProcessRunner implements ActivationProcessRunner {
  _RecordingProcessRunner({List<int> exitCodes = const []})
    : _exitCodes = List.of(exitCodes);

  final List<int> _exitCodes;
  final List<ActivationCommand> commands = [];

  @override
  Future<ActivationCommandResult> run(ActivationCommand command) async {
    commands.add(command);
    return ActivationCommandResult(
      exitCode: _exitCodes.isEmpty ? 0 : _exitCodes.removeAt(0),
      stderr: 'failed',
    );
  }
}
