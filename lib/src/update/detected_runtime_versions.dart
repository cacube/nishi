import '../compatibility/software_version.dart';
import '../environment/environment_component.dart';

Map<String, String> detectedRuntimeVersions(
  Iterable<EnvironmentComponent> components,
) {
  final versions = <String, String>{};
  for (final component in components) {
    if (component.status == ComponentStatus.checking ||
        component.status == ComponentStatus.missing) {
      continue;
    }
    final componentId = switch (component.id) {
      'java' => 'jdk',
      'android' => 'android-sdk',
      'flutter' || 'go' || 'node' || 'mysql' => component.id,
      _ => null,
    };
    final version = component.version?.trim();
    if (componentId != null &&
        version != null &&
        SoftwareVersion.tryParse(version) != null) {
      versions[componentId] = version;
    }
  }
  return Map.unmodifiable(versions);
}
