import 'package:flutter/foundation.dart';

import '../compatibility/software_version.dart';
import '../download/download_manager.dart';
import '../operation/runtime_operation_coordinator.dart';
import '../provisioning/provisioning_plan.dart';
import '../provisioning/runtime_target.dart';
import '../runtime_manifest/runtime_manifest.dart';
import 'update_models.dart';
import 'update_downloader.dart';

typedef UpdateManifestSource = Future<RuntimeManifest> Function();
typedef ActiveVersionsReader = Future<Map<String, String>> Function();
typedef DetectedVersionsReader = Future<Map<String, String>> Function();
typedef ActiveVersionValidator =
    Future<bool> Function(RuntimeComponent component, String version);

final class UpdateController extends ChangeNotifier {
  UpdateController({
    required UpdateManifestSource manifestSource,
    required ActiveVersionsReader readActiveVersions,
    DetectedVersionsReader? readDetectedVersions,
    ActiveVersionValidator? validateActiveVersion,
    UpdateArtifactDownloader? artifactDownloader,
    RuntimeOperationCoordinator? operations,
    RuntimeTarget? target,
    DateTime Function()? clock,
  }) : _manifestSource = manifestSource,
       _readActiveVersions = readActiveVersions,
       _readDetectedVersions = readDetectedVersions ?? _emptyVersions,
       _validateActiveVersion = validateActiveVersion,
       _artifactDownloader = artifactDownloader,
       _operations = operations,
       _target = target ?? RuntimeTarget.current(),
       _clock = clock ?? DateTime.now;

  final UpdateManifestSource _manifestSource;
  final ActiveVersionsReader _readActiveVersions;
  final DetectedVersionsReader _readDetectedVersions;
  final ActiveVersionValidator? _validateActiveVersion;
  final UpdateArtifactDownloader? _artifactDownloader;
  final RuntimeOperationCoordinator? _operations;
  final RuntimeTarget _target;
  final DateTime Function() _clock;

  UpdateState state = UpdateState();
  RuntimeManifest? _manifest;

  Future<void> check() async {
    if (state.checking || state.downloading) return;
    state = state.copyWith(checking: true, clearError: true);
    notifyListeners();
    try {
      final manifest = await _manifestSource();
      final activeVersions = await _readActiveVersions();
      final detectedVersions = await _readDetectedVersions();
      final plan = ProvisioningPlan.fromManifest(manifest, _target);
      final entries = <RuntimeUpdateEntry>[];
      for (final planEntry in plan.entries) {
        final component = planEntry.component;
        if (!component.isManaged) continue;
        var currentVersion = activeVersions[component.id];
        final validator = _validateActiveVersion;
        if (currentVersion != null &&
            validator != null &&
            !await validator(component, currentVersion)) {
          currentVersion = null;
        }
        currentVersion ??= detectedVersions[component.id];
        final status = _statusFor(currentVersion, component.version);
        entries.add(
          RuntimeUpdateEntry(
            componentId: component.id,
            displayName: component.displayName,
            currentVersion: currentVersion,
            targetVersion: component.version,
            status: status,
          ),
        );
      }
      state = state.copyWith(
        checking: false,
        entries: entries,
        lastCheckedAt: _clock(),
        clearError: true,
      );
      _manifest = manifest;
    } on Object {
      state = state.copyWith(
        checking: false,
        errorMessage: '无法检查组件更新，请检查网络后重试',
      );
    }
    notifyListeners();
  }

  Future<void> downloadAvailableUpdates({
    bool includeNotInstalled = true,
  }) async {
    final downloader = _artifactDownloader;
    final manifest = _manifest;
    final componentIds = state.availableUpdates
        .where(
          (entry) =>
              includeNotInstalled ||
              entry.status == RuntimeUpdateStatus.updateAvailable,
        )
        .map((entry) => entry.componentId)
        .toSet();
    if (downloader == null ||
        manifest == null ||
        componentIds.isEmpty ||
        state.checking ||
        state.downloading) {
      return;
    }
    final operation = _operations?.tryAcquire('download-updates');
    if (_operations != null && operation == null) {
      state = state.copyWith(
        downloadErrorMessage: '另一项环境操作正在进行，请稍后重试',
        downloadCancelled: false,
      );
      notifyListeners();
      return;
    }
    state = state.copyWith(
      downloading: true,
      downloadProgress: 0,
      clearDownloadError: true,
      downloadCancelled: false,
    );
    notifyListeners();
    try {
      await downloader.download(
        manifest: manifest,
        componentIds: componentIds,
        onProgress: (progress) {
          state = state.copyWith(downloadProgress: progress.clamp(0, 1));
          notifyListeners();
        },
      );
      state = state.copyWith(
        downloading: false,
        downloadProgress: 1,
        downloadCancelled: false,
      );
    } on DownloadCancelledException {
      state = state.copyWith(
        downloading: false,
        clearDownloadError: true,
        downloadCancelled: true,
      );
    } on Object {
      state = state.copyWith(
        downloading: false,
        downloadErrorMessage: '更新包下载失败，请重试',
        downloadCancelled: false,
      );
    } finally {
      operation?.release();
    }
    notifyListeners();
  }

  void cancelDownload() {
    if (!state.downloading) return;
    _artifactDownloader?.cancel();
  }

  RuntimeUpdateStatus _statusFor(String? current, String target) {
    if (current == null) return RuntimeUpdateStatus.notInstalled;
    final currentVersion = SoftwareVersion.tryParse(current);
    final targetVersion = SoftwareVersion.tryParse(target);
    if (currentVersion == null || targetVersion == null) {
      return current == target
          ? RuntimeUpdateStatus.current
          : RuntimeUpdateStatus.updateAvailable;
    }
    final comparison = currentVersion.compareTo(targetVersion);
    if (comparison == 0) return RuntimeUpdateStatus.current;
    if (comparison > 0) return RuntimeUpdateStatus.newerThanTarget;
    return RuntimeUpdateStatus.updateAvailable;
  }
}

Future<Map<String, String>> _emptyVersions() async => const {};
