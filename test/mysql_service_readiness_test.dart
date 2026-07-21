import 'package:dev_environment_manager/src/compatibility/service_probe.dart';
import 'package:dev_environment_manager/src/mysql/mysql_configurator.dart';
import 'package:dev_environment_manager/src/mysql/mysql_service_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const launch = MySqlLaunchConfiguration(
    mysqlRoot: '/runtime/mysql',
    executable: '/runtime/mysql/bin/mysqld',
    dataDirectory: '/runtime/data/mysql',
    logDirectory: '/runtime/logs/mysql',
    configPath: '/runtime/data/mysql/my.cnf',
    pidFilePath: '/runtime/data/mysql/mysql.pid',
    stdoutPath: '/runtime/logs/mysql/stdout.log',
    stderrPath: '/runtime/logs/mysql/stderr.log',
    serverArguments: ['--defaults-file=/runtime/data/mysql/my.cnf'],
  );

  test('waits until the expected MySQL protocol is ready', () async {
    var attempts = 0;
    final readiness = MySqlServiceReadiness(
      maximumAttempts: 3,
      retryDelay: Duration.zero,
      delay: (_) async {},
      managedInstanceProbe: (_) async => true,
      probe: (_) async {
        attempts++;
        return ServiceProbeResult(
          status: attempts == 1
              ? ServiceProbeStatus.connectionFailed
              : ServiceProbeStatus.identified,
          service: 'MySQL',
          version: attempts == 1 ? null : '8.4.10',
          message: attempts == 1 ? 'not ready' : 'ready',
        );
      },
    );

    final result = await readiness.wait(
      port: 3306,
      expectedVersion: '8.4.10',
      launch: launch,
    );

    expect(result.identified, isTrue);
    expect(attempts, 2);
  });

  test('rejects another MySQL version already using the port', () async {
    final readiness = MySqlServiceReadiness(
      maximumAttempts: 1,
      managedInstanceProbe: (_) async => true,
      probe: (_) async => const ServiceProbeResult(
        status: ServiceProbeStatus.identified,
        service: 'MySQL',
        version: '5.7.44',
        message: 'ready',
      ),
    );

    await expectLater(
      readiness.wait(port: 3306, expectedVersion: '8.4.10', launch: launch),
      throwsA(
        isA<MySqlServiceStartException>().having(
          (error) => error.message,
          'message',
          allOf(contains('3306'), contains('5.7.44')),
        ),
      ),
    );
  });

  test('fails after bounded connection attempts', () async {
    var attempts = 0;
    final readiness = MySqlServiceReadiness(
      maximumAttempts: 2,
      retryDelay: Duration.zero,
      delay: (_) async {},
      managedInstanceProbe: (_) async => true,
      probe: (_) async {
        attempts++;
        return const ServiceProbeResult(
          status: ServiceProbeStatus.connectionFailed,
          service: 'MySQL',
          message: 'connection refused',
        );
      },
    );

    await expectLater(
      readiness.wait(port: 3306, expectedVersion: '8.4.10', launch: launch),
      throwsA(isA<MySqlServiceStartException>()),
    );
    expect(attempts, 2);
  });

  test('does not accept another same-version MySQL instance', () async {
    final readiness = MySqlServiceReadiness(
      maximumAttempts: 2,
      retryDelay: Duration.zero,
      delay: (_) async {},
      managedInstanceProbe: (_) async => false,
      probe: (_) async => const ServiceProbeResult(
        status: ServiceProbeStatus.identified,
        service: 'MySQL',
        version: '8.4.10',
        message: 'ready',
      ),
    );

    await expectLater(
      readiness.wait(port: 3306, expectedVersion: '8.4.10', launch: launch),
      throwsA(
        isA<MySqlServiceStartException>().having(
          (error) => error.message,
          'message',
          contains('不是 lc 管理的实例'),
        ),
      ),
    );
  });

  test('honors cancellation while waiting for MySQL', () async {
    var cancelled = false;
    final readiness = MySqlServiceReadiness(
      maximumAttempts: 2,
      retryDelay: Duration.zero,
      delay: (_) async => cancelled = true,
      managedInstanceProbe: (_) async => true,
      probe: (_) async => const ServiceProbeResult(
        status: ServiceProbeStatus.connectionFailed,
        service: 'MySQL',
        message: 'not ready',
      ),
    );

    await expectLater(
      readiness.wait(
        port: 3306,
        expectedVersion: '8.4.10',
        launch: launch,
        throwIfCancelled: () {
          if (cancelled) throw const MySqlConfigurationCancelledException();
        },
      ),
      throwsA(isA<MySqlConfigurationCancelledException>()),
    );
  });
}
