import 'dart:convert';
import 'dart:typed_data';

import 'activation_boundaries.dart';
import 'environment_activation.dart';

const _payloadEnvironmentKey = 'NISHI_ENVIRONMENT_PAYLOAD';
const _defaultLaunchAgentLabel = 'com.cacube.nishi.environment';

final class HostEnvironmentInstallPaths {
  const HostEnvironmentInstallPaths.windows({required this.stateFile})
    : replayScript = null,
      launchAgentPlist = null,
      launchAgentLabel = _defaultLaunchAgentLabel;

  const HostEnvironmentInstallPaths.macos({
    required this.stateFile,
    required String this.replayScript,
    required String this.launchAgentPlist,
    this.launchAgentLabel = _defaultLaunchAgentLabel,
  });

  final String stateFile;
  final String? replayScript;
  final String? launchAgentPlist;
  final String launchAgentLabel;

  List<String> filesFor(ActivationHost host) {
    if (host == ActivationHost.windows) return [stateFile];
    final script = replayScript;
    final plist = launchAgentPlist;
    if (script == null || plist == null) {
      throw ArgumentError(
        'macOS host environment paths require a replay script and LaunchAgent',
      );
    }
    return [stateFile, script, plist];
  }
}

final class HostEnvironmentInstallException implements Exception {
  const HostEnvironmentInstallException({
    required this.operation,
    required this.host,
    required this.stage,
    this.exitCode,
  });

  final String operation;
  final ActivationHost host;
  final String stage;
  final int? exitCode;

  @override
  String toString() {
    final code = exitCode == null ? '' : ' (exit code $exitCode)';
    return 'Host environment $operation failed on ${host.name} at $stage$code.';
  }
}

final class HostEnvironmentInstallReceipt {
  HostEnvironmentInstallReceipt._(this._rollback);

  final Future<void> Function() _rollback;
  bool _rolledBack = false;

  Future<void> rollback() async {
    if (_rolledBack) return;
    await _rollback();
    _rolledBack = true;
  }
}

final class HostEnvironmentInstaller {
  HostEnvironmentInstaller({
    required ActivationFileStore files,
    required ActivationProcessRunner processes,
  }) : _files = files,
       _processes = processes;

  final ActivationFileStore _files;
  final ActivationProcessRunner _processes;

  Future<HostEnvironmentInstallReceipt> install({
    required ActivationHost host,
    required HostEnvironmentInstallPaths paths,
    required Map<String, String> environment,
  }) async {
    _validateEnvironment(environment);
    final artifactPaths = paths.filesFor(host);
    final previousFiles = await _readFiles(artifactPaths);
    final oldState = _readState(previousFiles[paths.stateFile], host);
    final oldManagedKeys = oldState?.managedKeys ?? const <String>[];
    final affectedNames = <String>{...oldManagedKeys, ...environment.keys};
    Map<String, String?>? immediatePrevious;
    var environmentAttempted = false;

    try {
      immediatePrevious = await _readHostEnvironment(host, affectedNames);
      final desired = <String, String?>{
        for (final name in oldManagedKeys)
          if (!environment.containsKey(name)) name: oldState!.previous[name],
        ...environment,
      };
      final persistentPrevious = <String, String?>{
        for (final name in environment.keys)
          name: oldState?.previous.containsKey(name) ?? false
              ? oldState!.previous[name]
              : immediatePrevious[name],
      };
      final state = _HostEnvironmentState(
        host: host,
        managedKeys: environment.keys.toList(growable: false),
        previous: persistentPrevious,
      );

      await _files.writeAtomically(paths.stateFile, state.encode());
      if (host == ActivationHost.macos) {
        await _files.writeAtomically(
          paths.replayScript!,
          _encodeText(_renderReplayScript(environment)),
        );
        await _files.writeAtomically(
          paths.launchAgentPlist!,
          _encodeText(
            _renderLaunchAgent(
              label: paths.launchAgentLabel,
              replayScript: paths.replayScript!,
            ),
          ),
        );
      }

      environmentAttempted = true;
      await _writeHostEnvironment(host, desired, operation: 'install');
    } on Object catch (error) {
      if (environmentAttempted && immediatePrevious != null) {
        await _bestEffortWriteHostEnvironment(host, immediatePrevious);
      }
      await _bestEffortRestoreFiles(previousFiles);
      if (error is HostEnvironmentInstallException) rethrow;
      throw HostEnvironmentInstallException(
        operation: 'install',
        host: host,
        stage: 'managed files',
      );
    }

    final rollbackEnvironment = Map<String, String?>.of(immediatePrevious);
    return HostEnvironmentInstallReceipt._(() async {
      Object? failure;
      try {
        await _writeHostEnvironment(
          host,
          rollbackEnvironment,
          operation: 'rollback',
        );
      } on Object catch (error) {
        failure = error;
      }
      try {
        await _restoreFiles(previousFiles);
      } on Object {
        failure ??= HostEnvironmentInstallException(
          operation: 'rollback',
          host: host,
          stage: 'managed files',
        );
      }
      if (failure != null) throw failure;
    });
  }

