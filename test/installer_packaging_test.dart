import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows installer installs only the GUI for the current user',
    () async {
      final installer = await File('packaging/windows/lc.iss').readAsString();
      final buildScript = await File(
        'scripts/build_windows_installer.ps1',
      ).readAsString();

      expect(installer, contains('PrivilegesRequired=lowest'));
      expect(installer, contains('Source: "{#AppSource}\\*"'));
      expect(installer, isNot(contains('#ifndef CliSource')));
      expect(installer, isNot(contains('AddCliToUserPath')));
      expect(installer, contains('RemoveLegacyCliArtifacts'));
      expect(buildScript, isNot(contains('dart compile exe')));
      expect(buildScript, isNot(contains('bin\\lc.dart')));
    },
  );

  test('macOS package installs only the GUI into the user domain', () async {
    final distribution = await File(
      'packaging/macos/Distribution.xml',
    ).readAsString();
    final postInstall = await File(
      'packaging/macos/scripts/postinstall',
    ).readAsString();
    final buildScript = await File(
      'scripts/build_macos_installer.sh',
    ).readAsString();

    expect(distribution, contains('enable_currentUserHome="true"'));
    expect(distribution, contains('enable_localSystem="false"'));
    expect(postInstall, contains('remove_legacy_profile_hook'));
    expect(postInstall, isNot(contains('install_profile_hook')));
    expect(buildScript, isNot(contains('compile exe')));
    expect(buildScript, isNot(contains('bin/lc.dart')));
    expect(buildScript, contains('pkgbuild'));
    expect(buildScript, contains('productbuild'));
  });

  test(
    'macOS postinstall removes legacy CLI files and profile hooks',
    () async {
      if (!Platform.isMacOS) return;
      final home = await Directory.systemTemp.createTemp(
        'lc-app-only-migration-',
      );
      addTearDown(() => home.delete(recursive: true));
      final support = Directory(
        '${home.path}/Library/Application Support/DevEnvironmentManager',
      );
      final bin = Directory('${support.path}/bin');
      await bin.create(recursive: true);
      await File('${bin.path}/lc').writeAsString('legacy');
      await File('${bin.path}/lc-uninstall').writeAsString('legacy');
      await File('${support.path}/lc-path.sh').writeAsString('legacy');
      for (final name in ['.zprofile', '.bash_profile']) {
        await File('${home.path}/$name').writeAsString('''before
# >>> lc CLI >>>
legacy hook
# <<< lc CLI <<<
after
''');
      }

      final result = await Process.run('/bin/sh', [
        'packaging/macos/scripts/postinstall',
        'unused',
        'unused',
        home.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await File('${bin.path}/lc').exists(), isFalse);
      expect(await File('${bin.path}/lc-uninstall').exists(), isFalse);
      expect(await File('${support.path}/lc-path.sh').exists(), isFalse);
      for (final name in ['.zprofile', '.bash_profile']) {
        final profile = await File('${home.path}/$name').readAsString();
        expect(profile, contains('before'));
        expect(profile, contains('after'));
        expect(profile, isNot(contains('lc CLI')));
      }
    },
  );
}
