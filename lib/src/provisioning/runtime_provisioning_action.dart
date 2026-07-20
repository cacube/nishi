import 'dart:io';

import '../download/download_manager.dart';
import '../install/artifact_installer.dart';
import '../runtime_manifest/runtime_manifest.dart';
import '../setup/setup_task.dart';
import '../storage/runtime_layout.dart';

typedef RuntimePostInstall =
    Future<void> Function(
      Directory activeDirectory,
      SetupProgressCallback onProgress,
    );

final class RuntimeProvisioningAction implements CancellableSetupTaskAction {
  RuntimeProvisioningAction({
    required this.component,
    required this.artifact,
    required RuntimeLayout layout,
    required DownloadManager downloads,
    required ArtifactInstaller installer,
    this.postInstall,
    this.cancelPostInstall,
  }) : _layout = layout,
       _downloads = downloads,
       _installer = installer;

  final RuntimeComponent component;
  final RuntimeArtifact artifact;
  final RuntimeLayout _layout;
  final DownloadManager _downloads;
  final ArtifactInstaller _installer;
  final RuntimePostInstall? postInstall;
  final void Function()? cancelPostInstall;
  DownloadCancellationToken? _cancellationToken;

  @override
  void cancel() {
    _cancellationToken?.cancel();
    cancelPostInstall?.call();
  }

  @override
  Future<void> execute(SetupProgressCallback onProgress) async {
    final token = DownloadCancellationToken();
    _cancellationToken = token;
    try {
      onProgress(0, '正在下载');
      final download = await _downloads.download(
        source: artifact.officialUrl,
        destinationDirectory: _layout.cache,
        fileName: _cacheFileName(),
        expectedSha256: artifact.sha256,
        cancellationToken: token,
        onProgress: (progress) {
          onProgress((progress.fraction ?? 0).clamp(0, 1) * 0.8, '正在下载');
        },
      );
      token.throwIfCancelled();
      onProgress(0.82, download.fromCache ? '使用已验证缓存' : '下载校验完成');

      final result = await _installer.install(
        component: component,
        artifact: artifact,
        artifactFile: download.file,
      );
      if (result.status == ArtifactInstallStatus.userActionRequired) {
        throw SetupUserActionRequiredException(
          message: '需要完成系统安装确认',
          request: result.installerCommand,
        );
      }
      final configure = postInstall;
      if (configure != null) {
        onProgress(0.85, '正在配置');
        await configure(result.activeDirectory!, (progress, message) {
          onProgress(0.85 + progress.clamp(0, 1) * 0.15, message);
        });
      }
      await _layout.recordActiveVersion(component.id, component.version);
      onProgress(1, '安装完成');
    } on DownloadCancelledException {
      throw StateError('下载已取消');
    } finally {
      if (identical(_cancellationToken, token)) _cancellationToken = null;
    }
  }

  String _cacheFileName() {
    final sourceName = artifact.officialUrl.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    final extension = sourceName == null ? 'artifact' : _safeName(sourceName);
    return _safeName(
      '${component.id}-${component.version}-'
      '${artifact.platform.jsonValue}-${artifact.architecture.jsonValue}-$extension',
    );
  }
}

String _safeName(String value) {
  final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (safe.isEmpty || safe == '.' || safe == '..') return 'artifact';
  return safe;
}
