import 'dart:convert';
import 'dart:io';
import 'dart:math';

final class MySqlProcessRequest {
  const MySqlProcessRequest({
    required this.executable,
    required this.arguments,
    required this.runInShell,
  });

  final String executable;
  final List<String> arguments;
  final bool runInShell;
}

abstract interface class MySqlProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  bool kill();
}

abstract interface class MySqlProcessStarter {
  Future<MySqlProcess> start(MySqlProcessRequest request);
}

final class SystemMySqlProcessStarter implements MySqlProcessStarter {
  const SystemMySqlProcessStarter();

  @override
  Future<MySqlProcess> start(MySqlProcessRequest request) async {
    final process = await Process.start(
      request.executable,
      request.arguments,
      runInShell: request.runInShell,
    );
    return _SystemMySqlProcess(process);
  }
}

final class MySqlLaunchConfiguration {
  const MySqlLaunchConfiguration({
    required this.mysqlRoot,
    required this.executable,
    required this.dataDirectory,
    required this.logDirectory,
    required this.configPath,
    required this.pidFilePath,
    required this.stdoutPath,
    required this.stderrPath,
    required this.serverArguments,
  });

  final String mysqlRoot;
  final String executable;
  final String dataDirectory;
  final String logDirectory;
  final String configPath;
  final String pidFilePath;
  final String stdoutPath;
  final String stderrPath;
  final List<String> serverArguments;
}

final class MySqlConfigurationResult {
  const MySqlConfigurationResult({
    required this.launchConfiguration,
    required this.initialized,
    required this.credentialsPath,
    required this.bootstrapSqlPath,
  });

  final MySqlLaunchConfiguration launchConfiguration;
  final bool initialized;
  final String credentialsPath;
  final String bootstrapSqlPath;
}

final class MySqlInitializationException implements Exception {
  const MySqlInitializationException({
    required this.exitCode,
    required this.details,
  });

  final int exitCode;
  final String details;

  @override
  String toString() {
    final suffix = details.trim().isEmpty ? '' : '：${details.trim()}';
    return 'MySQL 初始化失败（退出码 $exitCode）$suffix';
  }
}

final class MySqlConfigurationCancelledException implements Exception {
  const MySqlConfigurationCancelledException();

  @override
  String toString() => 'MySQL 配置已取消';
}

final class MySqlConfigurator {
  MySqlConfigurator({
    required this.mysqlRoot,
    required this.dataDirectory,
    required this.logDirectory,
    MySqlProcessStarter processStarter = const SystemMySqlProcessStarter(),
    bool? isWindows,
    String Function()? passwordGenerator,
  }) : _processStarter = processStarter,
       isWindows = isWindows ?? Platform.isWindows,
       _passwordGenerator = passwordGenerator ?? _generatePassword;

  final String mysqlRoot;
  final Directory dataDirectory;
  final Directory logDirectory;
  final bool isWindows;
  final MySqlProcessStarter _processStarter;
  final String Function() _passwordGenerator;
  MySqlProcess? _activeProcess;
  bool _cancelRequested = false;

  void cancel() {
    _cancelRequested = true;
    _activeProcess?.kill();
  }

  void throwIfCancelled() {
    if (_cancelRequested) {
      throw const MySqlConfigurationCancelledException();
    }
  }

  Future<MySqlConfigurationResult> configure() async {
    _cancelRequested = false;
    await dataDirectory.create(recursive: true);
    await logDirectory.create(recursive: true);
    final launch = _launchConfiguration;
    final marker = File(_securityMarkerPath);
    final initializationMarker = File(_initializationMarkerPath);
    final credentials = File(_join(dataDirectory.path, 'credentials.json'));
    final systemTables = Directory(_join(dataDirectory.path, 'mysql'));
    final hasSystemTables =
        await systemTables.exists() && !await systemTables.list().isEmpty;
    final isManagedDatabase =
        hasSystemTables &&
        (await credentials.exists() ||
            await marker.exists() ||
            await File(launch.configPath).exists());
    if (isManagedDatabase) {
      final result = await _prepareSecureBootstrap(launch, initialized: false);
      if (await marker.exists()) await marker.delete();
      if (await initializationMarker.exists()) {
        await initializationMarker.delete();
      }
      return result;
    }
    if (!await dataDirectory.list().isEmpty) {
      await _preserveIncompleteDataDirectory();
      await dataDirectory.create(recursive: true);
    }

    throwIfCancelled();
    await initializationMarker.writeAsString(
      DateTime.now().toUtc().toIso8601String(),
      flush: true,
    );
    try {
      final process = await _processStarter.start(
        MySqlProcessRequest(
          executable: launch.executable,
          arguments: [
            '--initialize-insecure',
            '--basedir=$mysqlRoot',
            '--datadir=${dataDirectory.path}',
          ],
          runInShell: false,
        ),
      );
      _activeProcess = process;
      try {
        if (_cancelRequested) {
          process.kill();
          throw const MySqlConfigurationCancelledException();
        }
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        final exitCode = await process.exitCode;
        final output = await stdout;
        final errorOutput = await stderr;
        throwIfCancelled();
        if (exitCode != 0) {
          throw MySqlInitializationException(
            exitCode: exitCode,
            details: errorOutput.trim().isNotEmpty ? errorOutput : output,
          );
        }
      } finally {
        if (identical(_activeProcess, process)) {
          _activeProcess = null;
        }
      }

      throwIfCancelled();
      final result = await _prepareSecureBootstrap(launch, initialized: true);
      if (await marker.exists()) await marker.delete();
      if (await initializationMarker.exists()) {
        await initializationMarker.delete();
      }
      return result;
    } on Object {
      await _cleanOwnedIncompleteInitialization(initializationMarker);
      rethrow;
    }
  }

