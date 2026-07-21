import 'dart:io';

import 'package:dev_environment_manager/src/compatibility/service_probe.dart';
import 'package:dev_environment_manager/src/mysql/mysql_configurator.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scripts/runtime_smoke.dart';

void main() {
  const target = RuntimeTarget(
    platform: RuntimePlatform.macos,
    architecture: RuntimeArchitecture.arm64,
  );

  test(
    'selects requested managed components and their dependencies in order',
    () {
      final manifest = RuntimeManifest(
        schemaVersion: 1,
        components: [
          _component('flutter', dependencies: ['android-sdk']),
          _component('android-sdk', dependencies: ['jdk']),
          _component('jdk'),
          _component('mysql'),
        ],
      );

      final plan = RuntimeSmokePlan.fromManifest(
        manifest: manifest,
        target: target,
        requestedComponentIds: const ['flutter'],
      );

      expect(plan.entries.map((entry) => entry.component.id), [
        'jdk',
        'android-sdk',
        'flutter',
      ]);
    },
  );

  test('rejects a requested component that is absent from the manifest', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [_component('flutter')],
    );

    expect(
      () => RuntimeSmokePlan.fromManifest(
        manifest: manifest,
        target: target,
        requestedComponentIds: const ['flutter', 'jdk'],
      ),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          contains('jdk'),
        ),
      ),
    );
  });

  test('rejects an externally provisioned smoke target', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [_component('jdk', external: true)],
    );

    expect(
      () => RuntimeSmokePlan.fromManifest(
        manifest: manifest,
        target: target,
        requestedComponentIds: const ['jdk'],
      ),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          contains('must be managed'),
        ),
      ),
    );
  });

  test('marks Android activation as incomplete SDK provisioning', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [
        _component('jdk'),
        _component('android-sdk', dependencies: ['jdk']),
      ],
    );

    final plan = RuntimeSmokePlan.fromManifest(
      manifest: manifest,
      target: target,
      requestedComponentIds: const ['android-sdk'],
    );

    expect(plan.limitations, hasLength(1));
    expect(plan.limitations.single, contains('sdkmanager'));
    expect(plan.limitations.single, contains('licenses'));
    expect(plan.remainingLimitations(configureAndroidSdk: true), isEmpty);
  });

  test('parses explicit smoke mode, target, and Android license consent', () {
    final arguments = RuntimeSmokeArguments.parse(const [
      '--manifest=release/runtime-manifest.json',
      '--mode=download',
      '--target=windows/x64',
      '--components=flutter,jdk,android-sdk',
      '--root=.runtime-smoke',
      '--accept-android-licenses=true',
    ]);

    expect(arguments.mode, RuntimeSmokeMode.download);
    expect(arguments.target.platform, RuntimePlatform.windows);
    expect(arguments.target.architecture, RuntimeArchitecture.x64);
    expect(arguments.componentIds, ['flutter', 'jdk', 'android-sdk']);
    expect(arguments.root.path, '.runtime-smoke');
    expect(arguments.acceptAndroidLicenses, isTrue);
  });

  test('does not accept Android licenses by default', () {
    final arguments = RuntimeSmokeArguments.parse(const [
      '--manifest=release/runtime-manifest.json',
      '--target=macos/arm64',
    ]);

    expect(arguments.acceptAndroidLicenses, isFalse);
  });

  test('rejects an invalid Android license consent value', () {
    expect(
      () => RuntimeSmokeArguments.parse(const [
        '--manifest=release/runtime-manifest.json',
        '--target=macos/arm64',
        '--accept-android-licenses=yes',
      ]),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          contains('true or false'),
        ),
      ),
    );
  });

  test(
    'verifies Go from the activated runtime instead of the host PATH',
    () async {
      final root = Directory.systemTemp.createTempSync('runtime_smoke_go_');
      addTearDown(() => root.deleteSync(recursive: true));
      final commands = <RuntimeSmokeCommand>[];
      final verifier = RuntimeSmokeComponentVerifier(
        processRunner: (command) async {
          commands.add(command);
          return const RuntimeSmokeProcessResult(
            exitCode: 0,
            stdout: 'go version go1.26.5 darwin/arm64',
            stderr: '',
          );
        },
      );

      await verifier.verify(
        component: _component('go', version: '1.26.5'),
        activeDirectory: root,
        target: target,
      );

      expect(commands, hasLength(1));
      expect(commands.single.executable, '${root.path}/bin/go');
      expect(commands.single.arguments, ['version']);
    },
  );

  test('verifies both Node and its bundled npm executable', () async {
    final root = Directory.systemTemp.createTempSync('runtime_smoke_node_');
    addTearDown(() => root.deleteSync(recursive: true));
    final commands = <RuntimeSmokeCommand>[];
    final verifier = RuntimeSmokeComponentVerifier(
      processRunner: (command) async {
        commands.add(command);
        return RuntimeSmokeProcessResult(
          exitCode: 0,
          stdout: command.label == 'node' ? 'v24.18.0' : '11.9.0',
          stderr: '',
        );
      },
    );

    await verifier.verify(
      component: _component('node', version: '24.18.0'),
      activeDirectory: root,
      target: target,
    );

    expect(commands.map((command) => command.label), ['node', 'npm']);
    expect(commands[0].executable, '${root.path}/bin/node');
    expect(commands[1].executable, '${root.path}/bin/npm');
    expect(commands[1].arguments, ['--version']);
    expect(commands[1].environment['PATH'], startsWith('${root.path}/bin:'));
  });

  test('fails when an activated command reports the wrong version', () async {
    final root = Directory.systemTemp.createTempSync('runtime_smoke_version_');
    addTearDown(() => root.deleteSync(recursive: true));
    final verifier = RuntimeSmokeComponentVerifier(
      processRunner: (_) async => const RuntimeSmokeProcessResult(
        exitCode: 0,
        stdout: 'go version go1.25.0 darwin/arm64',
        stderr: '',
      ),
    );

    await expectLater(
      verifier.verify(
        component: _component('go', version: '1.26.5'),
        activeDirectory: root,
        target: target,
      ),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          allOf(contains('go'), contains('1.26.5'), contains('1.25.0')),
        ),
      ),
    );
  });

  test(
    'builds Android and web from only the activated Flutter toolchain',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'runtime_smoke_flutter_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final commands = <RuntimeSmokeCommand>[];
      final verifier = RuntimeSmokeFlutterVerifier(
        processRunner: (command) async {
          commands.add(command);
          return RuntimeSmokeProcessResult(
            exitCode: 0,
            stdout: command.label == 'flutter-version'
                ? 'Flutter 3.44.6 • channel stable'
                : '',
            stderr: '',
          );
        },
        xcodeDetector: () async => false,
      );

      final result = await verifier.verify(
        component: _flutterComponent(),
        flutterRoot: Directory('${root.path}/flutter'),
        jdkRoot: Directory('${root.path}/jdk'),
        androidSdkRoot: Directory('${root.path}/android-sdk'),
        workspace: Directory('${root.path}/workspace'),
        target: target,
      );

      expect(result.xcodeAvailable, isFalse);
      expect(commands.map((command) => command.label), [
        'flutter-version',
        'flutter-config',
        'flutter-doctor',
        'flutter-create',
        'flutter-pub-get',
        'flutter-build-web',
        'flutter-build-apk',
      ]);
      final environment = commands.first.environment;
      expect(environment['JAVA_HOME'], '${root.path}/jdk');
      expect(environment['ANDROID_HOME'], '${root.path}/android-sdk');
      expect(environment['ANDROID_SDK_ROOT'], '${root.path}/android-sdk');
      expect(environment['PATH'], startsWith('${root.path}/flutter/bin:'));
      expect(
        commands
            .firstWhere((command) => command.label == 'flutter-config')
            .arguments,
        [
          'config',
          '--enable-android',
          '--enable-web',
          '--no-enable-ios',
          '--no-enable-macos-desktop',
        ],
      );
      expect(
        commands
            .firstWhere((command) => command.label == 'flutter-create')
            .arguments,
        contains('--platforms=android,web'),
      );
      expect(
        commands
            .firstWhere((command) => command.label == 'flutter-pub-get')
            .arguments,
        ['pub', 'get', '--enforce-lockfile'],
      );
      expect(
        commands
            .firstWhere((command) => command.label == 'flutter-build-apk')
            .arguments,
        ['build', 'apk', '--debug', '--no-pub'],
      );
    },
  );

  test('adds a real Windows desktop build on Windows', () async {
    final root = Directory.systemTemp.createTempSync(
      'runtime_smoke_flutter_windows_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final commands = <RuntimeSmokeCommand>[];
    final verifier = RuntimeSmokeFlutterVerifier(
      processRunner: (command) async {
        commands.add(command);
        return RuntimeSmokeProcessResult(
          exitCode: 0,
          stdout: command.label == 'flutter-version'
              ? 'Flutter 3.44.6 • channel stable'
              : '',
          stderr: '',
        );
      },
      xcodeDetector: () async =>
          throw StateError('Xcode must not be probed on Windows'),
    );

    await verifier.verify(
      component: _flutterComponent(),
      flutterRoot: Directory('${root.path}/flutter'),
      jdkRoot: Directory('${root.path}/jdk'),
      androidSdkRoot: Directory('${root.path}/android-sdk'),
      workspace: Directory('${root.path}/workspace'),
      target: const RuntimeTarget(
        platform: RuntimePlatform.windows,
        architecture: RuntimeArchitecture.x64,
      ),
    );

    expect(
      commands
          .firstWhere((command) => command.label == 'flutter-config')
          .arguments,
      contains('--enable-windows-desktop'),
    );
    expect(
      commands
          .firstWhere((command) => command.label == 'flutter-create')
          .arguments,
      contains('--platforms=android,web,windows'),
    );
    expect(
      commands.map((command) => command.label),
      contains('flutter-build-windows'),
    );
  });

  test('enables Apple targets only after Xcode is detected', () async {
    final root = Directory.systemTemp.createTempSync(
      'runtime_smoke_flutter_xcode_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final commands = <RuntimeSmokeCommand>[];
    final verifier = RuntimeSmokeFlutterVerifier(
      processRunner: (command) async {
        commands.add(command);
        return RuntimeSmokeProcessResult(
          exitCode: 0,
          stdout: command.label == 'flutter-version'
              ? 'Flutter 3.44.6 • channel stable'
              : '',
          stderr: '',
        );
      },
      xcodeDetector: () async => true,
    );

    final result = await verifier.verify(
      component: _flutterComponent(),
      flutterRoot: Directory('${root.path}/flutter'),
      jdkRoot: Directory('${root.path}/jdk'),
      androidSdkRoot: Directory('${root.path}/android-sdk'),
      workspace: Directory('${root.path}/workspace'),
      target: target,
    );

    expect(result.xcodeAvailable, isTrue);
    expect(
      commands
          .firstWhere((command) => command.label == 'flutter-config')
          .arguments,
      containsAll(['--enable-ios', '--enable-macos-desktop']),
    );
    expect(
      commands
          .firstWhere((command) => command.label == 'flutter-create')
          .arguments,
      contains('--platforms=android,web,ios,macos'),
    );
    expect(
      commands.map((command) => command.label),
      containsAll(['flutter-build-macos', 'flutter-build-ios-simulator']),
    );
    expect(
      commands
          .firstWhere(
            (command) => command.label == 'flutter-build-ios-simulator',
          )
          .arguments,
      ['build', 'ios', '--simulator', '--debug', '--no-codesign', '--no-pub'],
    );
  });

  test('rejects a managed Flutter SDK that reports another version', () async {
    final root = Directory.systemTemp.createTempSync(
      'runtime_smoke_flutter_version_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final verifier = RuntimeSmokeFlutterVerifier(
      processRunner: (command) async => RuntimeSmokeProcessResult(
        exitCode: 0,
        stdout: command.label == 'flutter-version'
            ? 'Flutter 3.43.0 • channel stable'
            : '',
        stderr: '',
      ),
      xcodeDetector: () async => false,
    );

    await expectLater(
      verifier.verify(
        component: _flutterComponent(),
        flutterRoot: Directory('${root.path}/flutter'),
        jdkRoot: Directory('${root.path}/jdk'),
        androidSdkRoot: Directory('${root.path}/android-sdk'),
        workspace: Directory('${root.path}/workspace'),
        target: target,
      ),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          allOf(contains('3.44.6'), contains('3.43.0')),
        ),
      ),
    );
  });

  test(
    'configures MySQL before auto-start and protocol verification',
    () async {
      final events = <String>[];
      var probeAttempts = 0;
      final lifecycle = RuntimeSmokeMySqlLifecycle(
        configure: () async {
          events.add('configure');
          return _mysqlConfigurationResult;
        },
        enableAutoStart: (configuration) async {
          expect(configuration.executable, '/runtime/mysql/bin/mysqld');
          events.add('autostart');
        },
        probe: (port) async {
          events.add('probe:$port');
          probeAttempts++;
          return ServiceProbeResult(
            status: probeAttempts == 1
                ? ServiceProbeStatus.connectionFailed
                : ServiceProbeStatus.identified,
            service: 'MySQL',
            version: probeAttempts == 1 ? null : '8.4.10',
            message: probeAttempts == 1 ? 'not ready' : 'ready',
          );
        },
        managedInstanceProbe: (_) async => true,
        retryDelay: Duration.zero,
        maximumProbeAttempts: 2,
      );

      final result = await lifecycle.run(_mysqlComponent());

      expect(result.version, '8.4.10');
      expect(events, ['configure', 'autostart', 'probe:3306', 'probe:3306']);
    },
  );

  test('requires MySQL clean-machine smoke to validate auto-start', () async {
    final lifecycle = RuntimeSmokeMySqlLifecycle(
      configure: () async => _mysqlConfigurationResult,
      enableAutoStart: (_) async {},
      probe: (_) async => const ServiceProbeResult(
        status: ServiceProbeStatus.identified,
        service: 'MySQL',
        version: '8.4.10',
        message: 'ready',
      ),
      managedInstanceProbe: (_) async => true,
      retryDelay: Duration.zero,
    );

    await expectLater(
      lifecycle.run(_mysqlComponent(startAutomatically: false)),
      throwsA(
        isA<RuntimeSmokeException>().having(
          (error) => error.message,
          'message',
          contains('startAutomatically'),
        ),
      ),
    );
  });

  test('pins clean-machine workflow actions and locked Flutter bootstrap', () {
    final workflow = File(
      '.github/workflows/runtime-smoke.yml',
    ).readAsStringSync();

    expect(
      workflow,
      contains('actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd'),
    );
    expect(
      workflow,
      contains(
        'subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2',
      ),
    );
    expect(
      workflow,
      contains('actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830'),
    );
    expect(workflow, contains('flutter-version: 3.44.6'));
    expect(workflow, contains('flutter pub get --enforce-lockfile'));
    expect(workflow, isNot(contains('uses: actions/checkout@v')));
    expect(workflow, isNot(contains('uses: actions/cache@v')));
  });
}

