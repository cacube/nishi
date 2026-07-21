import 'dart:convert';
import 'dart:typed_data';

import 'package:dev_environment_manager/src/activation/activation_boundaries.dart';
import 'package:dev_environment_manager/src/mysql/mysql_configurator.dart';
import 'package:dev_environment_manager/src/mysql/windows_mysql_autostart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const launch = MySqlLaunchConfiguration(
    mysqlRoot: r'C:\Users\Test User\MySQL',
    executable: r'C:\Users\Test User\MySQL\bin\mysqld.exe',
    dataDirectory: r'C:\Users\Test User\data\mysql',
    logDirectory: r'C:\Users\Test User\logs\mysql',
    configPath: r'C:\Users\Test User\data\mysql\my.ini',
    pidFilePath: r'C:\Users\Test User\data\mysql\mysql.pid',
    stdoutPath: r'C:\Users\Test User\logs\mysql-stdout.log',
    stderrPath: r'C:\Users\Test User\logs\mysql-stderr.log',
    serverArguments: [r'--defaults-file=C:\Users\Test User\data\mysql\my.ini'],
  );

  test('uses the scheduled task when Windows accepts it', () async {
    final processes = _RecordingProcessRunner([0, 0]);
    final files = _MemoryFileStore();
    final autostart = WindowsMySqlAutoStart(files: files, processes: processes);

    final result = await autostart.enable(launch);

    expect(result.mode, WindowsMySqlAutoStartMode.scheduledTask);
    expect(processes.commands.map((command) => command.executable), [
      'schtasks.exe',
      'schtasks.exe',
    ]);
    expect(files.contents, isEmpty);
  });

  test(
    'falls back to a hidden user startup entry when task creation fails',
    () async {
      final processes = _RecordingProcessRunner([1, 0, 0]);
      final files = _MemoryFileStore();
      final autostart = WindowsMySqlAutoStart(
        files: files,
        processes: processes,
      );

      final result = await autostart.enable(launch);

      expect(result.mode, WindowsMySqlAutoStartMode.userRunKey);
      expect(processes.commands.map((command) => command.executable), [
        'schtasks.exe',
        'reg.exe',
        'wscript.exe',
      ]);
      final script = utf8.decode(files.contents[result.launcherPath]!);
      expect(script, contains(launch.executable));
      expect(script, contains(launch.serverArguments.single));
      expect(processes.commands[1].arguments, containsAll(['ADD', 'REG_SZ']));
    },
  );

  test('falls back when the task is created but cannot be started', () async {
    final processes = _RecordingProcessRunner([0, 5, 0, 0, 0]);
    final autostart = WindowsMySqlAutoStart(
      files: _MemoryFileStore(),
      processes: processes,
    );

    final result = await autostart.enable(launch);

    expect(result.mode, WindowsMySqlAutoStartMode.userRunKey);
    expect(processes.commands[1].arguments, contains('/Run'));
    expect(processes.commands[2].arguments, contains('/Delete'));
    expect(processes.commands[3].executable, 'reg.exe');
    expect(processes.commands[4].executable, 'wscript.exe');
  });

  test('keeps using the fallback when its managed launcher exists', () async {
    final launcherPath = r'C:\Users\Test User\data\mysql\lc-start-mysql.vbs';
    final files = _MemoryFileStore()
      ..contents[launcherPath] = Uint8List.fromList(
        utf8.encode('old launcher'),
      );
    final processes = _RecordingProcessRunner([0, 0]);
    final autostart = WindowsMySqlAutoStart(files: files, processes: processes);

    final result = await autostart.enable(launch);

    expect(result.mode, WindowsMySqlAutoStartMode.userRunKey);
    expect(processes.commands.map((command) => command.executable), [
      'reg.exe',
      'wscript.exe',
    ]);
    expect(
      utf8.decode(files.contents[launcherPath]!),
      contains(launch.executable),
    );
  });
}

final class _RecordingProcessRunner implements ActivationProcessRunner {
  _RecordingProcessRunner(List<int> exitCodes)
    : _exitCodes = List<int>.of(exitCodes);

  final List<int> _exitCodes;
  final List<ActivationCommand> commands = [];

  @override
  Future<ActivationCommandResult> run(ActivationCommand command) async {
    commands.add(command);
    return ActivationCommandResult(exitCode: _exitCodes.removeAt(0));
  }
}

final class _MemoryFileStore implements ActivationFileStore {
  final Map<String, Uint8List> contents = {};

  @override
  Future<void> delete(String path) async => contents.remove(path);

  @override
  Future<Uint8List?> read(String path) async => contents[path];

  @override
  Future<void> writeAtomically(String path, Uint8List contents) async {
    this.contents[path] = contents;
  }
}
