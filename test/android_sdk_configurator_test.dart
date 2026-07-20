import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dev_environment_manager/src/android_sdk/android_sdk_configurator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'does not start sdkmanager until licenses are explicitly accepted',
    () async {
      final processes = _RecordingProcessStarter();
      final configurator = AndroidSdkConfigurator(
        sdkRoot: '/managed/android-sdk',
        jdkRoot: '/managed/jdk',
        packages: const ['platform-tools'],
        processStarter: processes,
        isWindows: false,
      );

      await expectLater(
        configurator.configure(licensesAccepted: false),
        throwsA(isA<AndroidSdkLicenseNotAcceptedException>()),
      );
      expect(processes.requests, isEmpty);
    },
  );

  test('accepts licenses before installing the fixed package set', () async {
    final licenseProcess = _CompletedProcess(stdoutText: 'licenses accepted');
    final installProcess = _CompletedProcess(stdoutText: 'packages installed');
    final processes = _RecordingProcessStarter([
      licenseProcess,
      installProcess,
    ]);
    final progress = <AndroidSdkConfigurationProgress>[];
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platform-tools', 'platforms;android-36'],
      processStarter: processes,
      isWindows: false,
    );

    await configurator.configure(
      licensesAccepted: true,
      onProgress: progress.add,
    );

    expect(processes.requests, hasLength(2));
    expect(
      processes.requests.first.executable,
      '/managed/android-sdk/cmdline-tools/latest/bin/sdkmanager',
    );
    expect(processes.requests.first.arguments, [
      '--sdk_root=/managed/android-sdk',
      '--licenses',
    ]);
    expect(processes.requests.last.arguments, [
      '--sdk_root=/managed/android-sdk',
      'platform-tools',
      'platforms;android-36',
    ]);
    expect(processes.requests.every((request) => !request.runInShell), isTrue);
    expect(processes.requests.first.environment, {
      'JAVA_HOME': '/managed/jdk',
      'ANDROID_HOME': '/managed/android-sdk',
      'ANDROID_SDK_ROOT': '/managed/android-sdk',
      'SDK_TEST_BASE_URL': 'https://dl.google.com/android/repository/',
    });
    expect(licenseProcess.stdinText, contains('y\n'));
    expect(licenseProcess.stdinClosed, isTrue);
    expect(installProcess.stdinText, isEmpty);
    expect(progress.first.stage, AndroidSdkConfigurationStage.licenses);
    expect(progress.last.stage, AndroidSdkConfigurationStage.completed);
    expect(progress.last.fraction, 1);
  });

  test('uses sdkmanager.bat through the Windows shell', () async {
    final processes = _RecordingProcessStarter([
      _CompletedProcess(),
      _CompletedProcess(),
    ]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: r'C:\Managed\Android SDK\',
      jdkRoot: r'C:\Managed\JDK',
      packages: const ['platform-tools'],
      processStarter: processes,
      isWindows: true,
    );

    await configurator.configure(licensesAccepted: true);

    expect(
      processes.requests.first.executable,
      r'C:\Managed\Android SDK\cmdline-tools\latest\bin\sdkmanager.bat',
    );
    expect(processes.requests.every((request) => request.runInShell), isTrue);
  });

  test('tolerates non-UTF-8 sdkmanager console output', () async {
    final processes = _RecordingProcessStarter([
      _CompletedProcess(stdoutBytes: const [0xff, 0xfe, 10]),
      _CompletedProcess(stdoutBytes: const [0x70, 0x61, 0x63, 0x6b, 0xff]),
    ]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: r'C:\Managed\Android SDK',
      jdkRoot: r'C:\Managed\JDK',
      packages: const ['platform-tools'],
      processStarter: processes,
      isWindows: true,
    );

    await configurator.configure(licensesAccepted: true);

    expect(processes.requests, hasLength(2));
  });

  test('reports license failure and does not install packages', () async {
    final processes = _RecordingProcessStarter([
      _CompletedProcess(
        exitCodeValue: 1,
        stderrText: 'license server unavailable',
      ),
    ]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platform-tools'],
      processStarter: processes,
      isWindows: false,
    );

    await expectLater(
      configurator.configure(licensesAccepted: true),
      throwsA(
        isA<AndroidSdkConfigurationException>()
            .having((error) => error.exitCode, 'exitCode', 1)
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('许可'), contains('license server unavailable')),
            ),
      ),
    );
    expect(processes.requests, hasLength(1));
  });

  test('reports package installation failure with sdkmanager output', () async {
    final processes = _RecordingProcessStarter([
      _CompletedProcess(),
      _CompletedProcess(exitCodeValue: 2, stderrText: 'package not found'),
    ]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platforms;android-36'],
      processStarter: processes,
      isWindows: false,
    );

    await expectLater(
      configurator.configure(licensesAccepted: true),
      throwsA(
        isA<AndroidSdkConfigurationException>()
            .having(
              (error) => error.stage,
              'stage',
              AndroidSdkConfigurationStage.packages,
            )
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('组件安装'), contains('package not found')),
            ),
      ),
    );
  });

  test(
    'selects a reachable repository mirror before running sdkmanager',
    () async {
      final processes = _RecordingProcessStarter([
        _CompletedProcess(),
        _CompletedProcess(stdoutText: 'packages installed from mirror'),
      ]);
      final progress = <AndroidSdkConfigurationProgress>[];
      final configurator = AndroidSdkConfigurator(
        sdkRoot: '/managed/android-sdk',
        jdkRoot: '/managed/jdk',
        packages: const ['platform-tools'],
        repositoryMirrorUrls: [
          Uri.parse('https://googledownloads.cn/android/repository/'),
        ],
        repositoryProbe: (url) async => url.host == 'googledownloads.cn',
        processStarter: processes,
        isWindows: false,
      );

      await configurator.configure(
        licensesAccepted: true,
        onProgress: progress.add,
      );

      expect(processes.requests, hasLength(2));
      expect(
        processes.requests[1].environment['SDK_TEST_BASE_URL'],
        'https://googledownloads.cn/android/repository/',
      );
      expect(
        progress.map((item) => item.message),
        contains('官网连接失败，正在切换 Android 国内镜像'),
      );
    },
  );

  test('does not retry a non-network sdkmanager failure', () async {
    final processes = _RecordingProcessStarter([
      _CompletedProcess(),
      _CompletedProcess(exitCodeValue: 1, stderrText: 'package not found'),
    ]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['missing-package'],
      repositoryMirrorUrls: [
        Uri.parse('https://googledownloads.cn/android/repository/'),
      ],
      repositoryProbe: (_) async => true,
      processStarter: processes,
      isWindows: false,
    );

    await expectLater(
      configurator.configure(licensesAccepted: true),
      throwsA(isA<AndroidSdkConfigurationException>()),
    );

    expect(processes.requests, hasLength(2));
  });

  test('times out and kills a stalled sdkmanager process', () async {
    final stalledProcess = _BlockingProcess();
    final processes = _RecordingProcessStarter([stalledProcess]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platform-tools'],
      repositoryMirrorUrls: [
        Uri.parse('https://googledownloads.cn/android/repository/'),
      ],
      repositoryProbe: (url) async => url.host == 'googledownloads.cn',
      processStarter: processes,
      processTimeout: const Duration(milliseconds: 10),
      isWindows: false,
    );

    await expectLater(
      configurator.configure(licensesAccepted: true),
      throwsA(
        isA<AndroidSdkConfigurationException>().having(
          (error) => error.exitCode,
          'exitCode',
          -1,
        ),
      ),
    );

    expect(stalledProcess.killed, isTrue);
    expect(processes.requests, hasLength(1));
  });

  test('cancellation kills sdkmanager and stops the configuration', () async {
    final activeProcess = _BlockingProcess();
    final processes = _RecordingProcessStarter([activeProcess]);
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platform-tools'],
      processStarter: processes,
      isWindows: false,
    );

    final configureFuture = configurator.configure(licensesAccepted: true);
    final expectation = expectLater(
      configureFuture,
      throwsA(isA<AndroidSdkConfigurationCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);
    configurator.cancel();

    await expectation;
    expect(activeProcess.killed, isTrue);
    expect(processes.requests, hasLength(1));
  });

  test('reports a readable error when sdkmanager cannot start', () async {
    final processes = _RecordingProcessStarter.throwing(
      ProcessException('sdkmanager', const [], 'No such file', 2),
    );
    final configurator = AndroidSdkConfigurator(
      sdkRoot: '/managed/android-sdk',
      jdkRoot: '/managed/jdk',
      packages: const ['platform-tools'],
      processStarter: processes,
      isWindows: false,
    );

    await expectLater(
      configurator.configure(licensesAccepted: true),
      throwsA(
        isA<AndroidSdkProcessStartException>()
            .having(
              (error) => error.stage,
              'stage',
              AndroidSdkConfigurationStage.licenses,
            )
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('sdkmanager'), contains('No such file')),
            ),
      ),
    );
  });
}

