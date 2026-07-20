import 'software_version.dart';

enum CompatibilityStatus { compatible, outdated, unknown }

final class CompatibilityRequirement {
  const CompatibilityRequirement({required this.minimumVersion});

  final SoftwareVersion minimumVersion;

  CompatibilityStatus evaluate(SoftwareVersion? installedVersion) {
    if (installedVersion == null) return CompatibilityStatus.unknown;
    return installedVersion >= minimumVersion
        ? CompatibilityStatus.compatible
        : CompatibilityStatus.outdated;
  }
}
