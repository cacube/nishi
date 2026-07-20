enum RuntimeUpdateStatus {
  current,
  updateAvailable,
  notInstalled,
  newerThanTarget,
}

final class RuntimeUpdateEntry {
  const RuntimeUpdateEntry({
    required this.componentId,
    required this.displayName,
    required this.currentVersion,
    required this.targetVersion,
    required this.status,
  });

  final String componentId;
  final String displayName;
  final String? currentVersion;
  final String targetVersion;
  final RuntimeUpdateStatus status;
}

final class UpdateState {
  UpdateState({
    this.checking = false,
    List<RuntimeUpdateEntry> entries = const [],
    this.lastCheckedAt,
    this.errorMessage,
    this.downloading = false,
    this.downloadProgress = 0,
    this.downloadErrorMessage,
    this.downloadCancelled = false,
  }) : entries = List.unmodifiable(entries);

  final bool checking;
  final List<RuntimeUpdateEntry> entries;
  final DateTime? lastCheckedAt;
  final String? errorMessage;
  final bool downloading;
  final double downloadProgress;
  final String? downloadErrorMessage;
  final bool downloadCancelled;

  UpdateState copyWith({
    bool? checking,
    List<RuntimeUpdateEntry>? entries,
    DateTime? lastCheckedAt,
    String? errorMessage,
    bool clearError = false,
    bool? downloading,
    double? downloadProgress,
    String? downloadErrorMessage,
    bool clearDownloadError = false,
    bool? downloadCancelled,
  }) {
    return UpdateState(
      checking: checking ?? this.checking,
      entries: entries ?? this.entries,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      downloading: downloading ?? this.downloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadErrorMessage: clearDownloadError
          ? null
          : downloadErrorMessage ?? this.downloadErrorMessage,
      downloadCancelled: downloadCancelled ?? this.downloadCancelled,
    );
  }

  List<RuntimeUpdateEntry> get availableUpdates => entries
      .where(
        (entry) =>
            entry.status == RuntimeUpdateStatus.updateAvailable ||
            entry.status == RuntimeUpdateStatus.notInstalled,
      )
      .toList(growable: false);

  RuntimeUpdateEntry? entryById(String componentId) {
    for (final entry in entries) {
      if (entry.componentId == componentId) return entry;
    }
    return null;
  }
}
