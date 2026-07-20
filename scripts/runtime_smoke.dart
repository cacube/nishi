import 'dart:io';

import 'package:dev_environment_manager/src/activation/activation_boundaries.dart';
import 'package:dev_environment_manager/src/activation/autostart_coordinator.dart';
import 'package:dev_environment_manager/src/activation/autostart_plans.dart';
import 'package:dev_environment_manager/src/android_sdk/android_sdk_configurator.dart';
import 'package:dev_environment_manager/src/compatibility/service_probe.dart';
import 'package:dev_environment_manager/src/compatibility/version_output_parser.dart';
import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:dev_environment_manager/src/install/artifact_installer.dart';
import 'package:dev_environment_manager/src/mysql/mysql_configurator.dart';
import 'package:dev_environment_manager/src/provisioning/provisioning_plan.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';

const _defaultComponents = ['flutter', 'jdk', 'android-sdk'];

enum RuntimeSmokeMode { validate, download, install }

final class RuntimeSmokeArguments {
  const RuntimeSmokeArguments({
    required this.manifest,
    required this.mode,
    required this.target,
    required this.componentIds,
    required this.root,
    required this.acceptAndroidLicenses,
  });

  final File manifest;
  final RuntimeSmokeMode mode;
  final RuntimeTarget target;
  final List<String> componentIds;
  final Directory root;
  final bool acceptAndroidLicenses;

  factory RuntimeSmokeArguments.parse(List<String> arguments) {
    final values = _parseOptions(arguments);
    final manifestPath = values['manifest'];
    if (manifestPath == null || manifestPath.trim().isEmpty) {
      throw const RuntimeSmokeException('--manifest is required');
    }

    final modeText = values['mode'] ?? RuntimeSmokeMode.validate.name;
    final mode = RuntimeSmokeMode.values.where(
      (candidate) => candidate.name == modeText,
    );
    if (mode.isEmpty) {
      throw RuntimeSmokeException(
        'Unsupported --mode "$modeText"; expected validate, download, or install',
      );
    }

    final targetText = values['target'];
    final target = targetText == null
        ? RuntimeTarget.current()
        : _parseTarget(targetText);
    final componentIds = (values['components'] ?? _defaultComponents.join(','))
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (componentIds.isEmpty) {
      throw const RuntimeSmokeException('--components cannot be empty');
    }

    return RuntimeSmokeArguments(
      manifest: File(manifestPath),
      mode: mode.single,
      target: target,
      componentIds: componentIds,
      root: Directory(values['root'] ?? '.runtime-smoke'),
      acceptAndroidLicenses: _parseBoolean(
        values['accept-android-licenses'] ?? 'false',
        option: 'accept-android-licenses',
      ),
    );
  }
}

final class RuntimeSmokePlan {
  RuntimeSmokePlan._({required this.entries, required this.limitations});

  final List<ProvisioningPlanEntry> entries;
  final List<String> limitations;

  List<String> remainingLimitations({required bool configureAndroidSdk}) {
    if (!configureAndroidSdk) return limitations;
    return limitations
        .where((limitation) => limitation != _androidSdkConfigurationLimitation)
        .toList(growable: false);
  }

  factory RuntimeSmokePlan.fromManifest({
    required RuntimeManifest manifest,
    required RuntimeTarget target,
    required List<String> requestedComponentIds,
  }) {
    final requested = requestedComponentIds.toSet();
    for (final id in requested) {
      final component = manifest.componentById(id);
      if (component == null) {
        throw RuntimeSmokeException(
          'Requested smoke component "$id" is absent from the manifest',
        );
      }
      if (!component.isManaged) {
        throw RuntimeSmokeException(
          'Requested smoke component "$id" must be managed',
        );
      }
    }

    final selected = <String>{};
    void includeWithDependencies(String id) {
      if (!selected.add(id)) return;
      final component = manifest.componentById(id)!;
      if (!component.isManaged) {
        throw RuntimeSmokeException(
          'Dependency "$id" in the smoke component closure must be managed',
        );
      }
      for (final dependency in component.dependencies) {
        includeWithDependencies(dependency);
      }
    }

    for (final id in requested) {
      includeWithDependencies(id);
    }

    final fullPlan = ProvisioningPlan.fromManifest(manifest, target);
    final entries = fullPlan.entries
        .where((entry) => selected.contains(entry.component.id))
        .toList(growable: false);
    final limitations = <String>[];
    if (selected.contains('android-sdk')) {
      limitations.add(_androidSdkConfigurationLimitation);
    }
    return RuntimeSmokePlan._(
      entries: List.unmodifiable(entries),
      limitations: List.unmodifiable(limitations),
    );
  }
}

