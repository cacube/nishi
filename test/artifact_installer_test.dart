import 'dart:io';

import 'package:dev_environment_manager/src/install/artifact_installer.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest_models.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late RuntimeLayout layout;
  late File artifactFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'artifact_installer_test_',
    );
    layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporaryDirectory.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    artifactFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}runtime.zip',
    );
    await artifactFile.writeAsString('fake archive');
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('lists and extracts archives with host tar before activation', () async {
    late Directory staging;
    final runner = _FakeProcessRunner((executable, arguments) async {
      expect(executable, 'tar');
      if (arguments.first == '-tf') {
        return _result(stdout: 'bin/tool\n');
      }
      staging = Directory(arguments.last);
      final executableFile = File(
        '${staging.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}tool',
      );
      await executableFile.parent.create(recursive: true);
      await executableFile.writeAsString('tool');
      return _result();
    });
    final installer = ArtifactInstaller(layout: layout, processRunner: runner);

    final result = await installer.install(
      component: _component(),
      artifact: _artifact(RuntimeArchiveType.zip),
      artifactFile: artifactFile,
    );

    expect(result.status, ArtifactInstallStatus.activated);
    expect(
      File(
        '${result.activeDirectory!.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}tool',
      ).existsSync(),
      isTrue,
    );
    expect(runner.calls, [
      _Call('tar', ['-tf', artifactFile.path]),
      _Call('tar', [
        '-xf',
        artifactFile.path,
        '-C',
        layout.componentStaging('tool', '1.0.0').path,
      ]),
    ]);
  });

  test('rejects archive path traversal before extraction', () async {
    final runner = _FakeProcessRunner((_, arguments) async {
      expect(arguments.first, '-tf');
      return _result(stdout: '../outside/tool\n');
    });
    final installer = ArtifactInstaller(layout: layout, processRunner: runner);

    await expectLater(
      installer.install(
        component: _component(),
        artifact: _artifact(RuntimeArchiveType.tarGz),
        artifactFile: artifactFile,
      ),
      throwsA(isA<ArtifactInstallException>()),
    );

    expect(runner.calls, hasLength(1));
    expect(layout.componentStaging('tool', '1.0.0').existsSync(), isFalse);
  });

  test('activates the selected root inside a vendor archive', () async {
    final runner = _FakeProcessRunner((_, arguments) async {
      if (arguments.first == '-tf') {
        return _result(stdout: 'vendor-root/bin/tool\n');
      }
      final staging = Directory(arguments.last);
      final executableFile = File(
        '${staging.path}${Platform.pathSeparator}vendor-root'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}tool',
      );
      await executableFile.parent.create(recursive: true);
      await executableFile.writeAsString('tool');
      return _result();
    });

    final result =
        await ArtifactInstaller(layout: layout, processRunner: runner).install(
          component: _component(),
          artifact: _artifact(
            RuntimeArchiveType.zip,
            archiveRoot: 'vendor-root',
          ),
          artifactFile: artifactFile,
        );

    expect(
      File(
        '${result.activeDirectory!.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}tool',
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '${result.activeDirectory!.path}${Platform.pathSeparator}vendor-root',
      ).existsSync(),
      isFalse,
    );
  });

  test('places archive contents in a managed install subdirectory', () async {
    final runner = _FakeProcessRunner((_, arguments) async {
      if (arguments.first == '-tf') {
        return _result(stdout: 'cmdline-tools/bin/tool\n');
      }
      final staging = Directory(arguments.last);
      final executableFile = File(
        '${staging.path}${Platform.pathSeparator}cmdline-tools'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}tool',
      );
      await executableFile.parent.create(recursive: true);
      await executableFile.writeAsString('tool');
      return _result();
    });

    final result =
        await ArtifactInstaller(layout: layout, processRunner: runner).install(
          component: _component(
            executablePath: 'cmdline-tools/latest/bin/tool',
          ),
          artifact: _artifact(
            RuntimeArchiveType.zip,
            archiveRoot: 'cmdline-tools',
            installSubdirectory: 'cmdline-tools/latest',
          ),
          artifactFile: artifactFile,
        );

    expect(
      File(
        '${result.activeDirectory!.path}${Platform.pathSeparator}cmdline-tools'
        '${Platform.pathSeparator}latest${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}tool',
      ).existsSync(),
      isTrue,
    );
  });

  test('failed extraction preserves an existing version', () async {
    final existing = layout.componentVersion('tool', '1.0.0');
    await existing.create(recursive: true);
    final marker = File('${existing.path}${Platform.pathSeparator}old-version');
    await marker.writeAsString('keep');
    final runner = _FakeProcessRunner((_, arguments) async {
      if (arguments.first == '-tf') return _result(stdout: 'bin/tool\n');
      return _result(exitCode: 2, stderr: 'broken archive');
    });

    await expectLater(
      ArtifactInstaller(layout: layout, processRunner: runner).install(
        component: _component(),
        artifact: _artifact(RuntimeArchiveType.zip),
        artifactFile: artifactFile,
      ),
      throwsA(isA<ArtifactInstallException>()),
    );

    expect(await marker.readAsString(), 'keep');
    expect(layout.componentStaging('tool', '1.0.0').existsSync(), isFalse);
  });

  test('raw artifact atomically replaces the active version', () async {
    final existing = layout.componentVersion('tool', '1.0.0');
    await existing.create(recursive: true);
    await File(
      '${existing.path}${Platform.pathSeparator}old-version',
    ).writeAsString('old');
    await artifactFile.writeAsString('new executable');

    final result =
        await ArtifactInstaller(
          layout: layout,
          processRunner: _FakeProcessRunner((_, _) async => _result()),
        ).install(
          component: _component(),
          artifact: _artifact(RuntimeArchiveType.raw),
          artifactFile: artifactFile,
        );

    expect(result.status, ArtifactInstallStatus.activated);
    expect(
      await File(
        '${existing.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}tool',
      ).readAsString(),
      'new executable',
    );
    expect(
      File('${existing.path}${Platform.pathSeparator}old-version').existsSync(),
      isFalse,
    );
    expect(Directory('${existing.path}.backup').existsSync(), isFalse);
  });

  test('interactive installers return explicit non-silent commands', () async {
    final installer = ArtifactInstaller(
      layout: layout,
      processRunner: _FakeProcessRunner((_, _) async => _result()),
    );

    final pkg = installer.commandForInteractiveInstaller(
      artifact: _artifact(RuntimeArchiveType.pkg),
      file: artifactFile,
    );
    expect(pkg.executable, 'open');
    expect(pkg.arguments, [artifactFile.absolute.path]);
    expect(pkg.requiresUserConfirmation, isTrue);
    expect(pkg.requiresElevation, isTrue);

    final msi = installer.commandForInteractiveInstaller(
      artifact: _artifact(
        RuntimeArchiveType.msi,
        platform: RuntimePlatform.windows,
      ),
      file: artifactFile,
    );
    expect(msi.executable, 'msiexec.exe');
    expect(msi.arguments, ['/i', artifactFile.absolute.path]);
    expect(msi.arguments, isNot(contains('/quiet')));
    expect(msi.requiresUserConfirmation, isTrue);
    expect(msi.requiresElevation, isTrue);
  });
}

