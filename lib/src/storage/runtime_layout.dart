import 'dart:convert';
import 'dart:io';

enum HostOperatingSystem { windows, macos }

final class RuntimeLayout {
  RuntimeLayout._(this.root);

  final Directory root;

  Directory get cache => Directory(_join(root.path, 'cache'));
  Directory get runtimes => Directory(_join(root.path, 'runtimes'));
  Directory get data => Directory(_join(root.path, 'data'));
  Directory get logs => Directory(_join(root.path, 'logs'));
  File get activeVersions => File(_join(root.path, 'active-versions.json'));

  Directory componentVersions(String componentId) {
    _validateSegment(componentId, 'componentId');
    return Directory(_join(runtimes.path, componentId));
  }

  Directory componentVersion(String componentId, String version) {
    _validateSegment(version, 'version');
    return Directory(_join(componentVersions(componentId).path, version));
  }

  Directory componentStaging(String componentId, String version) {
    _validateSegment(version, 'version');
    return Directory('${componentVersion(componentId, version).path}.staging');
  }

  static RuntimeLayout forCurrentUser({
    Map<String, String>? environment,
    HostOperatingSystem? operatingSystem,
  }) {
    final env = environment ?? Platform.environment;
    final os =
        operatingSystem ??
        (Platform.isWindows
            ? HostOperatingSystem.windows
            : HostOperatingSystem.macos);
    final root = switch (os) {
      HostOperatingSystem.windows => _windowsRoot(env),
      HostOperatingSystem.macos => _macosRoot(env),
    };
    return RuntimeLayout._(Directory(root));
  }

  Future<void> ensureCreated() async {
    await Future.wait([
      cache.create(recursive: true),
      runtimes.create(recursive: true),
      data.create(recursive: true),
      logs.create(recursive: true),
    ]);
  }

  Future<Map<String, String>> readActiveVersions() async {
    if (!await activeVersions.exists()) return const {};
    return _decodeActiveVersions(await activeVersions.readAsString());
  }

  Map<String, String> readActiveVersionsSync() {
    if (!activeVersions.existsSync()) return const {};
    return _decodeActiveVersions(activeVersions.readAsStringSync());
  }

  Map<String, String> _decodeActiveVersions(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('active-versions.json must be an object');
    }
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      if (entry.value is! String) {
        throw FormatException(
          'active version for ${entry.key} must be a string',
        );
      }
      result[entry.key] = entry.value! as String;
    }
    return Map.unmodifiable(result);
  }

  Future<void> recordActiveVersion(String componentId, String version) async {
    _validateSegment(componentId, 'componentId');
    _validateSegment(version, 'version');
    await root.create(recursive: true);
    final versions = Map<String, String>.from(await readActiveVersions());
    versions[componentId] = version;
    final ordered = Map.fromEntries(
      versions.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
    final temporary = File('${activeVersions.path}.tmp');
    final backup = File('${activeVersions.path}.backup');
    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();
    await temporary.writeAsString('${jsonEncode(ordered)}\n', flush: true);
    final hadExisting = await activeVersions.exists();
    if (hadExisting) await activeVersions.rename(backup.path);
    try {
      await temporary.rename(activeVersions.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      if (hadExisting &&
          await backup.exists() &&
          !await activeVersions.exists()) {
        await backup.rename(activeVersions.path);
      }
      rethrow;
    }
  }

  static String _windowsRoot(Map<String, String> environment) {
    final localAppData = environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw StateError('LOCALAPPDATA is unavailable');
    }
    return _join(localAppData, 'DevEnvironmentManager');
  }

  static String _macosRoot(Map<String, String> environment) {
    final home = environment['HOME'];
    if (home == null || home.trim().isEmpty) {
      throw StateError('HOME is unavailable');
    }
    return _join(
      _join(_join(home, 'Library'), 'Application Support'),
      'DevEnvironmentManager',
    );
  }
}

String _join(String parent, String child) {
  final separator = Platform.pathSeparator;
  if (parent.endsWith('/') || parent.endsWith(r'\')) return '$parent$child';
  return '$parent$separator$child';
}

void _validateSegment(String value, String name) {
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\')) {
    throw ArgumentError.value(value, name, 'Must be a single path segment');
  }
}