final class RuntimeSmokeException implements Exception {
  const RuntimeSmokeException(this.message);

  final String message;

  @override
  String toString() => 'RuntimeSmokeException: $message';
}

final class RuntimeSmokeCommand {
  const RuntimeSmokeCommand({
    required this.label,
    required this.executable,
    required this.arguments,
    required this.component,
    this.expectedVersion,
    this.runInShell = false,
    this.environment = const {},
    this.workingDirectory,
  });

  final String label;
  final String executable;
  final List<String> arguments;
  final SoftwareComponent component;
  final String? expectedVersion;
  final bool runInShell;
  final Map<String, String> environment;
  final String? workingDirectory;
}

final class RuntimeSmokeProcessResult {
  const RuntimeSmokeProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef RuntimeSmokeProcessRunner =
    Future<RuntimeSmokeProcessResult> Function(RuntimeSmokeCommand command);

final class RuntimeSmokeCommandVerification {
  const RuntimeSmokeCommandVerification({
    required this.label,
    required this.version,
  });

  final String label;
  final String version;
}

final class RuntimeSmokeComponentVerifier {
  RuntimeSmokeComponentVerifier({RuntimeSmokeProcessRunner? processRunner})
    : _processRunner = processRunner ?? _runProcess;

  final RuntimeSmokeProcessRunner _processRunner;

  Future<List<RuntimeSmokeCommandVerification>> verify({
    required RuntimeComponent component,
    required Directory activeDirectory,
    required RuntimeTarget target,
  }) async {
    final commands = _commandsFor(component, activeDirectory, target);
    final verified = <RuntimeSmokeCommandVerification>[];
    for (final command in commands) {
      final result = await _processRunner(command);
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode != 0) {
        throw RuntimeSmokeException(
          '${command.label} verification failed with exit code '
          '${result.exitCode}: $output',
        );
      }
      final version = const VersionOutputParser().extract(
        command.component,
        output,
      );
      if (version == null) {
        throw RuntimeSmokeException(
          '${command.label} did not report a recognizable version: $output',
        );
      }
      final actual = version.toString();
      final expected = command.expectedVersion;
      if (expected != null && actual != expected) {
        throw RuntimeSmokeException(
          '${command.label} expected version $expected but activated runtime '
          'reported $actual',
        );
      }
      verified.add(
        RuntimeSmokeCommandVerification(label: command.label, version: actual),
      );
    }
    return List.unmodifiable(verified);
  }

  List<RuntimeSmokeCommand> _commandsFor(
    RuntimeComponent component,
    Directory activeDirectory,
    RuntimeTarget target,
  ) {
    if (!const {'go', 'node', 'mysql'}.contains(component.id)) return const [];
    final executable = component.executables.where(
      (candidate) =>
          candidate.platform == target.platform &&
          candidate.architectures.contains(target.architecture),
    );
    if (executable.isEmpty) {
      throw RuntimeSmokeException(
        '${component.id} has no executable for $target',
      );
    }
    final primaryPath = _targetJoin(
      activeDirectory.path,
      executable.single.path,
      target.platform,
    );
    return switch (component.id) {
      'go' => [
        RuntimeSmokeCommand(
          label: 'go',
          executable: primaryPath,
          arguments: const ['version'],
          component: SoftwareComponent.go,
          expectedVersion: component.version,
          runInShell: target.platform == RuntimePlatform.windows,
        ),
      ],
      'node' => [
        RuntimeSmokeCommand(
          label: 'node',
          executable: primaryPath,
          arguments: const ['--version'],
          component: SoftwareComponent.node,
          expectedVersion: component.version,
          runInShell: target.platform == RuntimePlatform.windows,
        ),
        RuntimeSmokeCommand(
          label: 'npm',
          executable: _targetJoin(
            activeDirectory.path,
            target.platform == RuntimePlatform.windows ? 'npm.cmd' : 'bin/npm',
            target.platform,
          ),
          arguments: const ['--version'],
          component: SoftwareComponent.npm,
          runInShell: target.platform == RuntimePlatform.windows,
          environment: {
            'PATH': _prependPath(
              target.platform == RuntimePlatform.windows
                  ? activeDirectory.path
                  : _targetJoin(activeDirectory.path, 'bin', target.platform),
              target.platform,
            ),
          },
        ),
      ],
      'mysql' => [
        RuntimeSmokeCommand(
          label: 'mysql',
          executable: primaryPath,
          arguments: const ['--version'],
          component: SoftwareComponent.mysql,
          expectedVersion: component.version,
          runInShell: target.platform == RuntimePlatform.windows,
        ),
      ],
      _ => const [],
    };
  }

