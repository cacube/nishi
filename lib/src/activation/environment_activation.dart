import 'dart:convert';
import 'dart:typed_data';

import 'activation_boundaries.dart';

enum ActivationHost { macos, windows }

final class ToolchainEnvironment {
  ToolchainEnvironment({
    required this.host,
    required this.managerRoot,
    required this.javaHome,
    required this.androidSdkRoot,
    required this.flutterRoot,
    required this.goRoot,
    required this.nodeRoot,
    required this.mysqlRoot,
    required this.redisRoot,
    this.inheritedPath,
    this.additionalVariables = const {},
    this.additionalPathEntries = const [],
  }) {
    for (final entry in additionalVariables.entries) {
      _validateEnvironmentEntry(entry.key, entry.value);
    }
  }

  final ActivationHost host;
  final String managerRoot;
  final String javaHome;
  final String androidSdkRoot;
  final String flutterRoot;
  final String goRoot;
  final String nodeRoot;
  final String mysqlRoot;
  final String redisRoot;
  final String? inheritedPath;
  final Map<String, String> additionalVariables;
  final List<String> additionalPathEntries;

  String get pathSeparator => host == ActivationHost.windows ? ';' : ':';

  Map<String, String> toEnvironment() {
    final bin = host == ActivationHost.windows ? r'bin' : 'bin';
    final pathEntries = <String>[
      _join(flutterRoot, bin),
      _join(javaHome, bin),
      _join(androidSdkRoot, 'platform-tools'),
      _join(androidSdkRoot, _join('cmdline-tools', _join('latest', bin))),
      _join(goRoot, bin),
      host == ActivationHost.windows ? nodeRoot : _join(nodeRoot, bin),
      _join(mysqlRoot, bin),
      redisRoot,
      ...additionalPathEntries,
      ...?((inheritedPath?.trim().isNotEmpty ?? false)
          ? <String>[inheritedPath!]
          : null),
    ];
    final environment = <String, String>{
      'DEV_ENVIRONMENT_MANAGER_ROOT': managerRoot,
      'JAVA_HOME': javaHome,
      'ANDROID_SDK_ROOT': androidSdkRoot,
      'ANDROID_HOME': androidSdkRoot,
      'FLUTTER_ROOT': flutterRoot,
      'GOROOT': goRoot,
      'NODE_HOME': nodeRoot,
      'MYSQL_HOME': mysqlRoot,
      'REDIS_HOME': redisRoot,
      ...additionalVariables,
      'PATH': pathEntries.join(pathSeparator),
    };
    for (final entry in environment.entries) {
      _validateEnvironmentEntry(entry.key, entry.value);
    }
    return Map.unmodifiable(environment);
  }

  String _join(String parent, String child) {
    final separator = host == ActivationHost.windows ? r'\' : '/';
    if (parent.endsWith('/') || parent.endsWith(r'\')) return '$parent$child';
    return '$parent$separator$child';
  }
}

final class EnvironmentActivationPaths {
  const EnvironmentActivationPaths({
    required this.managedEnvironment,
    required this.launcherEnvironment,
  });

  final String managedEnvironment;
  final String launcherEnvironment;
}

final class EnvironmentActivationReceipt {
  EnvironmentActivationReceipt._({
    required ActivationFileStore files,
    required Map<String, Uint8List?> previousContents,
  }) : _files = files,
       _previousContents = previousContents;

  final ActivationFileStore _files;
  final Map<String, Uint8List?> _previousContents;
  bool _rolledBack = false;

  Future<void> rollback() async {
    if (_rolledBack) return;
    for (final entry in _previousContents.entries) {
      final previous = entry.value;
      if (previous == null) {
        await _files.delete(entry.key);
      } else {
        await _files.writeAtomically(entry.key, previous);
      }
    }
    _rolledBack = true;
  }
}

final class EnvironmentActivator {
  EnvironmentActivator({required ActivationFileStore files}) : _files = files;

  final ActivationFileStore _files;

  Future<EnvironmentActivationReceipt> activate({
    required EnvironmentActivationPaths paths,
    required ToolchainEnvironment toolchain,
  }) async {
    final environment = toolchain.toEnvironment();
    final managed = _encodeDocument(
      kind: 'managed-environment',
      host: toolchain.host,
      environment: environment,
    );
    final launcher = _encodeDocument(
      kind: 'launcher-environment',
      host: toolchain.host,
      environment: environment,
    );
    final previous = <String, Uint8List?>{
      paths.managedEnvironment: await _files.read(paths.managedEnvironment),
      paths.launcherEnvironment: await _files.read(paths.launcherEnvironment),
    };
    final receipt = EnvironmentActivationReceipt._(
      files: _files,
      previousContents: previous,
    );
    try {
      await _files.writeAtomically(paths.managedEnvironment, managed);
      await _files.writeAtomically(paths.launcherEnvironment, launcher);
      return receipt;
    } on Object {
      await receipt.rollback();
      rethrow;
    }
  }

  Future<void> uninstall(EnvironmentActivationPaths paths) async {
    await _files.delete(paths.launcherEnvironment);
    await _files.delete(paths.managedEnvironment);
  }

  Uint8List _encodeDocument({
    required String kind,
    required ActivationHost host,
    required Map<String, String> environment,
  }) {
    final document = <String, Object>{
      'schemaVersion': 1,
      'kind': kind,
      'host': host.name,
      'environment': environment,
    };
    return Uint8List.fromList(utf8.encode('${jsonEncode(document)}\n'));
  }
}

void _validateEnvironmentEntry(String key, String value) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
    throw ArgumentError.value(key, 'environment key', 'Invalid variable name');
  }
  if (value.contains('\u0000')) {
    throw ArgumentError.value(value, key, 'Environment value contains NUL');
  }
}
