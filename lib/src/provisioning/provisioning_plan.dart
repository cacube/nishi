import '../runtime_manifest/runtime_manifest.dart';
import 'runtime_target.dart';

final class ProvisioningPlanEntry {
  const ProvisioningPlanEntry({
    required this.component,
    required this.artifact,
  });

  final RuntimeComponent component;
  final RuntimeArtifact? artifact;
}

final class ProvisioningPlan {
  ProvisioningPlan._({required this.target, required this.entries});

  final RuntimeTarget target;
  final List<ProvisioningPlanEntry> entries;

  factory ProvisioningPlan.fromManifest(
    RuntimeManifest manifest,
    RuntimeTarget target, {
    Set<String>? componentIds,
  }) {
    final errors = <String>[];
    final entriesById = <String, ProvisioningPlanEntry>{};

    for (final component in manifest.components) {
      final appliesToTarget = component.executables.any(
        (executable) =>
            executable.platform == target.platform &&
            executable.architectures.contains(target.architecture),
      );
      if (!appliesToTarget) continue;

      RuntimeArtifact? artifact;
      if (component.isManaged) {
        final matching = component.artifacts.where(
          (candidate) =>
              candidate.platform == target.platform &&
              candidate.architecture == target.architecture,
        );
        if (matching.isEmpty) {
          errors.add('${component.id}: missing artifact for $target');
          continue;
        }
        artifact = matching.single;
      }
      entriesById[component.id] = ProvisioningPlanEntry(
        component: component,
        artifact: artifact,
      );
    }

    for (final entry in entriesById.values) {
      for (final dependency in entry.component.dependencies) {
        if (!entriesById.containsKey(dependency)) {
          errors.add(
            '${entry.component.id}: dependency $dependency is not available '
            'for $target',
          );
        }
      }
    }

    if (errors.isNotEmpty) throw ProvisioningPlanException(errors);

    final ordered = <ProvisioningPlanEntry>[];
    final visited = <String>{};
    void visit(String id) {
      if (!visited.add(id)) return;
      final entry = entriesById[id]!;
      for (final dependency in entry.component.dependencies) {
        visit(dependency);
      }
      ordered.add(entry);
    }

    final selectedIds = componentIds ?? entriesById.keys.toSet();
    for (final selectedId in selectedIds) {
      if (!entriesById.containsKey(selectedId)) {
        errors.add('$selectedId: component is not available for $target');
      }
    }
    if (errors.isNotEmpty) throw ProvisioningPlanException(errors);

    for (final component in manifest.components) {
      if (selectedIds.contains(component.id)) visit(component.id);
    }
    return ProvisioningPlan._(
      target: target,
      entries: List.unmodifiable(ordered),
    );
  }
}

final class ProvisioningPlanException implements Exception {
  ProvisioningPlanException(List<String> errors)
    : errors = List.unmodifiable(errors);

  final List<String> errors;

  @override
  String toString() => 'Provisioning plan failed:\n${errors.join('\n')}';
}
