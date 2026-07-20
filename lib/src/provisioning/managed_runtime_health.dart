import 'dart:io';

import '../runtime_manifest/runtime_manifest.dart';
import '../storage/runtime_layout.dart';
import 'runtime_target.dart';

Future<bool> managedRuntimeIsUsable({
  required RuntimeLayout layout,
  required RuntimeComponent component,
  required String version,
  required RuntimeTarget target,
}) async {
  final root = layout.componentVersion(component.id, version);
  if (!await root.exists()) return false;
  final executables = component.executables.where(
    (executable) =>
        executable.platform == target.platform &&
        executable.architectures.contains(target.architecture),
  );
  if (executables.isEmpty) return false;
  for (final executable in executables) {
    final relativePath = executable.path.replaceAll(
      RegExp(r'[/\\]+'),
      Platform.pathSeparator,
    );
    if (!await File(
      '${root.path}${Platform.pathSeparator}$relativePath',
    ).exists()) {
      return false;
    }
  }
  return true;
}
