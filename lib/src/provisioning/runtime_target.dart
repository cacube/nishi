import 'dart:ffi';
import 'dart:io';

import '../runtime_manifest/runtime_manifest.dart';

final class RuntimeTarget {
  const RuntimeTarget({required this.platform, required this.architecture});

  final RuntimePlatform platform;
  final RuntimeArchitecture architecture;

  factory RuntimeTarget.current() {
    final platform = Platform.isWindows
        ? RuntimePlatform.windows
        : Platform.isMacOS
        ? RuntimePlatform.macos
        : throw UnsupportedError('Only Windows and macOS are supported');
    final architecture = switch (Abi.current()) {
      Abi.macosArm64 || Abi.windowsArm64 => RuntimeArchitecture.arm64,
      Abi.macosX64 || Abi.windowsX64 => RuntimeArchitecture.x64,
      final abi => throw UnsupportedError(
        'Unsupported host architecture: $abi',
      ),
    };
    return RuntimeTarget(platform: platform, architecture: architecture);
  }

  @override
  String toString() => '${platform.jsonValue}/${architecture.jsonValue}';
}
