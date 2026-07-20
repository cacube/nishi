import 'dart:io';

import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:dev_environment_manager/src/install/artifact_installer.dart';
import 'package:dev_environment_manager/src/provisioning/provisioning_workflow.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'builds managed actions and external detection tasks from manifest',
    () async {
      final directory = await Directory.systemTemp.createTemp('workflow_test_');
      addTearDown(() => directory.delete(recursive: true));
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': directory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      final downloads = DownloadManager();
      addTearDown(() => downloads.close(force: true));
      final workflow = ProvisioningWorkflow(
        layout: layout,
        downloads: downloads,
        installer: ArtifactInstaller(layout: layout),
        target: const RuntimeTarget(
          platform: RuntimePlatform.macos,
          architecture: RuntimeArchitecture.arm64,
        ),
      );

      final orchestrator = await workflow.prepare(() async {
        return RuntimeManifest(
          schemaVersion: 1,
          components: [
            _component('git'),
            _component('xcode', external: true, dependencies: ['git']),
          ],
        );
      });

      expect(orchestrator.tasks.map((task) => task.definition.id), [
        'git',
        'xcode',
      ]);
      expect(orchestrator.tasks.last.definition.externallyManaged, isTrue);
      expect(orchestrator.tasks.first.status, SetupTaskStatus.pending);
    },
  );
}

RuntimeComponent _component(
  String id, {
  bool external = false,
  List<String> dependencies = const [],
}) {
  return RuntimeComponent(
    id: id,
    displayName: id,
    version: '1.0.0',
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
              officialUrl: Uri.parse('https://example.invalid/$id'),
              sha256: 'a' * 64,
              archiveType: RuntimeArchiveType.raw,
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