  Future<void> uninstall({
    required ActivationHost host,
    required HostEnvironmentInstallPaths paths,
  }) async {
    final artifactPaths = paths.filesFor(host);
    final previousFiles = await _readFiles(artifactPaths);
    final state = _readState(previousFiles[paths.stateFile], host);
    if (state == null) {
      await _deleteFiles(artifactPaths, host: host);
      return;
    }

    final immediatePrevious = await _readHostEnvironment(
      host,
      state.managedKeys.toSet(),
    );
    var environmentAttempted = false;
    try {
      environmentAttempted = true;
      await _writeHostEnvironment(host, state.previous, operation: 'uninstall');
      await _deleteFiles(artifactPaths, host: host);
    } on Object catch (error) {
      if (environmentAttempted) {
        await _bestEffortWriteHostEnvironment(host, immediatePrevious);
      }
      await _bestEffortRestoreFiles(previousFiles);
      if (error is HostEnvironmentInstallException) rethrow;
      throw HostEnvironmentInstallException(
        operation: 'uninstall',
        host: host,
        stage: 'managed files',
      );
    }
  }

  Future<Map<String, Uint8List?>> _readFiles(List<String> paths) async {
    return {for (final path in paths) path: await _files.read(path)};
  }

  Future<Map<String, String?>> _readHostEnvironment(
    ActivationHost host,
    Set<String> names,
  ) {
    if (host == ActivationHost.windows) return _readWindowsEnvironment(names);
    return _readMacOsEnvironment(names);
  }

  Future<void> _writeHostEnvironment(
    ActivationHost host,
    Map<String, String?> environment, {
    required String operation,
  }) {
    if (host == ActivationHost.windows) {
      return _writeWindowsEnvironment(environment, operation: operation);
    }
    return _writeMacOsEnvironment(environment, operation: operation);
  }

  Future<Map<String, String?>> _readWindowsEnvironment(
    Set<String> names,
  ) async {
    if (names.isEmpty) return {};
    final result = await _processes.run(
      _powerShellCommand({'action': 'get', 'names': names.toList()}),
    );
    if (result.exitCode != 0) {
      throw HostEnvironmentInstallException(
        operation: 'read',
        host: ActivationHost.windows,
        stage: 'user environment',
        exitCode: result.exitCode,
      );
    }
    try {
      final decoded =
          jsonDecode(utf8.decode(base64Decode(result.stdout.trim())))!
              as Map<String, dynamic>;
      final values = decoded['values']! as Map<String, dynamic>;
      return {for (final name in names) name: values[name] as String?};
    } on Object {
      throw const HostEnvironmentInstallException(
        operation: 'read',
        host: ActivationHost.windows,
        stage: 'PowerShell response',
      );
    }
  }

