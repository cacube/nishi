import '../download/download_manager.dart';
import '../install/artifact_installer.dart';
import '../runtime_manifest/runtime_manifest.dart';
import '../setup/setup_orchestrator.dart';
import '../setup/setup_task.dart';
import '../storage/runtime_layout.dart';
import 'provisioning_plan.dart';
import 'runtime_provisioning_action.dart';
import 'runtime_target.dart';

typedef RuntimeManifestSource = Future<RuntimeManifest> Function();

final class ProvisioningWorkflow {
  ProvisioningWorkflow({
    required RuntimeLayout layout,
    required DownloadManager downloads,
    required ArtifactInstaller installer,
    RuntimeTarget? target,
  }) : _layout = layout,
       _downloads = downloads,
       _installer = installer,
       _target = target ?? RuntimeTarget.current();

  final RuntimeLayout _layout;
  final DownloadManager _downloads;
  final ArtifactInstaller _installer;
  final RuntimeTarget _target;

  Future<SetupOrchestrator> prepare(RuntimeManifestSource source) async {
    await _layout.ensureCreated();
    final manifest = await source();
    final plan = ProvisioningPlan.fromManifest(manifest, _target);
    final tasks = <SetupTaskDefinition>[];
    final actions = <String, SetupTaskAction>{};

    for (final entry in plan.entries) {
      final component = entry.component;
      tasks.add(
        SetupTaskDefinition(
          id: component.id,
          label: component.displayName,
          dependencies: component.dependencies,
          externallyManaged: component.isExternal,
        ),
      );
      final artifact = entry.artifact;
      if (artifact != null) {
        actions[component.id] = RuntimeProvisioningAction(
          component: component,
          artifact: artifact,
          layout: _layout,
          downloads: _downloads,
          installer: _installer,
        );
      }
    }

    return SetupOrchestrator(tasks: tasks, actions: actions);
  }
}
