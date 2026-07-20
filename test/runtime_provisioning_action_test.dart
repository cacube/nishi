import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:dev_environment_manager/src/install/artifact_installer.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_provisioning_action.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late RuntimeLayout layout;
  late HttpServer server;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'runtime_provisioning_action_test_',
    );
    layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporaryDirectory.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await temporaryDirectory.delete(recursive: true);
  });

  test('downloads, verifies, and activates a raw runtime', () async {
    final bytes = utf8.encode('runtime executable');
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    final artifact = _artifact(
      server,
      RuntimeArchiveType.raw,
      sha256.convert(bytes).toString(),
    );
    final downloads = DownloadManager();
    final progress = <double>[];
    final action = RuntimeProvisioningAction(
      component: _component(),
      artifact: artifact,
      layout: layout,
      downloads: downloads,
      installer: ArtifactInstaller(layout: layout),
    );

    await action.execute((value, _) => progress.add(value));

    final executable = File(
      '${layout.componentVersion('tool', '1.0.0').path}'
      '${Platform.pathSeparator}bin${Platform.pathSeparator}tool',
    );
    expect(await executable.readAsString(), 'runtime executable');
    expect(progress.last, 1);
    downloads.close();
  });

  test('surfaces interactive package installation as user action', () async {
    final bytes = utf8.encode('package');
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    final downloads = DownloadManager();
    final action = RuntimeProvisioningAction(
      component: _component(),
      artifact: _artifact(
        server,
        RuntimeArchiveType.pkg,
        sha256.convert(bytes).toString(),
      ),
      layout: layout,
      downloads: downloads,
      installer: ArtifactInstaller(layout: layout),
    );

    await expectLater(
      action.execute((_, _) {}),
      throwsA(
        isA<SetupUserActionRequiredException>().having(
          (error) => error.request,
          'installer command',
          isA<InstallerCommand>(),
        ),
      ),
    );
    downloads.close();
  });
}

RuntimeComponent _component() {
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
        architectures: const [RuntimeArchitecture.arm64],
        path: 'bin/tool',
      ),
    ],
    dependencies: const [],
  );
}

RuntimeArtifact _artifact(
  HttpServer server,
  RuntimeArchiveType archiveType,
  String digest,
) {
  return RuntimeArtifact(
    platform: RuntimePlatform.macos,
    architecture: RuntimeArchitecture.arm64,
    officialUrl: Uri.parse(
      'http://${server.address.host}:${server.port}/runtime',
    ),
    sha256: digest,
    archiveType: archiveType,
  );
}
