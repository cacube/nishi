import 'dart:io';

import 'package:dev_environment_manager/src/environment/environment_scanner.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adds active managed runtimes to command environment', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'managed_scanner_environment_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporary.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    await layout.recordActiveVersion('jdk', '17.0.19+10');
    await layout.recordActiveVersion('android-sdk', '36.0.0');
    await layout.recordActiveVersion('flutter', '3.44.6');
    await layout.recordActiveVersion('go', '1.26.5');
    await layout.recordActiveVersion('node', '24.18.0');
    await layout.recordActiveVersion('mysql', '8.4.10');

    final environment = EnvironmentScanner(
      layout: layout,
      baseEnvironment: {'HOME': temporary.path, 'PATH': '/usr/bin'},
    ).commandEnvironment();

    expect(
      environment['JAVA_HOME'],
      layout.componentVersion('jdk', '17.0.19+10').path,
    );
    expect(
      environment['ANDROID_SDK_ROOT'],
      layout.componentVersion('android-sdk', '36.0.0').path,
    );
    expect(environment['ANDROID_HOME'], environment['ANDROID_SDK_ROOT']);
    expect(
      environment['PATH'],
      allOf(
        contains('${layout.componentVersion('flutter', '3.44.6').path}/bin'),
        contains(
          '${layout.componentVersion('android-sdk', '36.0.0').path}/platform-tools',
        ),
        contains('${layout.componentVersion('go', '1.26.5').path}/bin'),
        contains('${layout.componentVersion('node', '24.18.0').path}/bin'),
        contains('${layout.componentVersion('mysql', '8.4.10').path}/bin'),
        contains('/usr/bin'),
      ),
    );
  });
}
