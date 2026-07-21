import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows installer installs GUI and CLI for the current user', () async {
    final installer = await File('packaging/windows/lc.iss').readAsString();
    final buildScript = await File(
      'scripts/build_windows_installer.ps1',
    ).readAsString();

    expect(installer, contains('PrivilegesRequired=lowest'));
    expect(installer, contains('Source: "{#AppSource}\\*"'));
    expect(installer, contains('DestName: "lc.exe"'));
    expect(installer, contains('DevEnvironmentManager\\bin'));
    expect(installer, contains('AddCliToUserPath'));
    expect(installer, contains('RemoveCliFromUserPath'));
    expect(buildScript, contains('dart compile exe'));
    expect(buildScript, contains('lc-cli.exe'));
    expect(buildScript, contains('bin\\lc.dart'));
  });

  test('macOS package installs GUI and CLI into the user domain', () async {
    final distribution = await File(
      'packaging/macos/Distribution.xml',
    ).readAsString();
    final postInstall = await File(
      'packaging/macos/scripts/postinstall',
    ).readAsString();
    final uninstall = await File('packaging/macos/lc-uninstall').readAsString();
    final buildScript = await File(
      'scripts/build_macos_installer.sh',
    ).readAsString();

    expect(distribution, contains('enable_currentUserHome="true"'));
    expect(distribution, contains('enable_localSystem="false"'));
    expect(postInstall, contains('DevEnvironmentManager/bin'));
    expect(postInstall, contains('.zprofile'));
    expect(postInstall, contains('.bash_profile'));
    expect(uninstall, contains('Managed development data was preserved'));
    expect(buildScript, contains('dart'));
    expect(buildScript, contains('compile exe'));
    expect(buildScript, contains('bin/lc.dart'));
    expect(buildScript, contains('pkgbuild'));
    expect(buildScript, contains('productbuild'));
  });
}