  Future<void> _writeWindowsEnvironment(
    Map<String, String?> environment, {
    required String operation,
  }) async {
    if (environment.isEmpty) return;
    final result = await _processes.run(
      _powerShellCommand({'action': 'set', 'variables': environment}),
    );
    if (result.exitCode != 0) {
      throw HostEnvironmentInstallException(
        operation: operation,
        host: ActivationHost.windows,
        stage: 'user environment',
        exitCode: result.exitCode,
      );
    }
  }

  ActivationCommand _powerShellCommand(Map<String, Object?> payload) {
    final payloadBase64 = base64Encode(utf8.encode(jsonEncode(payload)));
    final scriptBase64 = base64Encode(_utf16LeEncode(_powerShellScript));
    return ActivationCommand(
      executable: 'powershell.exe',
      arguments: [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        scriptBase64,
      ],
      environment: {_payloadEnvironmentKey: payloadBase64},
      elevation: ElevationRequirement.none,
    );
  }

  Future<Map<String, String?>> _readMacOsEnvironment(Set<String> names) async {
    final values = <String, String?>{};
    for (final name in names) {
      final result = await _processes.run(
        ActivationCommand(
          executable: '/bin/launchctl',
          arguments: ['getenv', name],
        ),
      );
      if (result.exitCode != 0) {
        throw HostEnvironmentInstallException(
          operation: 'read',
          host: ActivationHost.macos,
          stage: 'launchd environment',
          exitCode: result.exitCode,
        );
      }
      final value = _removeOneLineEnding(result.stdout);
      values[name] = value.isEmpty ? null : value;
    }
    return values;
  }

  Future<void> _writeMacOsEnvironment(
    Map<String, String?> environment, {
    required String operation,
  }) async {
    for (final entry in environment.entries) {
      final value = entry.value;
      final arguments = value == null
          ? ['unsetenv', entry.key]
          : ['setenv', entry.key, value];
      final result = await _processes.run(
        ActivationCommand(executable: '/bin/launchctl', arguments: arguments),
      );
      if (result.exitCode != 0) {
        throw HostEnvironmentInstallException(
          operation: operation,
          host: ActivationHost.macos,
          stage: 'launchd environment',
          exitCode: result.exitCode,
        );
      }
    }
  }

  Future<void> _bestEffortWriteHostEnvironment(
    ActivationHost host,
    Map<String, String?> environment,
  ) async {
    try {
      await _writeHostEnvironment(host, environment, operation: 'rollback');
    } on Object {
      // Preserve the original failure. The public error never includes values.
    }
  }

  Future<void> _deleteFiles(
    List<String> paths, {
    required ActivationHost host,
  }) async {
    try {
      for (final path in paths.reversed) {
        await _files.delete(path);
      }
    } on Object {
      throw HostEnvironmentInstallException(
        operation: 'uninstall',
        host: host,
        stage: 'managed files',
      );
    }
  }

  Future<void> _restoreFiles(Map<String, Uint8List?> previousFiles) async {
    for (final entry in previousFiles.entries) {
      if (entry.value == null) {
        await _files.delete(entry.key);
      } else {
        await _files.writeAtomically(entry.key, entry.value!);
      }
    }
  }

  Future<void> _bestEffortRestoreFiles(
    Map<String, Uint8List?> previousFiles,
  ) async {
    try {
      await _restoreFiles(previousFiles);
    } on Object {
      // Preserve the original failure without exposing managed file contents.
    }
  }
}

final class _HostEnvironmentState {
  const _HostEnvironmentState({
    required this.host,
    required this.managedKeys,
    required this.previous,
  });

  final ActivationHost host;
  final List<String> managedKeys;
  final Map<String, String?> previous;

  Uint8List encode() {
    return _encodeText(
      '${jsonEncode({'schemaVersion': 1, 'host': host.name, 'managedKeys': managedKeys, 'previousEnvironment': previous})}\n',
    );
  }
}

