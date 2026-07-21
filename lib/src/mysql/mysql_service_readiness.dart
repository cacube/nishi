import 'dart:io';

import '../compatibility/service_probe.dart';
import 'mysql_configurator.dart';

typedef MySqlReadinessProbe = Future<ServiceProbeResult> Function(int port);
typedef MySqlReadinessDelay = Future<void> Function(Duration duration);
typedef MySqlManagedInstanceProbe =
    Future<bool> Function(MySqlLaunchConfiguration launch);

final class MySqlServiceStartException implements Exception {
  const MySqlServiceStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class MySqlServiceReadiness {
  MySqlServiceReadiness({
    MySqlReadinessProbe? probe,
    MySqlReadinessDelay? delay,
    MySqlManagedInstanceProbe? managedInstanceProbe,
    this.maximumAttempts = 30,
    this.retryDelay = const Duration(seconds: 1),
  }) : _probe = probe ?? _defaultProbe,
       _delay = delay ?? Future<void>.delayed,
       _managedInstanceProbe =
           managedInstanceProbe ?? _defaultManagedInstanceProbe {
    if (maximumAttempts < 1) {
      throw ArgumentError.value(maximumAttempts, 'maximumAttempts');
    }
  }

  final MySqlReadinessProbe _probe;
  final MySqlReadinessDelay _delay;
  final MySqlManagedInstanceProbe _managedInstanceProbe;
  final int maximumAttempts;
  final Duration retryDelay;

  Future<ServiceProbeResult> wait({
    required int port,
    required String expectedVersion,
    required MySqlLaunchConfiguration launch,
    void Function()? throwIfCancelled,
  }) async {
    ServiceProbeResult? lastResult;
    for (var attempt = 1; attempt <= maximumAttempts; attempt++) {
      throwIfCancelled?.call();
      lastResult = await _probe(port);
      if (lastResult.identified) {
        final version = lastResult.version;
        if (version != null && version.startsWith(expectedVersion)) {
          if (await _managedInstanceProbe(launch)) return lastResult;
          lastResult = const ServiceProbeResult(
            status: ServiceProbeStatus.connectionFailed,
            service: 'MySQL',
            message: '检测到同版本 MySQL，但不是 lc 管理的实例',
          );
        } else {
          throw MySqlServiceStartException(
            '端口 $port 已被其他 MySQL 版本占用：${version ?? '未知版本'}',
          );
        }
      }
      if (attempt < maximumAttempts) {
        await _delay(retryDelay);
        throwIfCancelled?.call();
      }
    }
    throw MySqlServiceStartException(
      'MySQL 未能在端口 $port 启动：${lastResult?.message ?? '连接失败'}',
    );
  }
}

Future<bool> _defaultManagedInstanceProbe(
  MySqlLaunchConfiguration launch,
) async {
  try {
    final pidFile = File(launch.pidFilePath);
    if (!await pidFile.exists()) return false;
    final processId = int.tryParse((await pidFile.readAsString()).trim());
    if (processId == null || processId < 1) return false;

    if (Platform.isWindows) {
      final result = await Process.run('tasklist.exe', [
        '/FI',
        'PID eq $processId',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if (result.exitCode != 0) return false;
      final firstField = _firstCsvField(result.stdout.toString());
      return firstField?.toLowerCase() ==
          _basename(launch.executable).toLowerCase();
    }

    final result = await Process.run('/bin/ps', [
      '-p',
      '$processId',
      '-o',
      'command=',
    ]);
    if (result.exitCode != 0) return false;
    final command = result.stdout.toString();
    return command.contains(launch.executable) &&
        launch.serverArguments.every(command.contains);
  } on FileSystemException {
    return false;
  } on ProcessException {
    return false;
  }
}

String? _firstCsvField(String output) {
  final firstLine = output
      .split(RegExp(r'[\r\n]'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  final match = RegExp(r'^"([^"]+)"').firstMatch(firstLine.trim());
  return match?.group(1);
}

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

Future<ServiceProbeResult> _defaultProbe(int port) {
  return TcpServiceProbe().probe(
    const MySqlHandshakeProtocol(),
    port: port,
    timeout: const Duration(seconds: 2),
  );
}