RuntimeComponent _component({String executablePath = 'bin/tool'}) {
  return RuntimeComponent(
    id: 'tool',
    displayName: 'Tool',
    version: '1.0.0',
    minimumCompatibleVersion: '1.0.0',
    provisioning: RuntimeProvisioning.managed,
    artifacts: const [],
    executables: [
      RuntimeExecutable(
        platform: RuntimePlatform.macos,
        architectures: [RuntimeArchitecture.arm64],
        path: executablePath,
      ),
    ],
    dependencies: const [],
  );
}

RuntimeArtifact _artifact(
  RuntimeArchiveType type, {
  RuntimePlatform platform = RuntimePlatform.macos,
  String archiveRoot = '',
  String installSubdirectory = '',
}) {
  return RuntimeArtifact(
    platform: platform,
    architecture: RuntimeArchitecture.arm64,
    officialUrl: Uri.parse('https://example.invalid/runtime'),
    sha256: '0' * 64,
    archiveType: type,
    archiveRoot: archiveRoot,
    installSubdirectory: installSubdirectory,
  );
}

final class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner(this.callback);

  final Future<ProcessResult> Function(String, List<String>) callback;
  final List<_Call> calls = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    calls.add(_Call(executable, List.unmodifiable(arguments)));
    return callback(executable, arguments);
  }
}

final class _Call {
  const _Call(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  @override
  bool operator ==(Object other) {
    return other is _Call &&
        executable == other.executable &&
        _listEquals(arguments, other.arguments);
  }

  @override
  int get hashCode => Object.hash(executable, Object.hashAll(arguments));
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

ProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) {
  return ProcessResult(1, exitCode, stdout, stderr);
}
