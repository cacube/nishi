import 'package:dev_environment_manager/src/provisioning/provisioning_plan.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const target = RuntimeTarget(
    platform: RuntimePlatform.macos,
    architecture: RuntimeArchitecture.arm64,
  );

  test('selects the host artifact and orders dependencies first', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [
        _component('android', dependencies: ['jdk']),
        _component('jdk'),
        _component('xcode', external: true),
      ],
    );

    final plan = ProvisioningPlan.fromManifest(manifest, target);

    expect(plan.entries.map((entry) => entry.component.id), [
      'jdk',
      'android',
      'xcode',
    ]);
    expect(plan.entries[0].artifact?.architecture, RuntimeArchitecture.arm64);
    expect(plan.entries.last.artifact, isNull);
  });

  test('reports every component missing an artifact for the host', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [
        _component('flutter', architecture: RuntimeArchitecture.x64),
        _component('go', architecture: RuntimeArchitecture.x64),
      ],
    );

    expect(
      () => ProvisioningPlan.fromManifest(manifest, target),
      throwsA(
        isA<ProvisioningPlanException>().having(
          (error) => error.errors,
          'errors',
          containsAll([
            'flutter: missing artifact for macos/arm64',
            'go: missing artifact for macos/arm64',
          ]),
        ),
      ),
    );
  });

  test('skips components declared only for another host platform', () {
    final manifest = RuntimeManifest(
      schemaVersion: 1,
      components: [
        _component('flutter'),
        _component(
          'memurai',
          platform: RuntimePlatform.windows,
          architecture: RuntimeArchitecture.x64,
        ),
      ],
    );

    final plan = ProvisioningPlan.fromManifest(manifest, target);

    expect(plan.entries.map((entry) => entry.component.id), ['flutter']);
  });
}

RuntimeComponent _component(
  String id, {
  List<String> dependencies = const [],
  RuntimeArchitecture architecture = RuntimeArchitecture.arm64,
  RuntimePlatform platform = RuntimePlatform.macos,
  bool external = false,
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
              platform: platform,
              architecture: architecture,
              officialUrl: Uri.parse('https://example.invalid/$id.zip'),
              sha256: 'a' * 64,
              archiveType: RuntimeArchiveType.zip,
            ),
          ],
    executables: [
      RuntimeExecutable(
        platform: platform,
        architectures: const [
          RuntimeArchitecture.x64,
          RuntimeArchitecture.arm64,
        ],
        path: 'bin/$id',
      ),
    ],
    dependencies: dependencies,
  );
}