RuntimeComponent _component(
  String id, {
  List<String> dependencies = const [],
  bool external = false,
  String version = '1.0.0',
}) {
  return RuntimeComponent(
    id: id,
    displayName: id,
    version: version,
    minimumCompatibleVersion: '1.0.0',
    provisioning: external
        ? RuntimeProvisioning.external
        : RuntimeProvisioning.managed,
    artifacts: external
        ? const []
        : [
            RuntimeArtifact(
              platform: RuntimePlatform.macos,
              architecture: RuntimeArchitecture.arm64,
              officialUrl: Uri.parse('https://example.invalid/$id.zip'),
              sha256: 'a' * 64,
              archiveType: RuntimeArchiveType.zip,
            ),
          ],
    executables: [
      RuntimeExecutable(
        platform: RuntimePlatform.macos,
        architectures: const [RuntimeArchitecture.arm64],
        path: 'bin/$id',
      ),
    ],
    dependencies: dependencies,
  );
}

RuntimeComponent _mysqlComponent({bool startAutomatically = true}) {
  return RuntimeComponent(
    id: 'mysql',
    displayName: 'MySQL',
    version: '8.4.10',
    minimumCompatibleVersion: '8.0.0',
    provisioning: RuntimeProvisioning.managed,
    artifacts: const [],
    executables: const [],
    dependencies: const [],
    service: RuntimeServiceMetadata(
      serviceName: 'nishi-mysql',
      defaultPort: 3306,
      startAutomatically: startAutomatically,
      dataDirectory: 'data/mysql',
      healthCheckCommand: const ['bin/mysqladmin', 'ping'],
    ),
  );
}

RuntimeComponent _flutterComponent() => RuntimeComponent(
  id: 'flutter',
  displayName: 'Flutter SDK',
  version: '3.44.6',
  minimumCompatibleVersion: '3.35.0',
  provisioning: RuntimeProvisioning.managed,
  artifacts: const [],
  executables: const [],
  dependencies: const ['jdk', 'android-sdk'],
);

const _mysqlConfigurationResult = MySqlConfigurationResult(
  launchConfiguration: MySqlLaunchConfiguration(
    mysqlRoot: '/runtime/mysql',
    executable: '/runtime/mysql/bin/mysqld',
    dataDirectory: '/runtime/data/mysql',
    logDirectory: '/runtime/logs/mysql',
    configPath: '/runtime/data/mysql/my.cnf',
    pidFilePath: '/runtime/data/mysql/mysql.pid',
    stdoutPath: '/runtime/logs/mysql/stdout.log',
    stderrPath: '/runtime/logs/mysql/stderr.log',
    serverArguments: ['--defaults-file=/runtime/data/mysql/my.cnf'],
  ),
  initialized: true,
  credentialsPath: '/runtime/data/mysql/credentials.json',
  bootstrapSqlPath: '/runtime/data/mysql/.nishi-bootstrap.sql',
);
