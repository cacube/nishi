import 'dart:convert';
import 'dart:typed_data';

import 'package:dev_environment_manager/src/activation/activation_boundaries.dart';
import 'package:dev_environment_manager/src/activation/environment_activation.dart';
import 'package:dev_environment_manager/src/activation/host_environment_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Windows host environment', () {
    test(
      'uses a fixed encoded script and base64 JSON without elevation',
      () async {
        final files = _MemoryFileStore();
        final processes = _WindowsEnvironmentRunner(
          initial: {'PATH': r'C:\Windows\System32'},
        );
        final installer = HostEnvironmentInstaller(
          files: files,
          processes: processes,
        );
        const paths = HostEnvironmentInstallPaths.windows(
          stateFile: r'C:\managed\host-environment.json',
        );
        const environment = {
          'JAVA_HOME': r'C:\managed\jdk secret & value',
          'PATH': r'C:\managed\flutter\bin;C:\Windows\System32',
        };

        await installer.install(
          host: ActivationHost.windows,
          paths: paths,
          environment: environment,
        );

        expect(processes.environment, environment);
        expect(processes.commands, hasLength(2));
        for (final command in processes.commands) {
          expect(command.executable, 'powershell.exe');
          expect(command.elevation, ElevationRequirement.none);
          expect(command.arguments, contains('-EncodedCommand'));
          expect(
            command.arguments.join(' '),
            isNot(contains('secret & value')),
          );
          expect(
            _decodePowerShell(command),
            contains('[Environment]::SetEnvironmentVariable'),
          );
          expect(_decodePowerShell(command), contains("'User'"));
        }
        final setPayload = _decodePayload(processes.commands.last);
        expect(setPayload['variables'], environment);
        expect(
          (setPayload['variables']! as Map<String, dynamic>)['PATH'],
          endsWith(r'C:\Windows\System32'),
        );
        expect(files.atomicWrites, [paths.stateFile]);
      },
    );

    test('receipt rollback restores the previous user environment', () async {
      final files = _MemoryFileStore();
      final processes = _WindowsEnvironmentRunner(
        initial: {'PATH': r'C:\Windows', 'JAVA_HOME': r'C:\old-jdk'},
      );
      final installer = HostEnvironmentInstaller(
        files: files,
        processes: processes,
      );
      const paths = HostEnvironmentInstallPaths.windows(
        stateFile: r'C:\managed\host-environment.json',
      );

      final receipt = await installer.install(
        host: ActivationHost.windows,
        paths: paths,
        environment: const {
          'PATH': r'C:\managed\bin;C:\Windows',
          'JAVA_HOME': r'C:\managed\jdk',
          'NEW_VALUE': 'installed',
        },
      );
      await receipt.rollback();
      await receipt.rollback();

      expect(processes.environment, {
        'PATH': r'C:\Windows',
        'JAVA_HOME': r'C:\old-jdk',
      });
      expect(files.contents, isNot(contains(paths.stateFile)));
    });

    test(
      'a failed command reports no values and leaves files unchanged',
      () async {
        const secret = 'do-not-report-this-value';
        final files = _MemoryFileStore(
          initial: {
            r'C:\managed\host-environment.json': utf8.encode('previous-state'),
          },
        );
        final processes = _WindowsEnvironmentRunner(failSetNumber: 1);
        final installer = HostEnvironmentInstaller(
          files: files,
          processes: processes,
        );

        Object? error;
        try {
          await installer.install(
            host: ActivationHost.windows,
            paths: const HostEnvironmentInstallPaths.windows(
              stateFile: r'C:\managed\host-environment.json',
            ),
            environment: const {'TOKEN_LIKE_VALUE': secret},
          );
        } on Object catch (caught) {
          error = caught;
        }

        expect(error, isA<HostEnvironmentInstallException>());
        expect(error.toString(), isNot(contains(secret)));
        expect(
          utf8.decode(files.contents[r'C:\managed\host-environment.json']!),
          'previous-state',
        );
        expect(processes.environment, isEmpty);
      },
    );
  });

  group('macOS host environment', () {
    test('sets the current session and installs a login replay agent', () async {
      final files = _MemoryFileStore();
      final processes = _LaunchctlEnvironmentRunner(
        initial: {'PATH': '/usr/bin:/bin'},
      );
      final installer = HostEnvironmentInstaller(
        files: files,
        processes: processes,
      );
      const paths = HostEnvironmentInstallPaths.macos(
        stateFile: '/managed/host-environment.json',
        replayScript: '/managed/replay-environment.sh',
        launchAgentPlist:
            '/Users/test/Library/LaunchAgents/com.cacube.nishi.environment.plist',
      );
      const environment = {
        'JAVA_HOME': "/managed/jdk's home",
        'PATH': '/managed/flutter/bin:/usr/bin:/bin',
      };

      await installer.install(
        host: ActivationHost.macos,
        paths: paths,
        environment: environment,
      );

      expect(processes.environment, environment);
      expect(files.atomicWrites, [
        paths.stateFile,
        paths.replayScript,
        paths.launchAgentPlist,
      ]);
      final script = utf8.decode(files.contents[paths.replayScript!]!);
      final plist = utf8.decode(files.contents[paths.launchAgentPlist!]!);
      expect(script, contains("'/managed/jdk'\"'\"'s home'"));
      expect(script, contains("'/managed/flutter/bin:/usr/bin:/bin'"));
      expect(plist, contains('<string>/bin/sh</string>'));
      expect(plist, contains('<key>RunAtLoad</key>'));
      expect(plist, isNot(contains('<key>KeepAlive</key>')));
      expect(
        files.contents.keys,
        isNot(contains(anyOf(contains('.zshrc'), contains('.bash_profile')))),
      );
      expect(
        processes.commands.where(
          (command) => command.arguments.first == 'setenv',
        ),
        hasLength(environment.length),
      );
    });

    test('failure restores current values and all managed files', () async {
      final files = _MemoryFileStore(
        initial: {
          '/managed/state.json': utf8.encode('old-state'),
          '/managed/replay.sh': utf8.encode('old-script'),
          '/agents/environment.plist': utf8.encode('old-plist'),
        },
      );
      final processes = _LaunchctlEnvironmentRunner(
        initial: {'A': 'before-a', 'B': 'before-b'},
        failSetNumber: 2,
      );
      final installer = HostEnvironmentInstaller(
        files: files,
        processes: processes,
      );

      await expectLater(
        installer.install(
          host: ActivationHost.macos,
          paths: const HostEnvironmentInstallPaths.macos(
            stateFile: '/managed/state.json',
            replayScript: '/managed/replay.sh',
            launchAgentPlist: '/agents/environment.plist',
          ),
          environment: const {'A': 'after-a', 'B': 'after-b'},
        ),
        throwsA(isA<HostEnvironmentInstallException>()),
      );

      expect(processes.environment, {'A': 'before-a', 'B': 'before-b'});
      expect(utf8.decode(files.contents['/managed/state.json']!), 'old-state');
      expect(utf8.decode(files.contents['/managed/replay.sh']!), 'old-script');
      expect(
        utf8.decode(files.contents['/agents/environment.plist']!),
        'old-plist',
      );
    });

    test(
      'uninstall restores pre-install values and removes artifacts',
      () async {
        final files = _MemoryFileStore();
        final processes = _LaunchctlEnvironmentRunner(
          initial: {'PATH': '/usr/local/bin:/usr/bin'},
        );
        final installer = HostEnvironmentInstaller(
          files: files,
          processes: processes,
        );
        const paths = HostEnvironmentInstallPaths.macos(
          stateFile: '/managed/state.json',
          replayScript: '/managed/replay.sh',
          launchAgentPlist: '/agents/environment.plist',
        );
        await installer.install(
          host: ActivationHost.macos,
          paths: paths,
          environment: const {
            'PATH': '/managed/bin:/usr/local/bin:/usr/bin',
            'JAVA_HOME': '/managed/jdk',
          },
        );

        await installer.uninstall(host: ActivationHost.macos, paths: paths);

        expect(processes.environment, {'PATH': '/usr/local/bin:/usr/bin'});
        expect(files.contents, isEmpty);
      },
    );
  });

  test(
    'rejects invalid environment entries before executing commands',
    () async {
      final processes = _WindowsEnvironmentRunner();
      final installer = HostEnvironmentInstaller(
        files: _MemoryFileStore(),
        processes: processes,
      );

      await expectLater(
        installer.install(
          host: ActivationHost.windows,
          paths: const HostEnvironmentInstallPaths.windows(
            stateFile: r'C:\managed\state.json',
          ),
          environment: const {'BAD-NAME': 'value'},
        ),
        throwsArgumentError,
      );
      expect(processes.commands, isEmpty);
    },
  );
}