  static Future<RuntimeSmokeProcessResult> _runProcess(
    RuntimeSmokeCommand command,
  ) async {
    final result = await Process.run(
      command.executable,
      command.arguments,
      runInShell: command.runInShell,
      environment: command.environment.isEmpty ? null : command.environment,
      workingDirectory: command.workingDirectory,
    );
    return RuntimeSmokeProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}

typedef RuntimeSmokeXcodeDetector = Future<bool> Function();

final class RuntimeSmokeFlutterVerification {
  const RuntimeSmokeFlutterVerification({
    required this.xcodeAvailable,
    required this.completedCommands,
  });

  final bool xcodeAvailable;
  final List<String> completedCommands;
}

final class RuntimeSmokeFlutterVerifier {
  RuntimeSmokeFlutterVerifier({
    RuntimeSmokeProcessRunner? processRunner,
    RuntimeSmokeXcodeDetector? xcodeDetector,
  }) : _processRunner =
           processRunner ?? RuntimeSmokeComponentVerifier._runProcess,
       _xcodeDetector = xcodeDetector ?? _detectXcode;

  final RuntimeSmokeProcessRunner _processRunner;
  final RuntimeSmokeXcodeDetector _xcodeDetector;

  Future<RuntimeSmokeFlutterVerification> verify({
    required RuntimeComponent component,
    required Directory flutterRoot,
    required Directory jdkRoot,
    required Directory androidSdkRoot,
    required Directory workspace,
    required RuntimeTarget target,
  }) async {
    if (component.id != 'flutter') {
      throw RuntimeSmokeException(
        'Flutter verification cannot run for component ${component.id}',
      );
    }
    final xcodeAvailable =
        target.platform == RuntimePlatform.macos && await _xcodeDetector();
    if (await workspace.exists()) await workspace.delete(recursive: true);
    await workspace.create(recursive: true);

    final project = Directory(
      _targetJoin(workspace.path, 'nishi_runtime_smoke', target.platform),
    );
    final commands = _commandsFor(
      flutterRoot: flutterRoot,
      jdkRoot: jdkRoot,
      androidSdkRoot: androidSdkRoot,
      workspace: workspace,
      project: project,
      target: target,
      xcodeAvailable: xcodeAvailable,
    );
    final completed = <String>[];
    for (final command in commands) {
      stdout.writeln('FLUTTER_SMOKE_START ${command.label}');
      final result = await _processRunner(command);
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode != 0) {
        throw RuntimeSmokeException(
          '${command.label} failed with exit code ${result.exitCode}: $output',
        );
      }
      if (command.label == 'flutter-version') {
        final version = const VersionOutputParser().extract(
          SoftwareComponent.flutter,
          output,
        );
        if (version == null) {
          throw RuntimeSmokeException(
            'Managed Flutter did not report a recognizable version: $output',
          );
        }
        final actual = version.toString();
        if (actual != component.version) {
          throw RuntimeSmokeException(
            'Managed Flutter expected version ${component.version} but '
            'reported $actual',
          );
        }
      }
      completed.add(command.label);
      stdout.writeln('FLUTTER_SMOKE_DONE ${command.label}');
    }
    return RuntimeSmokeFlutterVerification(
      xcodeAvailable: xcodeAvailable,
      completedCommands: List.unmodifiable(completed),
    );
  }

