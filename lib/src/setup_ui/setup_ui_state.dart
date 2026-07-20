import '../setup/setup_task.dart';

enum SetupUiPhase {
  idle,
  preparing,
  awaitingPreflight,
  running,
  cancelling,
  awaitingUser,
  failed,
  cancelled,
  completed,
}

final class SetupPreflightConfirmation {
  SetupPreflightConfirmation({
    required this.id,
    required this.title,
    required this.description,
    required Set<String> taskIds,
    this.termsUrl,
  }) : taskIds = Set.unmodifiable(taskIds);

  final String id;
  final String title;
  final String description;
  final Set<String> taskIds;
  final String? termsUrl;
}

final androidSdkLicensePreflight = SetupPreflightConfirmation(
  id: 'android-sdk-license',
  title: 'Android SDK 许可条款',
  description: '安装 Android SDK 前，需要确认接受 Google Android SDK 许可条款。',
  taskIds: {'android-sdk', 'android'},
  termsUrl: 'https://developer.android.com/studio/terms',
);

final memuraiLicensePreflight = SetupPreflightConfirmation(
  id: 'memurai-license',
  title: 'Memurai Developer Edition 许可',
  description: 'Memurai Developer Edition 仅限开发和测试，安装前需要确认接受其许可条款。',
  taskIds: {'memurai', 'redis'},
);

final class SetupUiTaskState {
  const SetupUiTaskState({
    required this.id,
    required this.label,
    required this.status,
    required this.progress,
    this.message,
    this.userActionRequest,
  });

  final String id;
  final String label;
  final SetupTaskStatus status;
  final double progress;
  final String? message;
  final Object? userActionRequest;
}

final class SetupUiState {
  const SetupUiState({
    this.phase = SetupUiPhase.idle,
    this.tasks = const [],
    this.progress = 0,
    this.errorMessage,
    this.pendingPreflight = const [],
  });

  final SetupUiPhase phase;
  final List<SetupUiTaskState> tasks;
  final double progress;
  final String? errorMessage;
  final List<SetupPreflightConfirmation> pendingPreflight;

  SetupUiState copyWith({
    SetupUiPhase? phase,
    List<SetupUiTaskState>? tasks,
    double? progress,
    String? errorMessage,
    bool clearError = false,
    List<SetupPreflightConfirmation>? pendingPreflight,
  }) {
    return SetupUiState(
      phase: phase ?? this.phase,
      tasks: List.unmodifiable(tasks ?? this.tasks),
      progress: progress ?? this.progress,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      pendingPreflight: List.unmodifiable(
        pendingPreflight ?? this.pendingPreflight,
      ),
    );
  }
}
