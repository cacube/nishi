import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:dev_environment_manager/src/operation/runtime_operation_coordinator.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/update/update.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const target = RuntimeTarget(
    platform: RuntimePlatform.macos,
    architecture: RuntimeArchitecture.arm64,
  );

  test(
    'compares active managed versions with the signed target manifest',
    () async {
      final controller = UpdateController(
        manifestSource: () async => RuntimeManifest(
          schemaVersion: 1,
          components: [
            _component('flutter', '3.44.6'),
            _component('go', '1.26.5'),
            _component('node', '24.18.0'),
            _component('git', '2.50.0', external: true),
          ],
        ),
        readActiveVersions: () async => {'flutter': '3.41.0', 'go': '1.26.5'},
        target: target,
        clock: () => DateTime.utc(2026, 7, 21, 8, 30),
      );

      await controller.check();

      expect(controller.state.errorMessage, isNull);
      expect(controller.state.lastCheckedAt, DateTime.utc(2026, 7, 21, 8, 30));
      expect(controller.state.entries.map((entry) => entry.componentId), [
        'flutter',
        'go',
        'node',
      ]);
      expect(
        controller.state.entryById('flutter')!.status,
        RuntimeUpdateStatus.updateAvailable,
      );
      expect(
        controller.state.entryById('go')!.status,
        RuntimeUpdateStatus.current,
      );
      expect(
        controller.state.entryById('node')!.status,
        RuntimeUpdateStatus.notInstalled,
      );
      expect(controller.state.availableUpdates, hasLength(2));
    },
  );

  test('uses detected host versions when lc has no managed receipt', () async {
    final controller = UpdateController(
      manifestSource: () async => RuntimeManifest(
        schemaVersion: 1,
        components: [
          _component('flutter', '3.44.6'),
          _component('mysql', '8.4.10'),
        ],
      ),
      readActiveVersions: () async => const {},
      readDetectedVersions: () async => {'flutter': '3.41.4', 'mysql': '9.3.0'},
      target: target,
    );

    await controller.check();

    final flutter = controller.state.entryById('flutter')!;
    expect(flutter.currentVersion, '3.41.4');
    expect(flutter.status, RuntimeUpdateStatus.updateAvailable);
    final mysql = controller.state.entryById('mysql')!;
    expect(mysql.currentVersion, '9.3.0');
    expect(mysql.status, RuntimeUpdateStatus.newerThanTarget);
  });

  test('does not offer a signed target as an implicit downgrade', () async {
    final controller = UpdateController(
      manifestSource: () async => RuntimeManifest(
        schemaVersion: 1,
        components: [_component('flutter', '3.44.6')],
      ),
      readActiveVersions: () async => {'flutter': '3.45.0'},
      target: target,
    );

    await controller.check();

    expect(
      controller.state.entryById('flutter')!.status,
      RuntimeUpdateStatus.newerThanTarget,
    );
    expect(controller.state.availableUpdates, isEmpty);
  });

  test('treats a stale active-version receipt as not installed', () async {
    final controller = UpdateController(
      manifestSource: () async => RuntimeManifest(
        schemaVersion: 1,
        components: [_component('flutter', '3.44.6')],
      ),
      readActiveVersions: () async => {'flutter': '3.44.6'},
      validateActiveVersion: (_, _) async => false,
      target: target,
    );

    await controller.check();

    expect(
      controller.state.entryById('flutter')!.status,
      RuntimeUpdateStatus.notInstalled,
    );
  });

  test(
    'downloads available signed artifacts without installing them',
    () async {
      final downloader = _RecordingUpdateDownloader();
      final controller = UpdateController(
        manifestSource: () async => RuntimeManifest(
          schemaVersion: 1,
          components: [_component('flutter', '3.44.6')],
        ),
        readActiveVersions: () async => {'flutter': '3.41.0'},
        artifactDownloader: downloader,
        target: target,
      );
      await controller.check();

      await controller.downloadAvailableUpdates();

      expect(downloader.componentIds, {'flutter'});
      expect(controller.state.downloading, isFalse);
      expect(controller.state.downloadProgress, 1);
    },
  );

  test('cancelling a pre-download is not reported as a failure', () async {
    final controller = UpdateController(
      manifestSource: () async => RuntimeManifest(
        schemaVersion: 1,
        components: [_component('flutter', '3.44.6')],
      ),
      readActiveVersions: () async => {'flutter': '3.41.0'},
      artifactDownloader: _CancellingUpdateDownloader(),
      target: target,
    );
    await controller.check();

    await controller.downloadAvailableUpdates();

    expect(controller.state.downloading, isFalse);
    expect(controller.state.downloadCancelled, isTrue);
    expect(controller.state.downloadErrorMessage, isNull);
  });

  test(
    'automatic pre-download only fetches updates to installed components',
    () async {
      final downloader = _RecordingUpdateDownloader();
      final controller = UpdateController(
        manifestSource: () async => RuntimeManifest(
          schemaVersion: 1,
          components: [
            _component('flutter', '3.44.6'),
            _component('node', '24.18.0'),
          ],
        ),
        readActiveVersions: () async => {'flutter': '3.41.0'},
        artifactDownloader: downloader,
        target: target,
      );
      await controller.check();

      await controller.downloadAvailableUpdates(includeNotInstalled: false);

      expect(downloader.componentIds, {'flutter'});
    },
  );

  test(
    'does not pre-download while another runtime operation owns the lock',
    () async {
      final operations = RuntimeOperationCoordinator();
      final lease = operations.tryAcquire('configure-environment')!;
      final downloader = _RecordingUpdateDownloader();
      final controller = UpdateController(
        manifestSource: () async => RuntimeManifest(
          schemaVersion: 1,
          components: [_component('flutter', '3.44.6')],
        ),
        readActiveVersions: () async => {'flutter': '3.41.0'},
        artifactDownloader: downloader,
        operations: operations,
        target: target,
      );
      addTearDown(operations.dispose);
      await controller.check();

      await controller.downloadAvailableUpdates();

      expect(downloader.componentIds, isNull);
      expect(controller.state.downloadErrorMessage, contains('另一项环境操作'));
      lease.release();
    },
  );
}

final class _RecordingUpdateDownloader implements UpdateArtifactDownloader {
  Set<String>? componentIds;

  @override
  void cancel() {}

  @override
  Future<void> download({
    required RuntimeManifest manifest,
    required Set<String> componentIds,
    required ValueChanged<double> onProgress,
  }) async {
    this.componentIds = componentIds;
    onProgress(0.5);
    onProgress(1);
  }
}

final class _CancellingUpdateDownloader implements UpdateArtifactDownloader {
  @override
  void cancel() {}

  @override
  Future<void> download({
    required RuntimeManifest manifest,
    required Set<String> componentIds,
    required ValueChanged<double> onProgress,
  }) async {
    throw const DownloadCancelledException();
  }
}

RuntimeComponent _component(
  String id,
  String version, {
  bool external = false,
}) {
  return RuntimeComponent(
    id: id,
    displayName: id,
    version: version,
    minimumCompatibleVersion: version,
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
    dependencies: const [],
  );
}
