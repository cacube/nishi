import 'dart:io';

import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a user-scoped macOS layout', () {
    final layout = RuntimeLayout.forCurrentUser(
      environment: const {'HOME': '/Users/tester'},
      operatingSystem: HostOperatingSystem.macos,
    );

    expect(
      layout.root.path,
      _path('/Users/tester/Library/Application Support/DevEnvironmentManager'),
    );
    expect(
      layout.componentVersion('flutter', '3.41.4').path,
      endsWith(_path('runtimes/flutter/3.41.4')),
    );
    expect(
      layout.componentStaging('flutter', '3.41.4').path,
      endsWith(_path('runtimes/flutter/3.41.4.staging')),
    );
    expect(layout.bin.path, endsWith(_path('DevEnvironmentManager/bin')));
  });

  test('builds a user-scoped Windows layout', () {
    final layout = RuntimeLayout.forCurrentUser(
      environment: const {'LOCALAPPDATA': r'C:\Users\tester\AppData\Local'},
      operatingSystem: HostOperatingSystem.windows,
    );

    expect(layout.root.path, contains('DevEnvironmentManager'));
    expect(layout.cache.path, endsWith(_path('DevEnvironmentManager/cache')));
    expect(layout.bin.path, endsWith(_path('DevEnvironmentManager/bin')));
  });

  test('rejects path traversal in component and version names', () {
    final layout = RuntimeLayout.forCurrentUser(
      environment: const {'HOME': '/Users/tester'},
      operatingSystem: HostOperatingSystem.macos,
    );

    expect(() => layout.componentVersions('../flutter'), throwsArgumentError);
    expect(
      () => layout.componentVersion('flutter', '../../current'),
      throwsArgumentError,
    );
  });
}

String _path(String value) => value.replaceAll('/', Platform.pathSeparator);
