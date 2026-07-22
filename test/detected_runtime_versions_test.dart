import 'package:dev_environment_manager/src/environment/environment_component.dart';
import 'package:dev_environment_manager/src/update/detected_runtime_versions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps usable host components to manifest component IDs', () {
    final versions = detectedRuntimeVersions([
      _component('flutter', ComponentStatus.ready, '3.41.4'),
      _component('java', ComponentStatus.ready, '20.0.2'),
      _component('android', ComponentStatus.attention, '36.0.0'),
      _component('mysql', ComponentStatus.attention, '9.3.0'),
      _component('go', ComponentStatus.missing, '1.24.5'),
      _component('browser', ComponentStatus.ready, 'Google Chrome'),
    ]);

    expect(versions, {
      'flutter': '3.41.4',
      'jdk': '20.0.2',
      'android-sdk': '36.0.0',
      'mysql': '9.3.0',
    });
  });
}

EnvironmentComponent _component(
  String id,
  ComponentStatus status,
  String version,
) {
  return EnvironmentComponent(
    id: id,
    name: id,
    group: ComponentGroup.tools,
    icon: Icons.build,
    required: true,
    status: status,
    version: version,
  );
}
