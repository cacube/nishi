import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef AndroidSdkProgressCallback =
    void Function(AndroidSdkConfigurationProgress progress);
typedef AndroidSdkRepositoryProbe = Future<bool> Function(Uri repositoryUrl);
typedef AndroidSdkRepositorySourceOrderer =
    List<Uri> Function(List<Uri> repositoryUrls);

enum AndroidSdkConfigurationStage { licenses, packages, completed }

final class AndroidSdkConfigurationProgress {
  const AndroidSdkConfigurationProgress({
    required this.stage,
    required this.fraction,
    required this.message,
  });

  final AndroidSdkConfigurationStage stage;
  final double fraction;
  final String message;
}

final class AndroidSdkProcessRequest {
  const AndroidSdkProcessRequest({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.runInShell,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final bool runInShell;
}

abstract interface class AndroidSdkProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  void writeToStdin(String input);
  Future<void> closeStdin();
  bool kill();
}

abstract interface class AndroidSdkProcessStarter {
  Future<AndroidSdkProcess> start(AndroidSdkProcessRequest request);
}

final class SystemAndroidSdkProcessStarter implements AndroidSdkProcessStarter {
  const SystemAndroidSdkProcessStarter();

  @override
  Future<AndroidSdkProcess> start(AndroidSdkProcessRequest request) async {
    final process = await Process.start(
      request.executable,
      request.arguments,
      environment: request.environment,
      runInShell: request.runInShell,
    );
    return _SystemAndroidSdkProcess(process);
  }
}

final class AndroidSdkLicenseNotAcceptedException implements Exception {
  const AndroidSdkLicenseNotAcceptedException();

  @override
  String toString() =>
      'Android SDK licenses must be explicitly accepted before configuration.';
}

final class AndroidSdkConfigurationException implements Exception {
  const AndroidSdkConfigurationException({
    required this.stage,
    required this.exitCode,
    required this.details,
  });

  final AndroidSdkConfigurationStage stage;
  final int exitCode;
  final String details;

  @override
  String toString() {
    final operation = switch (stage) {
      AndroidSdkConfigurationStage.licenses => 'Android SDK 许可确认',
      AndroidSdkConfigurationStage.packages => 'Android SDK 组件安装',
      AndroidSdkConfigurationStage.completed => 'Android SDK 配置',
    };
    final suffix = details.trim().isEmpty ? '' : '：${details.trim()}';
    return '$operation失败（退出码 $exitCode）$suffix';
  }
}

final class AndroidSdkConfigurationCancelledException implements Exception {
  const AndroidSdkConfigurationCancelledException();

  @override
  String toString() => 'Android SDK 配置已取消';
}

final class AndroidSdkProcessStartException implements Exception {
  const AndroidSdkProcessStartException({
    required this.stage,
    required this.executable,
    required this.details,
  });

  final AndroidSdkConfigurationStage stage;
  final String executable;
  final String details;

  @override
  String toString() => '无法启动 Android SDK 工具 $executable：$details';
}

final class AndroidSdkConfigurator {
  AndroidSdkConfigurator({
    required this.sdkRoot,
    required this.jdkRoot,
    required List<String> packages,
    List<Uri> repositoryMirrorUrls = const [],
    AndroidSdkProcessStarter processStarter =
        const SystemAndroidSdkProcessStarter(),
    AndroidSdkRepositoryProbe repositoryProbe = _probeAndroidSdkRepository,
    AndroidSdkRepositorySourceOrderer? repositorySourceOrderer,
    this.processTimeout = const Duration(minutes: 20),
    bool? isWindows,
  }) : packages = List.unmodifiable(packages),
       repositoryMirrorUrls = List.unmodifiable(repositoryMirrorUrls),
       _processStarter = processStarter,
       _repositoryProbe = repositoryProbe,
       _repositorySourceOrderer = repositorySourceOrderer,
       isWindows = isWindows ?? Platform.isWindows;

  final String sdkRoot;
  final String jdkRoot;
  final List<String> packages;
  final List<Uri> repositoryMirrorUrls;
  final Duration processTimeout;
  final bool isWindows;
  final AndroidSdkProcessStarter _processStarter;
  final AndroidSdkRepositoryProbe _repositoryProbe;
  final AndroidSdkRepositorySourceOrderer? _repositorySourceOrderer;
  AndroidSdkProcess? _activeProcess;
  bool _cancelRequested = false;

  void cancel() {
    _cancelRequested = true;
    _activeProcess?.kill();
  }

  Future<void> configure({
    required bool licensesAccepted,
    AndroidSdkProgressCallback? onProgress,
  }) async {
    if (!licensesAccepted) {
      throw const AndroidSdkLicenseNotAcceptedException();
    }
    _cancelRequested = false;

    final executable = _sdkManagerExecutable;
    final repositoryUrl = await _selectRepository(onProgress);
    if (_cancelRequested) {
      throw const AndroidSdkConfigurationCancelledException();
    }
    final environment = <String, String>{
      'JAVA_HOME': jdkRoot,
      'ANDROID_HOME': sdkRoot,
      'ANDROID_SDK_ROOT': sdkRoot,
      _sdkRepositoryEnvironmentKey: repositoryUrl.toString(),
    };
    onProgress?.call(
      const AndroidSdkConfigurationProgress(
        stage: AndroidSdkConfigurationStage.licenses,
        fraction: 0,
        message: '正在确认 Android SDK 许可',
      ),
    );
    await _runProcess(
      AndroidSdkProcessRequest(
        executable: executable,
        arguments: ['--sdk_root=$sdkRoot', '--licenses'],
        environment: environment,
        runInShell: isWindows,
      ),
      stage: AndroidSdkConfigurationStage.licenses,
      stdin: '${List.filled(100, 'y').join('\n')}\n',
    );

    onProgress?.call(
      const AndroidSdkConfigurationProgress(
        stage: AndroidSdkConfigurationStage.packages,
        fraction: 0.35,
        message: '正在安装 Android SDK 组件',
      ),
    );
    await _runProcess(
      AndroidSdkProcessRequest(
        executable: executable,
        arguments: ['--sdk_root=$sdkRoot', ...packages],
        environment: environment,
        runInShell: isWindows,
      ),
      stage: AndroidSdkConfigurationStage.packages,
    );
    onProgress?.call(
      const AndroidSdkConfigurationProgress(
        stage: AndroidSdkConfigurationStage.completed,
        fraction: 1,
        message: 'Android SDK 配置完成',
      ),
    );
  }