  MySqlLaunchConfiguration get _launchConfiguration {
    final executable = _join(
      _join(mysqlRoot, 'bin'),
      isWindows ? 'mysqld.exe' : 'mysqld',
    );
    final configPath = _join(
      dataDirectory.path,
      isWindows ? 'my.ini' : 'my.cnf',
    );
    final pidFilePath = _join(dataDirectory.path, 'mysql.pid');
    return MySqlLaunchConfiguration(
      mysqlRoot: mysqlRoot,
      executable: executable,
      dataDirectory: dataDirectory.path,
      logDirectory: logDirectory.path,
      configPath: configPath,
      pidFilePath: pidFilePath,
      stdoutPath: _join(logDirectory.path, 'mysql-stdout.log'),
      stderrPath: _join(logDirectory.path, 'mysql-stderr.log'),
      serverArguments: ['--defaults-file=$configPath'],
    );
  }

  String get _securityMarkerPath =>
      _join(dataDirectory.path, '.root-password-required');

  String get _initializationMarkerPath => '${dataDirectory.path}.initializing';

  Future<void> _preserveIncompleteDataDirectory() async {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final recovery = Directory('${dataDirectory.path}.recovered-$timestamp');
    await dataDirectory.rename(recovery.path);
  }

  Future<void> _cleanOwnedIncompleteInitialization(File marker) async {
    if (!await marker.exists()) return;
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
    await marker.delete();
  }

  Future<MySqlConfigurationResult> _prepareSecureBootstrap(
    MySqlLaunchConfiguration launch, {
    required bool initialized,
  }) async {
    final credentials = File(_join(dataDirectory.path, 'credentials.json'));
    final bootstrap = File(_join(dataDirectory.path, '.nishi-bootstrap.sql'));
    final password = await _loadOrCreatePassword(credentials);
    await _writePrivateFile(
      bootstrap,
      "ALTER USER 'root'@'localhost' IDENTIFIED BY '$password';\n",
    );
    await File(
      launch.configPath,
    ).writeAsString(_renderConfiguration(launch, bootstrap.path), flush: true);
    return MySqlConfigurationResult(
      launchConfiguration: launch,
      initialized: initialized,
      credentialsPath: credentials.path,
      bootstrapSqlPath: bootstrap.path,
    );
  }

  Future<String> _loadOrCreatePassword(File credentials) async {
    if (await credentials.exists()) {
      final decoded = jsonDecode(await credentials.readAsString());
      if (decoded is Map<String, Object?> && decoded['password'] is String) {
        return decoded['password']! as String;
      }
      throw const FormatException('MySQL credentials file is invalid');
    }
    final password = _passwordGenerator();
    if (!RegExp(r'^[A-Za-z0-9_-]{16,}$').hasMatch(password)) {
      throw StateError('Generated MySQL password is not safe');
    }
    await _writePrivateFile(
      credentials,
      '${jsonEncode({'host': '127.0.0.1', 'port': 3306, 'username': 'root', 'password': password})}\n',
    );
    return password;
  }

  Future<void> _writePrivateFile(File file, String contents) async {
    await file.writeAsString(contents, flush: true);
    if (!isWindows) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        await file.delete();
        throw FileSystemException('Could not secure MySQL file', file.path);
      }
    }
  }

  String _renderConfiguration(
    MySqlLaunchConfiguration launch,
    String bootstrapSqlPath,
  ) {
    String optionPath(String path) {
      final normalized = isWindows ? path.replaceAll(r'\', '/') : path;
      return normalized.replaceAll('"', r'\"');
    }

    return '''[mysqld]
port=3306
bind-address=127.0.0.1
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
basedir="${optionPath(launch.mysqlRoot)}"
datadir="${optionPath(launch.dataDirectory)}"
log-error="${optionPath(_join(launch.logDirectory, 'mysql-error.log'))}"
pid-file="${optionPath(launch.pidFilePath)}"
init-file="${optionPath(bootstrapSqlPath)}"

[client]
port=3306
default-character-set=utf8mb4
''';
  }

  String _join(String parent, String child) {
    final separator = isWindows ? r'\' : '/';
    if (parent.endsWith('/') || parent.endsWith(r'\')) return '$parent$child';
    return '$parent$separator$child';
  }
}

String _generatePassword() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

final class _SystemMySqlProcess implements MySqlProcess {
  _SystemMySqlProcess(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill();
}
