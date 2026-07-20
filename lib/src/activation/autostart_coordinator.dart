import 'dart:typed_data';

import 'activation_boundaries.dart';
import 'autostart_plans.dart';

enum AutoStartOperation { enable, update, disable, uninstall }

final class AutoStartOperationResult {
  const AutoStartOperationResult({
    required this.planId,
    required this.operation,
    required this.executedCommands,
  });

  final String planId;
  final AutoStartOperation operation;
  final int executedCommands;
}

final class AutoStartCommandException implements Exception {
  const AutoStartCommandException(this.command, this.result);

  final ActivationCommand command;
  final ActivationCommandResult result;

  @override
  String toString() {
    return 'Auto-start command failed (${result.exitCode}): '
        '${command.executable} ${command.arguments.join(' ')}\n${result.stderr}';
  }
}

final class AutoStartCoordinator {
  AutoStartCoordinator({
    required ActivationFileStore files,
    required ActivationProcessRunner processes,
  }) : _files = files,
       _processes = processes;

  final ActivationFileStore _files;
  final ActivationProcessRunner _processes;

  Future<AutoStartOperationResult> enable(AutoStartPlan plan) {
    return _applyWithArtifacts(
      plan,
      AutoStartOperation.enable,
      plan.enableCommands,
    );
  }

  Future<AutoStartOperationResult> update(AutoStartPlan plan) {
    return _applyWithArtifacts(
      plan,
      AutoStartOperation.update,
      plan.updateCommands,
    );
  }

  Future<AutoStartOperationResult> disable(AutoStartPlan plan) {
    return _execute(plan, AutoStartOperation.disable, plan.disableCommands);
  }

  Future<AutoStartOperationResult> uninstall(AutoStartPlan plan) async {
    final result = await _execute(
      plan,
      AutoStartOperation.uninstall,
      plan.uninstallCommands,
    );
    for (final artifact in plan.artifacts.reversed) {
      await _files.delete(artifact.path);
    }
    return result;
  }

  Future<AutoStartOperationResult> _applyWithArtifacts(
    AutoStartPlan plan,
    AutoStartOperation operation,
    List<ActivationCommand> commands,
  ) async {
    final previous = <String, Uint8List?>{};
    try {
      for (final artifact in plan.artifacts) {
        previous[artifact.path] = await _files.read(artifact.path);
        await _files.writeAtomically(artifact.path, artifact.contents);
      }
      return await _execute(plan, operation, commands);
    } on Object {
      for (final entry in previous.entries) {
        if (entry.value == null) {
          await _files.delete(entry.key);
        } else {
          await _files.writeAtomically(entry.key, entry.value!);
        }
      }
      rethrow;
    }
  }

  Future<AutoStartOperationResult> _execute(
    AutoStartPlan plan,
    AutoStartOperation operation,
    List<ActivationCommand> commands,
  ) async {
    var executed = 0;
    for (final command in commands) {
      final result = await _processes.run(command);
      if (!command.acceptedExitCodes.contains(result.exitCode)) {
        throw AutoStartCommandException(command, result);
      }
      executed++;
    }
    return AutoStartOperationResult(
      planId: plan.id,
      operation: operation,
      executedCommands: executed,
    );
  }
}
