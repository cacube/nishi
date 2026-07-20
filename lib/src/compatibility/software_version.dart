final class SoftwareVersion implements Comparable<SoftwareVersion> {
  SoftwareVersion._(this.parts, this.preRelease, this.build, this.original);

  final List<int> parts;
  final List<String> preRelease;
  final List<String> build;
  final String original;

  static SoftwareVersion? tryParse(String value) {
    final match = RegExp(
      r'^v?(\d+(?:[._]\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;

    final parts = match
        .group(1)!
        .split(RegExp(r'[._]'))
        .map(int.parse)
        .toList(growable: false);
    final preRelease = match.group(2)?.split('.') ?? const <String>[];
    final build = match.group(3)?.split('.') ?? const <String>[];
    return SoftwareVersion._(
      List.unmodifiable(parts),
      List.unmodifiable(preRelease),
      List.unmodifiable(build),
      value.trim(),
    );
  }

  factory SoftwareVersion.parse(String value) {
    return tryParse(value) ??
        (throw FormatException('Invalid software version: "$value"'));
  }

  @override
  int compareTo(SoftwareVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var index = 0; index < length; index++) {
      final left = index < parts.length ? parts[index] : 0;
      final right = index < other.parts.length ? other.parts[index] : 0;
      final comparison = left.compareTo(right);
      if (comparison != 0) return comparison;
    }

    if (preRelease.isEmpty && other.preRelease.isNotEmpty) return 1;
    if (preRelease.isNotEmpty && other.preRelease.isEmpty) return -1;
    final preReleaseComparison = _compareIdentifiers(
      preRelease,
      other.preRelease,
    );
    if (preReleaseComparison != 0) return preReleaseComparison;
    return _compareIdentifiers(build, other.build);
  }

  bool operator <(SoftwareVersion other) => compareTo(other) < 0;

  bool operator >(SoftwareVersion other) => compareTo(other) > 0;

  bool operator <=(SoftwareVersion other) => compareTo(other) <= 0;

  bool operator >=(SoftwareVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is SoftwareVersion && compareTo(other) == 0;

  @override
  int get hashCode {
    final normalized = parts.toList();
    while (normalized.length > 1 && normalized.last == 0) {
      normalized.removeLast();
    }
    return Object.hashAll([...normalized, '/', ...preRelease, '+', ...build]);
  }

  @override
  String toString() => original;
}

int _compareIdentifiers(List<String> leftParts, List<String> rightParts) {
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    if (index >= leftParts.length) return -1;
    if (index >= rightParts.length) return 1;
    final left = leftParts[index];
    final right = rightParts[index];
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    final comparison = switch ((leftNumber, rightNumber)) {
      (final int left, final int right) => left.compareTo(right),
      (final int _, null) => -1,
      (null, final int _) => 1,
      _ => left.compareTo(right),
    };
    if (comparison != 0) return comparison;
  }
  return 0;
}