String _decodePowerShell(ActivationCommand command) {
  final index = command.arguments.indexOf('-EncodedCommand');
  final bytes = base64Decode(command.arguments[index + 1]);
  final codeUnits = <int>[
    for (var byte = 0; byte < bytes.length; byte += 2)
      bytes[byte] | (bytes[byte + 1] << 8),
  ];
  return String.fromCharCodes(codeUnits);
}

Map<String, dynamic> _decodePayload(ActivationCommand command) {
  return jsonDecode(
        utf8.decode(
          base64Decode(command.environment['NISHI_ENVIRONMENT_PAYLOAD']!),
        ),
      )!
      as Map<String, dynamic>;
}

final class _MemoryFileStore implements ActivationFileStore {
  _MemoryFileStore({Map<String, List<int>> initial = const {}})
    : contents = {
        for (final entry in initial.entries)
          entry.key: Uint8List.fromList(entry.value),
      };

  final Map<String, Uint8List> contents;
  final List<String> atomicWrites = [];

  @override
  Future<void> delete(String path) async {
    contents.remove(path);
  }

  @override
  Future<Uint8List?> read(String path) async {
    final contents = this.contents[path];
    return contents == null ? null : Uint8List.fromList(contents);
  }

  @override
  Future<void> writeAtomically(String path, Uint8List contents) async {
    atomicWrites.add(path);
    this.contents[path] = Uint8List.fromList(contents);
  }
}

