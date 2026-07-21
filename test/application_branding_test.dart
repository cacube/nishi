import 'dart:io';

import 'package:dev_environment_manager/src/app_brand.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses lc as the public application name', () {
    expect(applicationName, 'lc');
    expect(applicationVersion, '1.0.0');
  });

  test('macOS build metadata produces lc.app', () async {
    final appInfo = await File(
      'macos/Runner/Configs/AppInfo.xcconfig',
    ).readAsString();
    final infoPlist = await File('macos/Runner/Info.plist').readAsString();
    final scheme = await File(
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    ).readAsString();
    final window = await File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsString();

    expect(appInfo, contains('PRODUCT_NAME = lc'));
    expect(infoPlist, contains('<string>lc</string>'));
    expect(scheme, contains('BuildableName = "lc.app"'));
    expect(window, contains('self.title = "lc"'));
  });

  test('Windows build metadata produces lc.exe', () async {
    final cmake = await File('windows/CMakeLists.txt').readAsString();
    final resources = await File('windows/runner/Runner.rc').readAsString();
    final runner = await File('windows/runner/main.cpp').readAsString();

    expect(cmake, contains('set(BINARY_NAME "lc")'));
    expect(resources, contains('VALUE "ProductName", "lc"'));
    expect(resources, contains('VALUE "OriginalFilename", "lc.exe"'));
    expect(runner, contains('window.Create(L"lc"'));
  });

  test('keeps existing storage and release protocol identifiers', () async {
    final layout = await File(
      'lib/src/storage/runtime_layout.dart',
    ).readAsString();
    final release = await File(
      'lib/src/manifest_security/remote_manifest_release_configuration.dart',
    ).readAsString();

    expect(layout, contains("'DevEnvironmentManager'"));
    expect(release, contains('NISHI_RUNTIME_MANIFEST_URL'));
    expect(release, contains('github.com/cacube/nishi'));
  });
}
