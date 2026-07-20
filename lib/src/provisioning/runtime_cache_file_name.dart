import '../runtime_manifest/runtime_manifest.dart';

String runtimeArtifactCacheFileName(
  RuntimeComponent component,
  RuntimeArtifact artifact,
) {
  final sourceName = artifact.officialUrl.pathSegments
      .where((segment) => segment.isNotEmpty)
      .lastOrNull;
  final extension = sourceName == null ? 'artifact' : _safeName(sourceName);
  return _safeName(
    '${component.id}-${component.version}-'
    '${artifact.platform.jsonValue}-${artifact.architecture.jsonValue}-$extension',
  );
}

String _safeName(String value) {
  final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (safe.isEmpty || safe == '.' || safe == '..') return 'artifact';
  return safe;
}