  List<RuntimeSmokeCommand> _commandsFor({
    required Directory flutterRoot,
    required Directory jdkRoot,
    required Directory androidSdkRoot,
    required Directory workspace,
    required Directory project,
    required RuntimeTarget target,
    required bool xcodeAvailable,
  }) {
    final isWindows = target.platform == RuntimePlatform.windows;
    final flutter = _targetJoin(
      flutterRoot.path,
      isWindows ? r'bin\flutter.bat' : 'bin/flutter',
      target.platform,
    );
    final pathSeparator = isWindows ? ';' : ':';
    final runtimePaths = [
      _targetJoin(flutterRoot.path, 'bin', target.platform),
      _targetJoin(jdkRoot.path, 'bin', target.platform),
      _targetJoin(androidSdkRoot.path, 'platform-tools', target.platform),
      _targetJoin(
        androidSdkRoot.path,
        'cmdline-tools/latest/bin',
        target.platform,
      ),
    ];
    final inheritedPath = Platform.environment['PATH'];
    if (inheritedPath != null && inheritedPath.isNotEmpty) {
      runtimePaths.add(inheritedPath);
    }
    final environment = <String, String>{
      'JAVA_HOME': jdkRoot.path,
      'ANDROID_HOME': androidSdkRoot.path,
      'ANDROID_SDK_ROOT': androidSdkRoot.path,
      'PATH': runtimePaths.join(pathSeparator),
      'CI': 'true',
    };
    final configArguments = <String>[
      'config',
      '--enable-android',
      '--enable-web',
      if (isWindows) '--enable-windows-desktop',
      if (xcodeAvailable) '--enable-ios',
      if (xcodeAvailable) '--enable-macos-desktop',
      if (!isWindows && !xcodeAvailable) '--no-enable-ios',
      if (!isWindows && !xcodeAvailable) '--no-enable-macos-desktop',
    ];
    final platforms = <String>[
      'android',
      'web',
      if (isWindows) 'windows',
      if (xcodeAvailable) 'ios',
      if (xcodeAvailable) 'macos',
    ];

    RuntimeSmokeCommand command(
      String label,
      List<String> arguments, {
      String? workingDirectory,
    }) => RuntimeSmokeCommand(
      label: label,
      executable: flutter,
      arguments: arguments,
      component: SoftwareComponent.flutter,
      runInShell: isWindows,
      environment: environment,
      workingDirectory: workingDirectory,
    );

    return [
      command('flutter-version', const ['--version']),
      command('flutter-config', configArguments),
      command('flutter-doctor', const ['doctor', '-v']),
      command('flutter-create', [
        'create',
        '--empty',
        '--project-name=nishi_runtime_smoke',
        '--platforms=${platforms.join(',')}',
        project.path,
      ], workingDirectory: workspace.path),
      command('flutter-pub-get', const [
        'pub',
        'get',
        '--enforce-lockfile',
      ], workingDirectory: project.path),
      command('flutter-build-web', const [
        'build',
        'web',
        '--debug',
        '--no-pub',
      ], workingDirectory: project.path),
      command('flutter-build-apk', const [
        'build',
        'apk',
        '--debug',
        '--no-pub',
      ], workingDirectory: project.path),
      if (isWindows)
        command('flutter-build-windows', const [
          'build',
          'windows',
          '--debug',
          '--no-pub',
        ], workingDirectory: project.path),
      if (xcodeAvailable)
        command('flutter-build-macos', const [
          'build',
          'macos',
          '--debug',
          '--no-pub',
        ], workingDirectory: project.path),
      if (xcodeAvailable)
        command('flutter-build-ios-simulator', const [
          'build',
          'ios',
          '--simulator',
          '--debug',
          '--no-codesign',
          '--no-pub',
        ], workingDirectory: project.path),
    ];
  }

  static Future<bool> _detectXcode() async {
    try {
      final result = await Process.run('xcodebuild', const ['-version']);
      if (result.exitCode != 0) return false;
      return const VersionOutputParser().extract(
            SoftwareComponent.xcode,
            '${result.stdout}\n${result.stderr}',
          ) !=
          null;
    } on ProcessException {
      return false;
    }
  }
}

