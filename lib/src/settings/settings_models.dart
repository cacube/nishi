enum DownloadSourcePreference { automatic, officialOnly, mirrorFirst }

final class AppSettings {
  const AppSettings({
    this.autoCheckUpdates = true,
    this.autoDownloadUpdates = false,
    this.downloadSourcePreference = DownloadSourcePreference.automatic,
  });

  final bool autoCheckUpdates;
  final bool autoDownloadUpdates;
  final DownloadSourcePreference downloadSourcePreference;

  AppSettings copyWith({
    bool? autoCheckUpdates,
    bool? autoDownloadUpdates,
    DownloadSourcePreference? downloadSourcePreference,
  }) {
    return AppSettings(
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      autoDownloadUpdates: autoDownloadUpdates ?? this.autoDownloadUpdates,
      downloadSourcePreference:
          downloadSourcePreference ?? this.downloadSourcePreference,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'autoCheckUpdates': autoCheckUpdates,
    'autoDownloadUpdates': autoDownloadUpdates,
    'downloadSourcePreference': downloadSourcePreference.name,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported settings schema version');
    }
    final autoCheckUpdates = json['autoCheckUpdates'];
    final autoDownloadUpdates = json['autoDownloadUpdates'];
    final sourcePreference = json['downloadSourcePreference'];
    if (autoCheckUpdates is! bool ||
        autoDownloadUpdates is! bool ||
        sourcePreference is! String) {
      throw const FormatException('Settings contain invalid field types');
    }
    final preferences = DownloadSourcePreference.values.where(
      (value) => value.name == sourcePreference,
    );
    if (preferences.isEmpty) {
      throw FormatException(
        'Unsupported download source preference: $sourcePreference',
      );
    }
    return AppSettings(
      autoCheckUpdates: autoCheckUpdates,
      autoDownloadUpdates: autoDownloadUpdates,
      downloadSourcePreference: preferences.single,
    );
  }
}