final class _WindowsEnvironmentRunner implements ActivationProcessRunner {
  _WindowsEnvironmentRunner({
    Map<String, String> initial = const {},
    this.failSetNumber,
  }) : environment = Map.of(initial);

  final Map<String, String> environment;
  final int? failSetNumber;
  final List<ActivationCommand> commands = [];
  int _setCount = 0;

  @override
  Future<ActivationCommandResult> run(ActivationCommand command) async {
    commands.add(command);
    final payload = _decodePayload(command);
    if (payload['action'] == 'get') {
      final values = <String, String?>{};
      for (final name in (payload['names']! as List<dynamic>).cast<String>()) {
        values[name] = environment[name];
      }
      return ActivationCommandResult(
        exitCode: 0,
        stdout: base64Encode(utf8.encode(jsonEncode({'values': values}))),
      );
    }

    _setCount++;
    if (_setCount == failSetNumber) {
      return const ActivationCommandResult(
        exitCode: 1,
        stderr: 'sensitive native error',
      );
    }
    final variables = (payload['variables']! as Map<String, dynamic>)
        .cast<String, String?>();
    for (final entry in variables.entries) {
      if (entry.value == null) {
        environment.remove(entry.key);
      } else {
        environment[entry.key] = entry.value!;
      }
    }
    return const ActivationCommandResult(exitCode: 0);
  }
}

final class _LaunchctlEnvironmentRunner implements ActivationProcessRunner {
  _LaunchctlEnvironmentRunner({
    Map<String, String> initial = const {},
    this.failSetNumber,
  }) : environment = Map.of(initial);

  final Map<String, String> environment;
  final int? failSetNumber;
  final List<ActivationCommand> commands = [];
  int _setCount = 0;

  @override
  Future<ActivationCommandResult> run(ActivationCommand command) async {
    commands.add(command);
    final operation = command.arguments.first;
    final name = command.arguments[1];
    if (operation == 'getenv') {
      return ActivationCommandResult(
        exitCode: 0,
        stdout: environment[name] == null ? '' : '${environment[name]}\n',
      );
    }
    _setCount++;
    if (_setCount == failSetNumber) {
      return const ActivationCommandResult(exitCode: 1, stderr: 'private');
    }
    if (operation == 'setenv') {
      environment[name] = command.arguments[2];
    } else if (operation == 'unsetenv') {
      environment.remove(name);
    }
    return const ActivationCommandResult(exitCode: 0);
  }
}
