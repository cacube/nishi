import '../download/download_manager.dart';
import '../environment/environment_controller.dart';
import '../environment/environment_scanner.dart';
import '../install/artifact_installer.dart';
import '../manifest_security/remote_manifest_release_configuration.dart';
import '../provisioning/provisioning_workflow.dart';
import '../setup/license_acceptance.dart';
import '../storage/runtime_layout.dart';
import 'setup_ui_controller.dart';

final class SetupComposition {
  SetupComposition._({
    required this.environment,
    required this.setup,
    required DownloadManager? downloads,
  }) : _downloads = downloads;

  factory SetupComposition.forTesting({
    required EnvironmentController environment,
    required SetupUiController setup,
  }) {
    return SetupComposition._(
      environment: environment,
      setup: setup,
      downloads: null,
    );
  }

  factory SetupComposition.forCurrentUser() {
    final layout = RuntimeLayout.forCurrentUser();
    final downloads = DownloadManager();
    final environment = EnvironmentController(
      scanner: EnvironmentScanner(layout: layout),
    );
    final licenses = LicenseAcceptanceRegistry();
    final workflow = ProvisioningWorkflow(
      layout: layout,
      downloads: downloads,
      installer: ArtifactInstaller(layout: layout),
      licenseAcceptance: licenses,
    );
    final setup = SetupUiController.forRemoteRelease(
      workflow: workflow,
      releaseConfiguration:
          RemoteManifestReleaseConfiguration.fromEnvironment(),
      environmentController: environment,
      preflightConfirmations: [androidSdkLicensePreflight],
      onPreflightAccepted: licenses.acceptAll,
    );
    return SetupComposition._(
      environment: environment,
      setup: setup,
      downloads: downloads,
    );
  }

  final EnvironmentController environment;
  final SetupUiController setup;
  final DownloadManager? _downloads;

  void dispose() {
    setup.dispose();
    environment.dispose();
    _downloads?.close(force: true);
  }
}
