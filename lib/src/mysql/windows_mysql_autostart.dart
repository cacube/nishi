import 'dart:io';

import '../activation/activation_boundaries.dart';
import '../activation/autostart_coordinator.dart';
import '../activation/autostart_plans.dart';
import 'mysql_configurator.dart';

enum WindowsMySqlAutoStartMode { scheduledTask, userRunKey }

final class WindowsMySqlAutoStartResult {
  const WindowsMySqlAutoStartResult({required this.mode, this.launcherPath});

  final WindowsMySqlAutoStartMode mode;
  final String? launcherPath;
}

final class WindowsMySqlAutoStart {
  const WindowsMySqlAutoStart({
    required ActivationFileStore files,
    required ActivationProcessRunner processes,
  }) : _files = files,
       _processes = processes;

  static const _taskName = r'DevEnvironmentManager\MySQL';
  static const _runValueName = 'lc-MySQL';

  final ActivationFileStore _files;
  final ActivationProcessRunner _processes;

  Future<WindowsMySqlAutoStartResult> enable(
    MySqlLaunchConfiguration launch,
  ) async {
    final coordinator = AutoStartCoordinator(
      files: _files,
      processes: _processes,
    );
    final taskPlan = WindowsAutoStartPlan.userTask(
      id: 'mysql',
      taskName: _taskName,
      executable: launch.executable,
      arguments: launch.serverArguments,
    );
    if (await _files.read(_launcherPath(launch)) != null) {
      return _enableUserRunKey(coordinator, launch);
    }

    var taskCreated = false;
    try {
      await coordinator.enable(taskPlan);
      taskCreated = true;
      const runTask = ActivationCommand(
        executable: 'schtasks.exe',
        arguments: ['/Run', '/TN', _taskName],
      );
      final result = await _processes.run(runTask);
      if (!runTask.acceptedExitCodes.contains(result.exitCode)) {
        throw AutoStartCommandException(runTask, result);
      }
      return const WindowsMySqlAutoStartResult(
        mode: WindowsMySqlAutoStartMode.scheduledTask,
      );
    } on Object catch (error) {
      if (error is! AutoStartCommandException && error is! ProcessException) {
        rethrow;
      }
      if (taskCreated) {
        await coordinator.uninstall(taskPlan);
      }
      return _enableUserRunKey(coordinator, launch);
    }
  }

  Future<WindowsMySqlAutoStartResult> _enableUserRunKey(
    AutoStartCoordinator coordinator,
    MySqlLaunchConfiguration launch,
  ) async {
    final launcherPath = _launcherPath(launch);
    final plan = WindowsAutoStartPlan.userRunKey(
      id: 'mysql-user-run',
      valueName: _runValueName,
      executable: 'wscript.exe',
      arguments: [launcherPath],
      artifacts: [ManagedArtifact.text(launcherPath, _hiddenLauncher(launch))],
    );
    await coordinator.enable(plan);
    final start = ActivationCommand(
      executable: 'wscript.exe',
      arguments: [launcherPath],
    );
    final result = await _processes.run(start);
    if (!start.acceptedExitCodes.contains(result.exitCode)) {
      throw AutoStartCommandException(start, result);
    }
    return WindowsMySqlAutoStartResult(
      mode: WindowsMySqlAutoStartMode.userRunKey,
      launcherPath: launcherPath,
    );
  }

  String _launcherPath(MySqlLaunchConfiguration launch) =>
      '${launch.dataDirectory}\\lc-start-mysql.vbs';
}

String _hiddenLauncher(MySqlLaunchConfiguration launch) {
  final command = _windowsCommandLine(
    launch.executable,
    launch.serverArguments,
  ).replaceAll('"', '""');
  return 'Option Explicit\r\n'
      'Dim shell\r\n'
      'Set shell = CreateObject("WScript.Shell")\r\n'
      'shell.Run "$command", 0, False\r\n';
}

String _windowsCommandLine(String executable, List<String> arguments) {
  return [_windowsQuote(executable), ...arguments.map(_windowsQuote)].join(' ');
}

String _windowsQuote(String value) {
  if (value.isEmpty) return '""';
  if (!RegExp(r'[\s"]').hasMatch(value)) return value;
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final codePoint in value.runes) {
    final character = String.fromCharCode(codePoint);
    if (character == r'\') {
      backslashes++;
    } else if (character == '"') {
      buffer
        ..write(r'\' * (backslashes * 2 + 1))
        ..write('"');
      backslashes = 0;
    } else {
      buffer
        ..write(r'\' * backslashes)
        ..write(character);
      backslashes = 0;
    }
  }
  buffer
    ..write(r'\' * (backslashes * 2))
    ..write('"');
  return buffer.toString();
}
