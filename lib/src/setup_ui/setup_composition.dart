import 'dart:io';

import '../download/download_manager.dart';
import '../environment/environment_controller.dart';
import '../environment/environment_scanner.dart';
import '../install/artifact_installer.dart';
import '../manifest_security/remote_manifest_release_configuration.dart';
import '../mysql/mysql_credentials.dart';
import '../operation/runtime_operation_coordinator.dart';
import '../provisioning/managed_runtime_health.dart';
import '../provisioning/provisioning_workflow.dart';
import '../provisioning/runtime_target.dart';
import '../runtime_manifest/runtime_manifest.dart';
import '../setup/license_acceptance.dart';
import '../settings/settings.dart';
import '../storage/runtime_layout.dart';
import '../update/update.dart';
import 'setup_ui_controller.dart';

final class SetupComposition {
  SetupComposition._({
    required this.environment,
    required this.setup,
    required this.settings,
    required this.updates,
    required this.operations,
    required this.mysqlCredentials,
    required DownloadManager? downloads,
  }) : _downloads = downloads;

  factory SetupComposition.forTesting({
    required EnvironmentController environment,
    required SetupUiController setup,
    SettingsController? settings,
    UpdateController? updates,
    MySqlCredentialsReader mysqlCredentials =
        const EmptyMySqlCredentialsReader(),
  }) {
    final testSettings =
        settings ??
        SettingsController(
          store: MemorySettingsStore(
            const AppSettings(autoCheckUpdates: false),
          ),
        );
    final testUpdates =
        updates ??
        UpdateController(
          manifestSource: () async =>
              RuntimeManifest(schemaVersion: 1, components: const []),
          readActiveVersions: () async => const {},
          target: const RuntimeTarget(
            platform: RuntimePlatform.macos,
            architecture: RuntimeArchitecture.arm64,
          ),
        );
    return SetupComposition._(
      environment: environment,
      setup: setup,
      settings: testSettings,
      updates: testUpdates,
      operations: RuntimeOperationCoordinator(),
      mysqlCredentials: mysqlCredentials,
      downloads: null,
    );
  }

  factory SetupComposition.forCurrentUser() {
    final layout = RuntimeLayout.forCurrentUser();
    final operations = RuntimeOperationCoordinator();
    final target = RuntimeTarget.current();
    final environment = EnvironmentController(
      scanner: EnvironmentScanner(layout: layout),
    );
    late final ProvisioningWorkflow workflow;
    final settings = SettingsController(
      store: JsonSettingsStore(File('${layout.root.path}/settings.json')),
      layout: layout,
      repairEnvironment: () async {
        await workflow.repairHostEnvironment();
        await environment.scan();
      },
      operations: operations,
    );
    final downloads = DownloadManager(
      sourceOrderer: settings.orderDownloadSources,
    );
    final licenses = LicenseAcceptanceRegistry();
    workflow = ProvisioningWorkflow(
      layout: layout,
      downloads: downloads,
      installer: ArtifactInstaller(layout: layout),
      licenseAcceptance: licenses,
      sourceOrderer: settings.orderDownloadSources,
      target: target,
    );
    final releaseConfiguration =
        RemoteManifestReleaseConfiguration.fromEnvironment();
    Future<RuntimeManifest> manifestSource() async {
      final loader = releaseConfiguration.createLoader();
      try {
        return await loader.load(
          manifestUri: releaseConfiguration.manifestUri,
          signatureUri: releaseConfiguration.signatureUri,
        );
      } finally {
        loader.close();
      }
    }

    final setup = SetupUiController.forRemoteRelease(
      workflow: workflow,
      releaseConfiguration: releaseConfiguration,
      environmentController: environment,
      preflightConfirmations: [androidSdkLicensePreflight],
      onPreflightAccepted: licenses.acceptAll,
      manifestSourceOverride: manifestSource,
      operations: operations,
    );
    final updates = UpdateController(
      manifestSource: manifestSource,
      readActiveVersions: layout.readActiveVersions,
      artifactDownloader: RuntimeUpdateDownloader(
        layout: layout,
        downloads: downloads,
        readActiveVersions: layout.readActiveVersions,
        target: target,
      ),
      operations: operations,
      target: target,
      validateActiveVersion: (component, version) => managedRuntimeIsUsable(
        layout: layout,
        component: component,
        version: version,
        target: target,
      ),
    );
    return SetupComposition._(
      environment: environment,
      setup: setup,
      settings: settings,
      updates: updates,
      operations: operations,
      mysqlCredentials: FileMySqlCredentialsReader(
        File(
          '${layout.data.path}${Platform.pathSeparator}mysql'
          '${Platform.pathSeparator}credentials.json',
        ),
      ),
      downloads: downloads,
    );
  }

  final EnvironmentController environment;
  final SetupUiController setup;
  final SettingsController settings;
  final UpdateController updates;
  final RuntimeOperationCoordinator operations;
  final MySqlCredentialsReader mysqlCredentials;
  final DownloadManager? _downloads;

  void dispose() {
    setup.dispose();
    environment.dispose();
    settings.dispose();
    updates.dispose();
    operations.dispose();
    _downloads?.close(force: true);
  }
}
