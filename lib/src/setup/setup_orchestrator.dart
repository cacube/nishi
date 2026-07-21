import 'dart:async';

import 'package:flutter/foundation.dart';

import 'setup_task.dart';

class SetupOrchestrator extends ChangeNotifier {
  SetupOrchestrator({
    required Iterable<SetupTaskDefinition> tasks,
    required Map<String, SetupTaskAction> actions,
  }) : _actions = Map.unmodifiable(actions),
       _states = {
         for (final task in tasks) task.id: SetupTaskState(definition: task),
       } {
    _validateGraph();
  }

  final Map<String, SetupTaskAction> _actions;
  final Map<String, SetupTaskState> _states;
  bool _cancelRequested = false;
  bool _running = false;
  SetupTaskAction? _activeAction;

  List<SetupTaskState> get tasks => List.unmodifiable(_states.values);
  bool get running => _running;
  bool get completed => _states.values
      .where((state) => !state.definition.externallyManaged)
      .every((state) => state.status == SetupTaskStatus.succeeded);

  double get progress {
    final managed = _states.values
        .where((state) => !state.definition.externallyManaged)
        .toList();
    if (managed.isEmpty) return 1;
    final total = managed.fold<double>(0, (sum, state) {
      return sum +
          switch (state.status) {
            SetupTaskStatus.succeeded => 1,
            SetupTaskStatus.running => state.progress.clamp(0, 1),
            _ => 0,
          };
    });
    return total / managed.length;
  }

  Future<void> run() async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    notifyListeners();

    try {
      while (!_cancelRequested) {
        _markBlockedTasks();
        final next = _nextRunnableTask();
        if (next == null) break;
        await _runTask(next);
      }
      if (_cancelRequested) _markPendingCancelled();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    final action = _activeAction;
    if (action is CancellableSetupTaskAction) action.cancel();
  }

  Future<void> retryFailed() async {
    if (_running) return;
    for (final entry in _states.entries) {
      if (entry.value.status
          case SetupTaskStatus.failed || SetupTaskStatus.blocked) {
        _states[entry.key] = entry.value.copyWith(
          status: SetupTaskStatus.pending,
          progress: 0,
          clearMessage: true,
          clearFailure: true,
          clearUserActionRequest: true,
        );
      }
    }
    notifyListeners();
    await run();
  }

  Future<void> resumeAfterUserAction(
    String taskId, {
    required bool verified,
    String? failureMessage,
  }) async {
    if (_running) return;
    final current = _states[taskId];
    if (current == null || current.status != SetupTaskStatus.awaitingUser) {
      throw StateError('$taskId is not waiting for user action');
    }
    _setState(
      taskId,
      current.copyWith(
        status: verified ? SetupTaskStatus.succeeded : SetupTaskStatus.failed,
        progress: verified ? 1 : current.progress,
        message: verified ? '安装已确认' : failureMessage ?? '安装未完成',
        clearUserActionRequest: true,
      ),
    );
    if (verified) {
      for (final entry in _states.entries) {
        if (entry.value.status == SetupTaskStatus.blocked) {
          _states[entry.key] = entry.value.copyWith(
            status: SetupTaskStatus.pending,
            progress: 0,
            clearMessage: true,
          );
        }
      }
      notifyListeners();
      await run();
    }
  }

  SetupTaskState? _nextRunnableTask() {
    for (final state in _states.values) {
      if (state.definition.externallyManaged ||
          state.status != SetupTaskStatus.pending) {
        continue;
      }
      final dependenciesReady = state.definition.dependencies.every(
        (id) => _states[id]!.status == SetupTaskStatus.succeeded,
      );
      if (dependenciesReady) return state;
    }
    return null;
  }

  Future<void> _runTask(SetupTaskState task) async {
    final action = _actions[task.definition.id];
    if (action == null) {
      _setState(
        task.definition.id,
        task.copyWith(status: SetupTaskStatus.failed, message: '缺少安装适配器'),
      );
      return;
    }

    _setState(
      task.definition.id,
      task.copyWith(
        status: SetupTaskStatus.running,
        progress: 0,
        clearMessage: true,
        clearFailure: true,
        clearUserActionRequest: true,
      ),
    );
    _activeAction = action;
    try {
      await action.execute((progress, message) {
        final current = _states[task.definition.id]!;
        _setState(
          task.definition.id,
          current.copyWith(progress: progress.clamp(0, 1), message: message),
        );
      });
      final current = _states[task.definition.id]!;
      _setState(
        task.definition.id,
        current.copyWith(status: SetupTaskStatus.succeeded, progress: 1),
      );
    } on SetupUserActionRequiredException catch (error) {
      final current = _states[task.definition.id]!;
      _setState(
        task.definition.id,
        current.copyWith(
          status: SetupTaskStatus.awaitingUser,
          message: error.message,
          userActionRequest: error.request,
        ),
      );
    } on Object catch (error) {
      final current = _states[task.definition.id]!;
      _setState(
        task.definition.id,
        current.copyWith(
          status: _cancelRequested
              ? SetupTaskStatus.cancelled
              : SetupTaskStatus.failed,
          message: _cancelRequested ? '已取消' : error.toString(),
          failure: _cancelRequested ? null : error,
          clearFailure: _cancelRequested,
        ),
      );
    } finally {
      _activeAction = null;
    }
  }

  void _markBlockedTasks() {
    var changed = false;
    for (final entry in _states.entries) {
      final state = entry.value;
      if (state.status != SetupTaskStatus.pending) continue;
      final failedDependency = state.definition.dependencies.any((id) {
        return switch (_states[id]!.status) {
          SetupTaskStatus.failed ||
          SetupTaskStatus.blocked ||
          SetupTaskStatus.cancelled ||
          SetupTaskStatus.awaitingUser => true,
          _ => false,
        };
      });
      if (failedDependency) {
        _states[entry.key] = state.copyWith(
          status: SetupTaskStatus.blocked,
          message: '依赖项未完成',
        );
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _markPendingCancelled() {
    for (final entry in _states.entries) {
      final state = entry.value;
      if (state.status == SetupTaskStatus.pending) {
        _states[entry.key] = state.copyWith(
          status: SetupTaskStatus.cancelled,
          message: '已取消',
        );
      }
    }
  }

  void _setState(String id, SetupTaskState state) {
    _states[id] = state;
    notifyListeners();
  }

  void _validateGraph() {
    for (final state in _states.values) {
      for (final dependency in state.definition.dependencies) {
        if (!_states.containsKey(dependency)) {
          throw ArgumentError(
            'Unknown dependency $dependency for ${state.definition.id}',
          );
        }
      }
      if (!state.definition.externallyManaged &&
          !_actions.containsKey(state.definition.id)) {
        continue;
      }
    }

    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) {
        throw ArgumentError('Setup dependency cycle at $id');
      }
      for (final dependency in _states[id]!.definition.dependencies) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
    }

    for (final id in _states.keys) {
      visit(id);
    }
  }
}
