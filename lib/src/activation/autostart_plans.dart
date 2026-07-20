import 'dart:convert';
import 'dart:typed_data';

import 'activation_boundaries.dart';

final class ManagedArtifact {
  const ManagedArtifact({required this.path, required this.contents});

  final String path;
  final Uint8List contents;

  factory ManagedArtifact.text(String path, String contents) {
    return ManagedArtifact(
      path: path,
      contents: Uint8List.fromList(utf8.encode(contents)),
    );
  }
}

final class AutoStartPlan {
  const AutoStartPlan({
    required this.id,
    this.artifacts = const [],
    required this.enableCommands,
    required this.updateCommands,
    required this.disableCommands,
    required this.uninstallCommands,
  });

  final String id;
  final List<ManagedArtifact> artifacts;
  final List<ActivationCommand> enableCommands;
  final List<ActivationCommand> updateCommands;
  final List<ActivationCommand> disableCommands;
  final List<ActivationCommand> uninstallCommands;
}

final class MacOsLaunchAgentPlan {
  static AutoStartPlan build({
    required int userId,
    required String label,
    required String plistPath,
    required String executable,
    required List<String> arguments,
    required String stdoutPath,
    required String stderrPath,
    Map<String, String> environment = const {},
  }) {
    final domain = 'gui/$userId';
    final service = '$domain/$label';
    final bootout = ActivationCommand(
      executable: '/bin/launchctl',
      arguments: ['bootout', service],
      acceptedExitCodes: const {0, 3},
    );
    final bootstrap = ActivationCommand(
      executable: '/bin/launchctl',
      arguments: ['bootstrap', domain, plistPath],
    );
    final kickstart = ActivationCommand(
      executable: '/bin/launchctl',
      arguments: ['kickstart', '-k', service],
    );
    final enable = ActivationCommand(
      executable: '/bin/launchctl',
      arguments: ['enable', service],
    );
    final disable = ActivationCommand(
      executable: '/bin/launchctl',
      arguments: ['disable', service],
    );
    return AutoStartPlan(
      id: label,
      artifacts: [
        ManagedArtifact.text(
          plistPath,
          _renderPlist(
            label: label,
            executable: executable,
            arguments: arguments,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            environment: environment,
          ),
        ),
      ],
      enableCommands: [enable, bootstrap, kickstart],
      updateCommands: [bootout, enable, bootstrap, kickstart],
      disableCommands: [bootout, disable],
      uninstallCommands: [bootout, enable],
    );
  }

  static AutoStartPlan mysql({
    required int userId,
    required String plistPath,
    required String mysqlRoot,
    required String dataDirectory,
    required String logDirectory,
  }) {
    return build(
      userId: userId,
      label: 'com.devenvironmentmanager.mysql',
      plistPath: plistPath,
      executable: '$mysqlRoot/bin/mysqld',
      arguments: [
        '--datadir=$dataDirectory',
        '--log-error=$logDirectory/mysql-error.log',
        '--pid-file=$dataDirectory/mysql.pid',
      ],
      stdoutPath: '$logDirectory/mysql-stdout.log',
      stderrPath: '$logDirectory/mysql-stderr.log',
    );
  }

