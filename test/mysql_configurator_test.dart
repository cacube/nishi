import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dev_environment_manager/src/mysql/mysql_configurator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'mysql_configurator_test_',
    );
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test(
    'initializes an empty data directory with a private bootstrap password',
    () async {
      final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
      final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
      final processes = _RecordingProcessStarter([_CompletedProcess()]);
      final configurator = MySqlConfigurator(
        mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
        dataDirectory: dataDirectory,
        logDirectory: logDirectory,
        processStarter: processes,
        isWindows: false,
        passwordGenerator: () => 'test-local-password',
      );

      final result = await configurator.configure();

      expect(processes.requests, hasLength(1));
      expect(
        processes.requests.single.executable,
        '${temporaryRoot.path}/runtimes/mysql/bin/mysqld',
      );
      expect(processes.requests.single.arguments, [
        '--initialize-insecure',
        '--basedir=${temporaryRoot.path}/runtimes/mysql',
        '--datadir=${dataDirectory.path}',
      ]);
      final launch = result.launchConfiguration;
      expect(result.initialized, isTrue);
      expect(launch.serverArguments, ['--defaults-file=${launch.configPath}']);
      expect(
        await File(launch.configPath).readAsString(),
        allOf(
          contains('port=3306'),
          contains('bind-address=127.0.0.1'),
          contains('character-set-server=utf8mb4'),
          contains('datadir="${dataDirectory.path}"'),
          contains('log-error="${logDirectory.path}/mysql-error.log"'),
          contains('pid-file="${dataDirectory.path}/mysql.pid"'),
          contains('init-file="${result.bootstrapSqlPath}"'),
        ),
      );
      expect(
        await File(result.bootstrapSqlPath).readAsString(),
        contains(
          "ALTER USER 'root'@'localhost' IDENTIFIED BY 'test-local-password'",
        ),
      );
      expect(
        await File(result.credentialsPath).readAsString(),
        allOf(contains('"username":"root"'), contains('test-local-password')),
      );
      expect((await File(result.credentialsPath).stat()).mode & 0x3f, 0);
      expect(
        await File('${dataDirectory.path}/.root-password-required').exists(),
        isFalse,
      );
    },
  );

  test(
    'skips initialization when the mysql system tables already exist',
    () async {
      final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
      final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
      final systemTables = Directory('${dataDirectory.path}/mysql');
      await systemTables.create(recursive: true);
      await File('${systemTables.path}/user.ibd').writeAsString('existing');
      final processes = _RecordingProcessStarter(const []);
      final configurator = MySqlConfigurator(
        mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
        dataDirectory: dataDirectory,
        logDirectory: logDirectory,
        processStarter: processes,
        isWindows: false,
      );

      final result = await configurator.configure();

      expect(result.initialized, isFalse);
      expect(processes.requests, isEmpty);
      expect(
        await File(result.launchConfiguration.configPath).exists(),
        isTrue,
      );
      expect(result.launchConfiguration.serverArguments, [
        '--defaults-file=${result.launchConfiguration.configPath}',
      ]);
    },
  );

  test(
    'migrates a previously insecure initialization to managed credentials',
    () async {
      final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
      final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
      final systemTables = Directory('${dataDirectory.path}/mysql');
      await systemTables.create(recursive: true);
      await File('${systemTables.path}/user.ibd').writeAsString('existing');
      final marker = File('${dataDirectory.path}/.root-password-required');
      await marker.writeAsString('password change still required');
      final processes = _RecordingProcessStarter(const []);
      final configurator = MySqlConfigurator(
        mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
        dataDirectory: dataDirectory,
        logDirectory: logDirectory,
        processStarter: processes,
        isWindows: false,
        passwordGenerator: () => 'migrated-password',
      );

      final result = await configurator.configure();

      expect(result.initialized, isFalse);
      expect(await marker.exists(), isFalse);
      expect(await File(result.bootstrapSqlPath).exists(), isTrue);
      expect(
        await File(result.credentialsPath).readAsString(),
        contains('migrated-password'),
      );
      expect(processes.requests, isEmpty);
    },
  );

  test('refuses a non-empty directory without mysql system tables', () async {
    final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
    final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
    await dataDirectory.create(recursive: true);
    await File('${dataDirectory.path}/unrelated.txt').writeAsString('keep me');
    final processes = _RecordingProcessStarter(const []);
    final configurator = MySqlConfigurator(
      mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
      dataDirectory: dataDirectory,
      logDirectory: logDirectory,
      processStarter: processes,
      isWindows: false,
    );

    await expectLater(
      configurator.configure(),
      throwsA(
        isA<MySqlDataDirectoryConflictException>().having(
          (error) => error.toString(),
          'message',
          allOf(contains('非空'), contains(dataDirectory.path)),
        ),
      ),
    );
    expect(processes.requests, isEmpty);
  });

  test(
    'reports initialization failure without persisting success state',
    () async {
      final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
      final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
      final processes = _RecordingProcessStarter([
        _CompletedProcess(exitCodeValue: 1, stderrText: 'permission denied'),
      ]);
      final configurator = MySqlConfigurator(
        mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
        dataDirectory: dataDirectory,
        logDirectory: logDirectory,
        processStarter: processes,
        isWindows: false,
      );

      await expectLater(
        configurator.configure(),
        throwsA(
          isA<MySqlInitializationException>()
              .having((error) => error.exitCode, 'exitCode', 1)
              .having(
                (error) => error.toString(),
                'message',
                allOf(contains('初始化失败'), contains('permission denied')),
              ),
        ),
      );
      expect(await File('${dataDirectory.path}/my.cnf').exists(), isFalse);
      expect(
        await File('${dataDirectory.path}/.root-password-required').exists(),
        isFalse,
      );
    },
  );

  test('cancellation kills an active initialization process', () async {
    final dataDirectory = Directory('${temporaryRoot.path}/data/mysql');
    final logDirectory = Directory('${temporaryRoot.path}/logs/mysql');
    final activeProcess = _BlockingProcess();
    final processes = _RecordingProcessStarter([activeProcess]);
    final configurator = MySqlConfigurator(
      mysqlRoot: '${temporaryRoot.path}/runtimes/mysql',
      dataDirectory: dataDirectory,
      logDirectory: logDirectory,
      processStarter: processes,
      isWindows: false,
    );

    final configureFuture = configurator.configure();
    final expectation = expectLater(
      configureFuture,
      throwsA(isA<MySqlConfigurationCancelledException>()),
    );
    await processes.started.future;
    configurator.cancel();

    await expectation;
    expect(activeProcess.killed, isTrue);
    expect(await File('${dataDirectory.path}/my.cnf').exists(), isFalse);
  });
}

final class _RecordingProcessStarter implements MySqlProcessStarter {
  _RecordingProcessStarter(List<MySqlProcess> processes)
    : _processes = List.of(processes);

  final List<MySqlProcess> _processes;
  final List<MySqlProcessRequest> requests = [];
  final Completer<void> started = Completer<void>();

  @override
  Future<MySqlProcess> start(MySqlProcessRequest request) async {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return _processes.removeAt(0);
  }
}

final class _CompletedProcess implements MySqlProcess {
  _CompletedProcess({this.exitCodeValue = 0, this.stderrText = ''});

  final int exitCodeValue;
  final String stderrText;
  bool killed = false;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));

  @override
  Future<int> get exitCode => Future.value(exitCodeValue);

  @override
  bool kill() {
    killed = true;
    return true;
  }
}

final class _BlockingProcess implements MySqlProcess {
  final StreamController<List<int>> _stdout = StreamController();
  final StreamController<List<int>> _stderr = StreamController();
  final Completer<int> _exitCode = Completer();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill() {
    killed = true;
    _stdout.close();
    _stderr.close();
    _exitCode.complete(143);
    return true;
  }
}
