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