  static String _renderPlist({
    required String label,
    required String executable,
    required List<String> arguments,
    required String stdoutPath,
    required String stderrPath,
    required Map<String, String> environment,
  }) {
    final programArguments = [
      executable,
      ...arguments,
    ].map((value) => '    <string>${_xmlEscape(value)}</string>').join('\n');
    final environmentBlock = environment.isEmpty
        ? ''
        : '''
  <key>EnvironmentVariables</key>
  <dict>
${environment.entries.map((entry) => '    <key>${_xmlEscape(entry.key)}</key>\n    <string>${_xmlEscape(entry.value)}</string>').join('\n')}
  </dict>''';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
$programArguments
  </array>$environmentBlock
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${_xmlEscape(stdoutPath)}</string>
  <key>StandardErrorPath</key>
  <string>${_xmlEscape(stderrPath)}</string>
</dict>
</plist>
''';
  }
}

enum WindowsAutoStartKind { userTask, systemService }

final class WindowsAutoStartPlan {
  static AutoStartPlan userTask({
    required String id,
    required String taskName,
    required String executable,
    required List<String> arguments,
    List<ManagedArtifact> artifacts = const [],
  }) {
    final taskRun = _windowsCommandLine(executable, arguments);
    final create = ActivationCommand(
      executable: 'schtasks.exe',
      arguments: [
        '/Create',
        '/TN',
        taskName,
        '/SC',
        'ONLOGON',
        '/TR',
        taskRun,
        '/RL',
        'LIMITED',
        '/F',
      ],
    );
    final disable = ActivationCommand(
      executable: 'schtasks.exe',
      arguments: ['/Change', '/TN', taskName, '/DISABLE'],
    );
    final remove = ActivationCommand(
      executable: 'schtasks.exe',
      arguments: ['/Delete', '/TN', taskName, '/F'],
    );
    return AutoStartPlan(
      id: id,
      artifacts: artifacts,
      enableCommands: [create],
      updateCommands: [create],
      disableCommands: [disable],
      uninstallCommands: [remove],
    );
  }

  static AutoStartPlan mysqlUserTask({
    required String mysqlRoot,
    required String dataDirectory,
    required String logDirectory,
  }) {
    return userTask(
      id: 'mysql',
      taskName: r'DevEnvironmentManager\MySQL',
      executable: '$mysqlRoot\\bin\\mysqld.exe',
      arguments: [
        '--datadir=$dataDirectory',
        '--log-error=$logDirectory\\mysql-error.log',
      ],
    );
  }

  static AutoStartPlan memuraiUserTask({
    required String memuraiRoot,
    required String dataDirectory,
    required String logDirectory,
    required String configPath,
  }) {
    final config = _memuraiConfig(dataDirectory, logDirectory);
    return userTask(
      id: 'memurai',
      taskName: r'DevEnvironmentManager\Memurai',
      executable: '$memuraiRoot\\memurai.exe',
      arguments: [configPath],
      artifacts: [ManagedArtifact.text(configPath, config)],
    );
  }

  static AutoStartPlan memuraiSystemService({
    required String memuraiRoot,
    required String configPath,
    required String dataDirectory,
    required String logDirectory,
  }) {
    const elevation = ElevationRequirement.required;
    return AutoStartPlan(
      id: 'memurai-system-service',
      artifacts: [
        ManagedArtifact.text(
          configPath,
          _memuraiConfig(dataDirectory, logDirectory),
        ),
      ],
      enableCommands: [
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: ['--service-install', configPath],
          elevation: elevation,
        ),
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: const ['--service-start'],
          elevation: elevation,
        ),
      ],
      updateCommands: [
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: const ['--service-stop'],
          elevation: elevation,
        ),
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: ['--service-install', configPath],
          elevation: elevation,
        ),
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: const ['--service-start'],
          elevation: elevation,
        ),
      ],
      disableCommands: [
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: const ['--service-stop'],
          elevation: elevation,
        ),
      ],
      uninstallCommands: [
        ActivationCommand(
          executable: '$memuraiRoot\\memurai.exe',
          arguments: const ['--service-uninstall'],
          elevation: elevation,
        ),
      ],
    );
  }
}

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _windowsCommandLine(String executable, List<String> arguments) {
  return [_windowsQuote(executable), ...arguments.map(_windowsQuote)].join(' ');
}

String _windowsQuote(String value) {
  if (value.isEmpty) return '""';
  if (!RegExp(r'[\s"]').hasMatch(value)) return value;
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final codePoint in value.runes) {
    final character = String.fromCharCode(codePoint);
    if (character == r'\') {
      backslashes++;
    } else if (character == '"') {
      buffer
        ..write(r'\' * (backslashes * 2 + 1))
        ..write('"');
      backslashes = 0;
    } else {
      buffer
        ..write(r'\' * backslashes)
        ..write(character);
      backslashes = 0;
    }
  }
  buffer
    ..write(r'\' * (backslashes * 2))
    ..write('"');
  return buffer.toString();
}

String _redisQuote(String value) {
  return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

String _memuraiConfig(String dataDirectory, String logDirectory) {
  return '''dir ${_redisQuote(dataDirectory)}
logfile ${_redisQuote('$logDirectory\\memurai.log')}
daemonize no
''';
}