_HostEnvironmentState? _readState(
  Uint8List? contents,
  ActivationHost expectedHost,
) {
  if (contents == null) return null;
  try {
    final document = jsonDecode(utf8.decode(contents))! as Map<String, dynamic>;
    if (document['schemaVersion'] != 1 ||
        document['host'] != expectedHost.name) {
      throw const FormatException();
    }
    final managedKeys = (document['managedKeys']! as List<dynamic>)
        .cast<String>();
    final previous = (document['previousEnvironment']! as Map<String, dynamic>)
        .cast<String, String?>();
    if (previous.keys.toSet().difference(managedKeys.toSet()).isNotEmpty ||
        managedKeys.toSet().difference(previous.keys.toSet()).isNotEmpty) {
      throw const FormatException();
    }
    _validateNullableEnvironment(previous);
    return _HostEnvironmentState(
      host: expectedHost,
      managedKeys: List.unmodifiable(managedKeys),
      previous: Map.unmodifiable(previous),
    );
  } on Object {
    throw HostEnvironmentInstallException(
      operation: 'read',
      host: expectedHost,
      stage: 'managed state',
    );
  }
}

void _validateEnvironment(Map<String, String> environment) {
  _validateNullableEnvironment(environment);
}

void _validateNullableEnvironment(Map<String, String?> environment) {
  final namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  for (final entry in environment.entries) {
    if (!namePattern.hasMatch(entry.key)) {
      throw ArgumentError.value(
        entry.key,
        'environment key',
        'Invalid variable name',
      );
    }
    if (entry.value?.contains('\u0000') ?? false) {
      throw ArgumentError.value(
        entry.value,
        entry.key,
        'Environment value contains NUL',
      );
    }
  }
}

Uint8List _encodeText(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List _utf16LeEncode(String value) {
  final codeUnits = value.codeUnits;
  final bytes = Uint8List(codeUnits.length * 2);
  for (var index = 0; index < codeUnits.length; index++) {
    final codeUnit = codeUnits[index];
    bytes[index * 2] = codeUnit & 0xff;
    bytes[index * 2 + 1] = codeUnit >> 8;
  }
  return bytes;
}

String _renderReplayScript(Map<String, String> environment) {
  final commands = environment.entries.map(
    (entry) =>
        '/bin/launchctl setenv ${_shellQuote(entry.key)} '
        '${_shellQuote(entry.value)}',
  );
  return '#!/bin/sh\nset -eu\n${commands.join('\n')}\n';
}

String _renderLaunchAgent({
  required String label,
  required String replayScript,
}) {
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${_xmlEscape(replayScript)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _removeOneLineEnding(String value) {
  if (value.endsWith('\r\n')) return value.substring(0, value.length - 2);
  if (value.endsWith('\n')) return value.substring(0, value.length - 1);
  return value;
}

const _powerShellScript = r'''
$ErrorActionPreference = 'Stop'
try {
  $json = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:NISHI_ENVIRONMENT_PAYLOAD)
  )
  $payload = ConvertFrom-Json -InputObject $json
  $namePattern = '^[A-Za-z_][A-Za-z0-9_]*$'

  if ($payload.action -eq 'get') {
    $values = @{}
    foreach ($nameValue in $payload.names) {
      $name = [string]$nameValue
      if ($name -notmatch $namePattern) { throw 'Invalid variable name.' }
      $values[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    $output = ConvertTo-Json -Compress -InputObject @{ values = $values }
    [Console]::Out.Write(
      [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($output))
    )
    exit 0
  }

  if ($payload.action -ne 'set') { throw 'Invalid action.' }
  $previous = @{}
  foreach ($property in $payload.variables.psobject.Properties) {
    $name = [string]$property.Name
    if ($name -notmatch $namePattern) { throw 'Invalid variable name.' }
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
  }
  try {
    foreach ($property in $payload.variables.psobject.Properties) {
      $name = [string]$property.Name
      $value = if ($null -eq $property.Value) { $null } else { [string]$property.Value }
      [Environment]::SetEnvironmentVariable($name, $value, 'User')
    }
  } catch {
    foreach ($name in $previous.Keys) {
      try {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'User')
      } catch {}
    }
    throw 'Failed to update user environment.'
  }
  exit 0
} catch {
  [Console]::Error.Write('Host environment operation failed.')
  exit 1
}
''';
