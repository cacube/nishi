import 'software_version.dart';

enum SoftwareComponent {
  flutter,
  java,
  go,
  node,
  npm,
  mysql,
  redis,
  git,
  xcode,
}

final class VersionOutputParser {
  const VersionOutputParser();

  SoftwareVersion? extract(SoftwareComponent component, String output) {
    final candidates = switch (component) {
      SoftwareComponent.flutter => [
        RegExp(r'Flutter\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)', caseSensitive: false),
      ],
      SoftwareComponent.java => [
        RegExp(
          r'(?:openjdk|java)\s+version\s+"(\d+(?:[._]\d+)*(?:-[\w.-]+)?)"',
          caseSensitive: false,
        ),
        RegExp(
          r'openjdk\s+(\d+(?:[._]\d+)*(?:-[\w.-]+)?)',
          caseSensitive: false,
        ),
      ],
      SoftwareComponent.go => [
        RegExp(
          r'\bgo(?:\s+version\s+)?go(\d+(?:\.\d+)+(?:-[\w.-]+)?)\b',
          caseSensitive: false,
        ),
      ],
      SoftwareComponent.node => [
        RegExp(r'^\s*v(\d+(?:\.\d+)+(?:-[\w.-]+)?)\s*$', multiLine: true),
      ],
      SoftwareComponent.npm => [
        RegExp(r'^\s*(\d+(?:\.\d+)+(?:-[\w.-]+)?)\s*$', multiLine: true),
      ],
      SoftwareComponent.mysql => [
        RegExp(
          r'\bDistrib\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)',
          caseSensitive: false,
        ),
        RegExp(r'\bVer\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)', caseSensitive: false),
        RegExp(r'\bmysql\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)', caseSensitive: false),
      ],
      SoftwareComponent.redis => [
        RegExp(r'\bv=(\d+(?:\.\d+)+(?:-[\w.-]+)?)', caseSensitive: false),
        RegExp(
          r'\bredis(?:-server| server)?\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)',
          caseSensitive: false,
        ),
      ],
      SoftwareComponent.git => [
        RegExp(
          r'git\s+version\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)',
          caseSensitive: false,
        ),
      ],
      SoftwareComponent.xcode => [
        RegExp(
          r'^\s*Xcode\s+(\d+(?:\.\d+)+(?:-[\w.-]+)?)',
          caseSensitive: false,
          multiLine: true,
        ),
      ],
    };

    for (final pattern in candidates) {
      final value = pattern.firstMatch(output)?.group(1);
      if (value == null) continue;
      final parsed = SoftwareVersion.tryParse(value);
      if (parsed != null) return parsed;
    }
    return null;
  }
}