typedef RuntimeSmokeMySqlConfigure =
    Future<MySqlConfigurationResult> Function();
typedef RuntimeSmokeMySqlAutoStart =
    Future<void> Function(MySqlLaunchConfiguration configuration);
typedef RuntimeSmokeMySqlProbe = Future<ServiceProbeResult> Function(int port);

final class RuntimeSmokeMySqlLifecycle {
  const RuntimeSmokeMySqlLifecycle({
    required RuntimeSmokeMySqlConfigure configure,
    required RuntimeSmokeMySqlAutoStart enableAutoStart,
    required RuntimeSmokeMySqlProbe probe,
    this.retryDelay = const Duration(seconds: 2),
    this.maximumProbeAttempts = 30,
  }) : _configure = configure,
       _enableAutoStart = enableAutoStart,
       _probe = probe;

  final RuntimeSmokeMySqlConfigure _configure;
  final RuntimeSmokeMySqlAutoStart _enableAutoStart;
  final RuntimeSmokeMySqlProbe _probe;
  final Duration retryDelay;
  final int maximumProbeAttempts;

  Future<ServiceProbeResult> run(RuntimeComponent component) async {
    final service = component.service;
    if (service == null) {
      throw const RuntimeSmokeException(
        'MySQL smoke requires service metadata',
      );
    }
    if (!service.startAutomatically) {
      throw const RuntimeSmokeException(
        'MySQL smoke requires service.startAutomatically=true',
      );
    }
    if (maximumProbeAttempts < 1) {
      throw const RuntimeSmokeException(
        'MySQL smoke requires at least one protocol probe attempt',
      );
    }

    final configuration = await _configure();
    await _enableAutoStart(configuration.launchConfiguration);
    ServiceProbeResult? lastResult;
    for (var attempt = 1; attempt <= maximumProbeAttempts; attempt++) {
      lastResult = await _probe(service.defaultPort);
      if (lastResult.identified) {
        final version = lastResult.version;
        if (version == null || !version.startsWith(component.version)) {
          throw RuntimeSmokeException(
            'MySQL protocol expected version ${component.version} but '
            'reported ${version ?? 'none'}',
          );
        }
        return lastResult;
      }
      if (attempt < maximumProbeAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw RuntimeSmokeException(
      'MySQL did not become ready on 127.0.0.1:${service.defaultPort}: '
      '${lastResult?.message ?? 'no probe result'}',
    );
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final options = RuntimeSmokeArguments.parse(arguments);
    await runRuntimeSmoke(options);
  } on Object catch (error, stackTrace) {
    stderr.writeln(error);
    if (error is! RuntimeSmokeException) stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<void> runRuntimeSmoke(RuntimeSmokeArguments options) async {
  if (!await options.manifest.exists()) {
    throw RuntimeSmokeException(
      'Manifest does not exist: ${options.manifest.path}',
    );
  }

  final manifest = await const RuntimeManifestLoader().loadFile(
    options.manifest,
  );
  final plan = RuntimeSmokePlan.fromManifest(
    manifest: manifest,
    target: options.target,
    requestedComponentIds: options.componentIds,
  );
  final componentSummary = plan.entries
      .map((entry) => '${entry.component.id}@${entry.component.version}')
      .join(', ');
  stdout.writeln(
    'VALIDATED target=${options.target} components=[$componentSummary]',
  );
  final configureAndroidSdk =
      options.mode == RuntimeSmokeMode.install && options.acceptAndroidLicenses;
  final limitations = plan.remainingLimitations(
    configureAndroidSdk: configureAndroidSdk,
  );
  for (final limitation in limitations) {
    stdout.writeln('LIMITATION: $limitation');
    stdout.writeln('::warning title=Android SDK provisioning gap::$limitation');
  }
  await _writeStepSummary(options, plan, limitations);
  if (options.mode == RuntimeSmokeMode.validate) return;

  final layout = _smokeLayout(options.root, options.target.platform);
  await layout.ensureCreated();
  final downloads = DownloadManager(timeout: const Duration(minutes: 30));
  try {
    final installer = ArtifactInstaller(layout: layout);
    final verifier = RuntimeSmokeComponentVerifier();
    final activeDirectories = <String, Directory>{};
    for (final entry in plan.entries) {
      final artifact = entry.artifact;
      if (artifact == null) {
        throw RuntimeSmokeException(
          '${entry.component.id} unexpectedly has no managed artifact',
        );
      }
      var reportedTenths = -1;
      final result = await downloads.downloadFromSources(
        sources: artifact.downloadUrls,
        destinationDirectory: layout.cache,
        fileName: _cacheFileName(entry.component, artifact),
        expectedSha256: artifact.sha256,
        onProgress: (progress) {
          final fraction = progress.fraction;
          if (fraction == null) return;
          final tenths = (fraction * 10).floor().clamp(0, 10);
          if (tenths == reportedTenths) return;
          reportedTenths = tenths;
          stdout.writeln('DOWNLOAD ${entry.component.id} ${tenths * 10}%');
        },
        onSourceChanged: (source, sourceIndex) {
          if (sourceIndex > 0) {
            stdout.writeln(
              'DOWNLOAD_FALLBACK ${entry.component.id} source=$source',
            );
          }
        },
      );
      stdout.writeln(
        'DOWNLOADED ${entry.component.id} sha256=${artifact.sha256} '
        'cache=${result.fromCache}',
      );
      if (options.mode != RuntimeSmokeMode.install) continue;

      final installResult = await installer.install(
        component: entry.component,
        artifact: artifact,
        artifactFile: result.file,
      );
      if (installResult.status == ArtifactInstallStatus.userActionRequired) {
        throw RuntimeSmokeException(
          '${entry.component.id} requires an interactive installer and cannot '
          'be clean-machine smoke tested unattended',
        );
      }
      stdout.writeln(
        'ARTIFACT_ACTIVATED ${entry.component.id} '
        'path=${installResult.activeDirectory!.path}',
      );
      activeDirectories[entry.component.id] = installResult.activeDirectory!;

      final verifications = await verifier.verify(
        component: entry.component,
        activeDirectory: installResult.activeDirectory!,
        target: options.target,
      );
      for (final verification in verifications) {
        stdout.writeln(
          'COMMAND_VERIFIED ${verification.label} '
          'version=${verification.version}',
        );
      }

      if (entry.component.id == 'android-sdk' && configureAndroidSdk) {
        final metadata = entry.component.androidSdk;
        final jdkRoot = activeDirectories['jdk'];
        if (metadata == null || jdkRoot == null) {
          throw const RuntimeSmokeException(
            'Android SDK configuration requires manifest androidSdk metadata '
            'and an activated jdk dependency',
          );
        }
        await AndroidSdkConfigurator(
          sdkRoot: installResult.activeDirectory!.path,
          jdkRoot: jdkRoot.path,
          packages: metadata.packages,
          repositoryMirrorUrls: metadata.repositoryMirrorUrls,
        ).configure(
          licensesAccepted: true,
          onProgress: (progress) {
            stdout.writeln(
              'ANDROID_SDK ${progress.stage.name} '
              '${(progress.fraction * 100).round()}% ${progress.message}',
            );
          },
        );
        stdout.writeln(
          'ANDROID_SDK_CONFIGURED packages=${metadata.packages.join(',')}',
        );
      }
      if (entry.component.id == 'flutter' && configureAndroidSdk) {
        final jdkRoot = activeDirectories['jdk'];
        final androidSdkRoot = activeDirectories['android-sdk'];
        if (jdkRoot == null || androidSdkRoot == null) {
          throw const RuntimeSmokeException(
            'Flutter install smoke requires activated JDK and Android SDK '
            'dependencies',
          );
        }
        final verification = await RuntimeSmokeFlutterVerifier().verify(
          component: entry.component,
          flutterRoot: installResult.activeDirectory!,
          jdkRoot: jdkRoot,
          androidSdkRoot: androidSdkRoot,
          workspace: Directory(
            '${layout.data.path}${Platform.pathSeparator}flutter-smoke',
          ),
          target: options.target,
        );
        stdout.writeln(
          'FLUTTER_READY version=${entry.component.version} '
          'android=true web=true '
          'windows=${options.target.platform == RuntimePlatform.windows} '
          'apple=${verification.xcodeAvailable}',
        );
        if (options.target.platform == RuntimePlatform.macos &&
            !verification.xcodeAvailable) {
          stdout.writeln(
            'APPLE_TARGETS_SKIPPED: xcodebuild was not available; iOS and '
            'macOS remain disabled.',
          );
        }
      }
      if (entry.component.id == 'mysql') {
        final configurator = MySqlConfigurator(
          mysqlRoot: installResult.activeDirectory!.path,
          dataDirectory: Directory(
            '${layout.data.path}${Platform.pathSeparator}mysql',
          ),
          logDirectory: Directory(
            '${layout.logs.path}${Platform.pathSeparator}mysql',
          ),
          isWindows: options.target.platform == RuntimePlatform.windows,
        );
        final protocol = await RuntimeSmokeMySqlLifecycle(
          configure: configurator.configure,
          enableAutoStart: (configuration) =>
              _enableMySqlAutoStart(configuration, target: options.target),
          probe: (port) => TcpServiceProbe().probe(
            const MySqlHandshakeProtocol(),
            port: port,
            timeout: const Duration(seconds: 2),
          ),
        ).run(entry.component);
        stdout.writeln(
          'MYSQL_READY version=${protocol.version} '
          'port=${entry.component.service!.defaultPort}',
        );
      }
    }
  } finally {
    downloads.close(force: true);
  }

  if (options.mode == RuntimeSmokeMode.install && limitations.isNotEmpty) {
    stdout.writeln(
      'INSTALL_SMOKE_PARTIAL: managed archives activated, but the limitations '
      'above still prevent claiming a ready Android development environment.',
    );
  }
}

Future<void> _enableMySqlAutoStart(
  MySqlLaunchConfiguration configuration, {
  required RuntimeTarget target,
}) async {
  const files = IoActivationFileStore();
  const processes = IoActivationProcessRunner();
  final coordinator = AutoStartCoordinator(files: files, processes: processes);
  if (target.platform == RuntimePlatform.macos) {
    final uid = await Process.run('/usr/bin/id', const ['-u']);
    final userId = int.tryParse(uid.stdout.toString().trim());
    if (uid.exitCode != 0 || userId == null) {
      throw const RuntimeSmokeException(
        'Could not determine the macOS user ID for MySQL auto-start',
      );
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const RuntimeSmokeException(
        'Could not determine HOME for MySQL auto-start',
      );
    }
    final plistPath =
        '$home/Library/LaunchAgents/com.devenvironmentmanager.mysql.plist';
    final plan = MacOsLaunchAgentPlan.build(
      userId: userId,
      label: 'com.devenvironmentmanager.mysql',
      plistPath: plistPath,
      executable: configuration.executable,
      arguments: configuration.serverArguments,
      stdoutPath: configuration.stdoutPath,
      stderrPath: configuration.stderrPath,
    );
    if (await File(plistPath).exists()) {
      await coordinator.update(plan);
    } else {
      await coordinator.enable(plan);
    }
    return;
  }

  const taskName = r'DevEnvironmentManager\MySQL';
  final plan = WindowsAutoStartPlan.userTask(
    id: 'mysql',
    taskName: taskName,
    executable: configuration.executable,
    arguments: configuration.serverArguments,
  );
  await coordinator.enable(plan);
  final start = await processes.run(
    const ActivationCommand(
      executable: 'schtasks.exe',
      arguments: ['/Run', '/TN', taskName],
    ),
  );
  if (start.exitCode != 0) {
    throw RuntimeSmokeException(
      'Could not start the Windows MySQL user task: ${start.stderr}',
    );
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) {
      throw RuntimeSmokeException('Unexpected argument: $argument');
    }
    final separator = argument.indexOf('=');
    if (separator >= 0) {
      values[argument.substring(2, separator)] = argument.substring(
        separator + 1,
      );
      continue;
    }
    final key = argument.substring(2);
    if (index + 1 >= arguments.length ||
        arguments[index + 1].startsWith('--')) {
      throw RuntimeSmokeException('Missing value for --$key');
    }
    values[key] = arguments[++index];
  }
  const supported = {
    'manifest',
    'mode',
    'target',
    'components',
    'root',
    'accept-android-licenses',
  };
  final unknown = values.keys.where((key) => !supported.contains(key));
  if (unknown.isNotEmpty) {
    throw RuntimeSmokeException('Unknown option --${unknown.first}');
  }
  return values;
}

bool _parseBoolean(String value, {required String option}) {
  return switch (value) {
    'true' => true,
    'false' => false,
    _ => throw RuntimeSmokeException('--$option must be true or false'),
  };
}

RuntimeTarget _parseTarget(String value) {
  final parts = value.split('/');
  if (parts.length != 2) {
    throw RuntimeSmokeException(
      'Invalid --target "$value"; expected windows/x64, windows/arm64, '
      'macos/x64, or macos/arm64',
    );
  }
  final platforms = RuntimePlatform.values.where(
    (candidate) => candidate.jsonValue == parts[0],
  );
  final architectures = RuntimeArchitecture.values.where(
    (candidate) => candidate.jsonValue == parts[1],
  );
  if (platforms.isEmpty || architectures.isEmpty) {
    throw RuntimeSmokeException('Invalid --target "$value"');
  }
  return RuntimeTarget(
    platform: platforms.single,
    architecture: architectures.single,
  );
}

RuntimeLayout _smokeLayout(Directory root, RuntimePlatform platform) {
  return switch (platform) {
    RuntimePlatform.windows => RuntimeLayout.forCurrentUser(
      environment: {'LOCALAPPDATA': root.absolute.path},
      operatingSystem: HostOperatingSystem.windows,
    ),
    RuntimePlatform.macos => RuntimeLayout.forCurrentUser(
      environment: {'HOME': root.absolute.path},
      operatingSystem: HostOperatingSystem.macos,
    ),
  };
}

String _cacheFileName(RuntimeComponent component, RuntimeArtifact artifact) {
  final sourceName = artifact.officialUrl.pathSegments
      .where((segment) => segment.isNotEmpty)
      .lastOrNull;
  final suffix = sourceName == null ? 'artifact' : _safeName(sourceName);
  return _safeName(
    '${component.id}-${component.version}-'
    '${artifact.platform.jsonValue}-${artifact.architecture.jsonValue}-$suffix',
  );
}

String _safeName(String value) {
  final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (safe.isEmpty || safe == '.' || safe == '..') return 'artifact';
  return safe;
}

String _targetJoin(String parent, String child, RuntimePlatform platform) {
  final separator = platform == RuntimePlatform.windows ? r'\' : '/';
  final normalizedChild = child.replaceAll(RegExp(r'[/\\]+'), separator);
  if (parent.endsWith('/') || parent.endsWith(r'\')) {
    return '$parent$normalizedChild';
  }
  return '$parent$separator$normalizedChild';
}

String _prependPath(String directory, RuntimePlatform platform) {
  final separator = platform == RuntimePlatform.windows ? ';' : ':';
  final inherited = Platform.environment['PATH'] ?? '';
  return inherited.isEmpty ? directory : '$directory$separator$inherited';
}

Future<void> _writeStepSummary(
  RuntimeSmokeArguments options,
  RuntimeSmokePlan plan,
  List<String> limitations,
) async {
  final summaryPath = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summaryPath == null || summaryPath.isEmpty) return;
  final lines = <String>[
    '## Runtime smoke',
    '',
    '- Mode: `${options.mode.name}`',
    '- Target: `${options.target}`',
    '- Components: `${plan.entries.map((entry) => entry.component.id).join(', ')}`',
    '- Android licenses accepted: `${options.acceptAndroidLicenses}`',
  ];
  if (limitations.isNotEmpty) {
    lines.addAll(['', '### Known limitations', '']);
    for (final limitation in limitations) {
      lines.add('- $limitation');
    }
  }
  await File(
    summaryPath,
  ).writeAsString('${lines.join('\n')}\n', mode: FileMode.append);
}

const _androidSdkConfigurationLimitation =
    'Android SDK install smoke only activates the command-line tools archive. '
    'It does not run sdkmanager for platform-tools/platforms/build-tools or '
    'accept Android licenses. This is not yet a ready Android SDK.';
