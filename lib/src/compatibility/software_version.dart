final class SoftwareVersion implements Comparable<SoftwareVersion> {
  SoftwareVersion._(this.parts, this.preRelease, this.original);

  final List<int> parts;
  final List<String> preRelease;
  final String original;

  static SoftwareVersion? tryParse(String value) {
    final match = RegExp(
      r'^v?(\d+(?:[._]\d+)*)(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;

    final parts = match
        .group(1)!
        .split(RegExp(r'[._]'))
        .map(int.parse)
        .toList(growable: false);
    final preRelease = match.group(2)?.split('.') ?? const <String>[];
    return SoftwareVersion._(
      List.unmodifiable(parts),
      List.unmodifiable(preRelease),
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

    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final preReleaseLength = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var index = 0; index < preReleaseLength; index++) {
      if (index >= preRelease.length) return -1;
      if (index >= other.preRelease.length) return 1;

      final left = preRelease[index];
      final right = other.preRelease[index];
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
    return Object.hashAll([...normalized, '/', ...preRelease]);
  }

  @override
  String toString() => original;
}
