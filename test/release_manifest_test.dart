import 'dart:io';

import 'package:dev_environment_manager/src/provisioning/provisioning_plan.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production manifest supports every released desktop target', () async {
    final file = File('release/runtime-manifest.json');
    final source = await file.readAsString();
    final manifest = const RuntimeManifestLoader().decode(source);

    expect(source, isNot(contains('example.invalid')));
    expect(manifest.componentById('flutter')?.version, '3.44.6');
    expect(manifest.componentById('jdk')?.version, '17.0.19+10');
    expect(manifest.componentById('go')?.minimumCompatibleVersion, '1.24.2');
    expect(manifest.componentById('node')?.version, '24.18.0');
    expect(manifest.componentById('mysql')?.version, '8.4.10');
    expect(manifest.componentById('android-sdk')?.androidSdk?.packages, [
      'platform-tools',
      'platforms;android-36',
      'build-tools;36.0.0',
    ]);

    for (final target in const [
      RuntimeTarget(
        platform: RuntimePlatform.windows,
        architecture: RuntimeArchitecture.x64,
      ),
      RuntimeTarget(
        platform: RuntimePlatform.macos,
        architecture: RuntimeArchitecture.x64,
      ),
      RuntimeTarget(
        platform: RuntimePlatform.macos,
        architecture: RuntimeArchitecture.arm64,
      ),
    ]) {
      final plan = ProvisioningPlan.fromManifest(manifest, target);
      expect(
        plan.entries.map((entry) => entry.component.id),
        containsAll(['jdk', 'android-sdk', 'flutter', 'go', 'node', 'mysql']),
        reason: 'target $target must have the full managed toolchain',
      );
      for (final entry in plan.entries.where(
        (entry) => entry.component.isManaged,
      )) {
        expect(
          entry.artifact,
          isNotNull,
          reason: '${entry.component.id} $target',
        );
      }
    }
  });
}
