import 'package:flutter/foundation.dart';

import '../download/download_manager.dart';
import '../provisioning/provisioning_plan.dart';
import '../provisioning/runtime_cache_file_name.dart';
import '../provisioning/runtime_target.dart';
import '../runtime_manifest/runtime_manifest.dart';
import '../storage/runtime_layout.dart';

abstract interface class UpdateArtifactDownloader {
  Future<void> download({
    required RuntimeManifest manifest,
    required Set<String> componentIds,
    required ValueChanged<double> onProgress,
  });

  void cancel();
}

final class RuntimeUpdateDownloader implements UpdateArtifactDownloader {
  RuntimeUpdateDownloader({
    required RuntimeLayout layout,
    required DownloadManager downloads,
    required Future<Map<String, String>> Function() readActiveVersions,
    RuntimeTarget? target,
  }) : _layout = layout,
       _downloads = downloads,
       _readActiveVersions = readActiveVersions,
       _target = target ?? RuntimeTarget.current();

  final RuntimeLayout _layout;
  final DownloadManager _downloads;
  final Future<Map<String, String>> Function() _readActiveVersions;
  final RuntimeTarget _target;
  DownloadCancellationToken? _cancellationToken;

  @override
  void cancel() => _cancellationToken?.cancel();

  @override
  Future<void> download({
    required RuntimeManifest manifest,
    required Set<String> componentIds,
    required ValueChanged<double> onProgress,
  }) async {
    final token = DownloadCancellationToken();
    _cancellationToken = token;
    try {
      await _layout.ensureCreated();
      final activeVersions = await _readActiveVersions();
      final plan = ProvisioningPlan.fromManifest(
        manifest,
        _target,
        componentIds: componentIds,
      );
      final entries = plan.entries
          .where(
            (entry) =>
                entry.artifact != null &&
                activeVersions[entry.component.id] != entry.component.version,
          )
          .toList(growable: false);
      if (entries.isEmpty) {
        onProgress(1);
        return;
      }
      for (var index = 0; index < entries.length; index++) {
        token.throwIfCancelled();
        final entry = entries[index];
        final artifact = entry.artifact!;
        await _downloads.downloadFromSources(
          sources: artifact.downloadUrls,
          destinationDirectory: _layout.cache,
          fileName: runtimeArtifactCacheFileName(entry.component, artifact),
          expectedSha256: artifact.sha256,
          cancellationToken: token,
          onProgress: (progress) {
            final componentProgress = progress.fraction ?? 0;
            onProgress((index + componentProgress) / entries.length);
          },
        );
      }
      onProgress(1);
    } finally {
      if (identical(_cancellationToken, token)) _cancellationToken = null;
    }
  }
}