final class _RecordingProcessStarter implements AndroidSdkProcessStarter {
  _RecordingProcessStarter([List<AndroidSdkProcess> processes = const []])
    : _processes = List.of(processes),
      startError = null;

  _RecordingProcessStarter.throwing(this.startError) : _processes = [];

  final List<AndroidSdkProcess> _processes;
  final Object? startError;
  final List<AndroidSdkProcessRequest> requests = [];

  @override
  Future<AndroidSdkProcess> start(AndroidSdkProcessRequest request) {
    requests.add(request);
    if (startError case final error?) {
      return Future.error(error);
    }
    if (_processes.isEmpty) {
      throw StateError('No process was expected');
    }
    return Future.value(_processes.removeAt(0));
  }
}

final class _CompletedProcess implements AndroidSdkProcess {
  _CompletedProcess({
    this.exitCodeValue = 0,
    this.stdoutText = '',
    this.stderrText = '',
    this.stdoutBytes,
  });

  final int exitCodeValue;
  final String stdoutText;
  final String stderrText;
  final List<int>? stdoutBytes;
  final StringBuffer _stdin = StringBuffer();
  bool stdinClosed = false;
  bool killed = false;

  String get stdinText => _stdin.toString();

  @override
  Stream<List<int>> get stdout =>
      Stream.value(stdoutBytes ?? utf8.encode(stdoutText));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));

  @override
  Future<int> get exitCode => Future.value(exitCodeValue);

  @override
  void writeToStdin(String input) => _stdin.write(input);

  @override
  Future<void> closeStdin() async {
    stdinClosed = true;
  }

  @override
  bool kill() {
    killed = true;
    return true;
  }
}

final class _BlockingProcess implements AndroidSdkProcess {
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
  void writeToStdin(String input) {}

  @override
  Future<void> closeStdin() async {}

  @override
  bool kill() {
    killed = true;
    _stdout.close();
    _stderr.close();
    _exitCode.complete(143);
    return true;
  }
}