  String get _sdkManagerExecutable {
    final separator = isWindows ? r'\' : '/';
    final root = sdkRoot.replaceAll(RegExp(r'[/\\]+$'), '');
    final name = isWindows ? 'sdkmanager.bat' : 'sdkmanager';
    return [root, 'cmdline-tools', 'latest', 'bin', name].join(separator);
  }

  Future<Uri> _selectRepository(AndroidSdkProgressCallback? onProgress) async {
    final configuredUrls = [
      Uri.parse(_officialRepositoryBaseUrl),
      ...repositoryMirrorUrls,
    ];
    final repositoryUrls =
        _repositorySourceOrderer?.call(configuredUrls) ?? configuredUrls;
    if (repositoryUrls.isEmpty) {
      throw StateError('Android SDK repository source list is empty');
    }
    if (repositoryUrls.length == 1 && _repositorySourceOrderer == null) {
      return repositoryUrls.single;
    }
    for (var index = 0; index < repositoryUrls.length; index++) {
      if (await _repositoryProbe(repositoryUrls[index])) {
        return repositoryUrls[index];
      }
      if (_cancelRequested) {
        throw const AndroidSdkConfigurationCancelledException();
      }
      if (index + 1 < repositoryUrls.length) {
        onProgress?.call(
          const AndroidSdkConfigurationProgress(
            stage: AndroidSdkConfigurationStage.licenses,
            fraction: 0,
            message: '当前 Android 仓库不可用，正在切换备用源',
          ),
        );
      }
    }
    throw AndroidSdkConfigurationException(
      stage: AndroidSdkConfigurationStage.licenses,
      exitCode: _repositoryUnavailableExitCode,
      details: '配置的 Android SDK 仓库均不可用',
    );
  }

  Future<void> _runProcess(
    AndroidSdkProcessRequest request, {
    required AndroidSdkConfigurationStage stage,
    String? stdin,
  }) async {
    if (_cancelRequested) {
      throw const AndroidSdkConfigurationCancelledException();
    }
    late final AndroidSdkProcess process;
    try {
      process = await _processStarter.start(request);
    } on ProcessException catch (error) {
      if (_cancelRequested) {
        throw const AndroidSdkConfigurationCancelledException();
      }
      throw AndroidSdkProcessStartException(
        stage: stage,
        executable: request.executable,
        details: error.message,
      );
    }
    _activeProcess = process;
    try {
      if (_cancelRequested) {
        process.kill();
        throw const AndroidSdkConfigurationCancelledException();
      }
      final stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (stdin != null) {
        process.writeToStdin(stdin);
        await process.closeStdin();
      }
      var timedOut = false;
      final exitCode = await process.exitCode.timeout(
        processTimeout,
        onTimeout: () {
          timedOut = true;
          process.kill();
          return _processTimeoutExitCode;
        },
      );
      final output = timedOut
          ? await stdout.timeout(
              const Duration(seconds: 5),
              onTimeout: () => '',
            )
          : await stdout;
      final errorOutput = timedOut
          ? await stderr.timeout(
              const Duration(seconds: 5),
              onTimeout: () => '',
            )
          : await stderr;
      if (_cancelRequested) {
        throw const AndroidSdkConfigurationCancelledException();
      }
      if (timedOut) {
        throw AndroidSdkConfigurationException(
          stage: stage,
          exitCode: _processTimeoutExitCode,
          details: '运行超过 ${processTimeout.inMinutes} 分钟，已停止',
        );
      }
      if (exitCode != 0) {
        throw AndroidSdkConfigurationException(
          stage: stage,
          exitCode: exitCode,
          details: errorOutput.trim().isNotEmpty ? errorOutput : output,
        );
      }
    } finally {
      if (identical(_activeProcess, process)) {
        _activeProcess = null;
      }
    }
  }
}

const _sdkRepositoryEnvironmentKey = 'SDK_TEST_BASE_URL';
const _officialRepositoryBaseUrl = 'https://dl.google.com/android/repository/';
const _repositoryUnavailableExitCode = -2;
const _processTimeoutExitCode = -1;

Future<bool> _probeAndroidSdkRepository(Uri repositoryUrl) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  HttpClientRequest? request;
  try {
    request = await client
        .getUrl(repositoryUrl.resolve('repository2-3.xml'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok) {
      request.abort();
      return false;
    }
    await response.drain<void>().timeout(const Duration(seconds: 30));
    return true;
  } on SocketException {
    return false;
  } on HttpException {
    return false;
  } on HandshakeException {
    return false;
  } on TimeoutException {
    request?.abort();
    return false;
  } finally {
    client.close(force: true);
  }
}

final class _SystemAndroidSdkProcess implements AndroidSdkProcess {
  _SystemAndroidSdkProcess(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeToStdin(String input) => _process.stdin.write(input);

  @override
  Future<void> closeStdin() => _process.stdin.close();

  @override
  bool kill() => _process.kill();
}
