enum SetupTaskStatus {
  pending,
  running,
  awaitingUser,
  succeeded,
  failed,
  blocked,
  cancelled,
}

class SetupTaskDefinition {
  const SetupTaskDefinition({
    required this.id,
    required this.label,
    this.dependencies = const [],
    this.externallyManaged = false,
  });

  final String id;
  final String label;
  final List<String> dependencies;
  final bool externallyManaged;
}

class SetupTaskState {
  const SetupTaskState({
    required this.definition,
    this.status = SetupTaskStatus.pending,
    this.progress = 0,
    this.message,
    this.failure,
    this.userActionRequest,
  });

  final SetupTaskDefinition definition;
  final SetupTaskStatus status;
  final double progress;
  final String? message;
  final Object? failure;
  final Object? userActionRequest;

  SetupTaskState copyWith({
    SetupTaskStatus? status,
    double? progress,
    String? message,
    bool clearMessage = false,
    Object? failure,
    bool clearFailure = false,
    Object? userActionRequest,
    bool clearUserActionRequest = false,
  }) {
    return SetupTaskState(
      definition: definition,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: clearMessage ? null : message ?? this.message,
      failure: clearFailure ? null : failure ?? this.failure,
      userActionRequest: clearUserActionRequest
          ? null
          : userActionRequest ?? this.userActionRequest,
    );
  }
}

typedef SetupProgressCallback = void Function(double progress, String? message);

abstract interface class SetupTaskAction {
  Future<void> execute(SetupProgressCallback onProgress);
}

abstract interface class CancellableSetupTaskAction implements SetupTaskAction {
  void cancel();
}

final class SetupUserActionRequiredException implements Exception {
  const SetupUserActionRequiredException({required this.message, this.request});

  final String message;
  final Object? request;

  @override
  String toString() => message;
}
