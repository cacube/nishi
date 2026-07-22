import 'dart:io';

import 'package:flutter/foundation.dart';

import '../activation/autostart_coordinator.dart';
import '../download/download_manager.dart';
import '../environment/environment_controller.dart';
import '../install/artifact_installer.dart';
import '../manifest_security/remote_manifest_exceptions.dart';
import '../manifest_security/remote_manifest_release_configuration.dart';
import '../mysql/mysql_configurator.dart';
import '../mysql/mysql_service_readiness.dart';
import '../operation/runtime_operation_coordinator.dart';
import '../provisioning/provisioning_plan.dart';
import '../provisioning/provisioning_workflow.dart';
import '../runtime_manifest/runtime_manifest_validator.dart';
import '../setup/setup_orchestrator.dart';
import '../setup/setup_task.dart';
import 'setup_ui_state.dart';

export 'setup_ui_state.dart';

typedef SetupOrchestratorPreparer = Future<SetupOrchestrator> Function();
typedef SetupSelectionPreparer =
    Future<SetupOrchestrator> Function(Set<String> componentIds);
typedef EnvironmentRescan = Future<void> Function();
typedef PreflightAccepted = void Function(Set<String> acceptedIds);

final class SetupUiController extends ChangeNotifier {
  SetupUiController({
    required SetupOrchestratorPreparer prepare,
    SetupSelectionPreparer? prepareSelection,
    required EnvironmentRescan rescanEnvironment,
    List<SetupPreflightConfirmation> preflightConfirmations = const [],
    PreflightAccepted? onPreflightAccepted,
    RuntimeOperationCoordinator? operations,
  }) : _prepare = prepare,
       _prepareSelection = prepareSelection,
       _rescanEnvironment = rescanEnvironment,
       _preflightConfirmations = List.unmodifiable(preflightConfirmations),
       _onPreflightAccepted = onPreflightAccepted,
       _operations = operations;

  factory SetupUiController.forRemoteRelease({
    required ProvisioningWorkflow workflow,
    required RemoteManifestReleaseConfiguration releaseConfiguration,
    required EnvironmentController environmentController,
    required List<SetupPreflightConfirmation> preflightConfirmations,
    PreflightAccepted? onPreflightAccepted,
    RuntimeManifestSource? manifestSourceOverride,
    RuntimeOperationCoordinator? operations,
  }) {
    final RuntimeManifestSource manifestSource;
    if (manifestSourceOverride != null) {
      manifestSource = manifestSourceOverride;
    } else {
      manifestSource = () async {
        final loader = releaseConfiguration.createLoader();
        try {
          return await loader.load(
            manifestUri: releaseConfiguration.manifestUri,
            signatureUri: releaseConfiguration.signatureUri,
          );
        } finally {
          loader.close();
        }
      };
    }
    return SetupUiController(
      prepare: () => workflow.prepare(manifestSource),
      prepareSelection: (componentIds) =>
          workflow.prepare(manifestSource, componentIds: componentIds),
      rescanEnvironment: environmentController.scan,
      preflightConfirmations: preflightConfirmations,
      onPreflightAccepted: onPreflightAccepted,
      operations: operations,
    );
  }

  final SetupOrchestratorPreparer _prepare;
  final SetupSelectionPreparer? _prepareSelection;
  final EnvironmentRescan _rescanEnvironment;
  final List<SetupPreflightConfirmation> _preflightConfirmations;
  final PreflightAccepted? _onPreflightAccepted;
  final RuntimeOperationCoordinator? _operations;
  RuntimeOperationLease? _operationLease;
  SetupOrchestrator? _orchestrator;
  SetupOrchestratorPreparer? _lastPrepare;
  bool _cancelRequested = false;

  SetupUiState state = const SetupUiState();

  void cancel() {
    if (!_canCancel) return;
    _cancelRequested = true;
    state = state.copyWith(phase: SetupUiPhase.cancelling);
    notifyListeners();
    final orchestrator = _orchestrator;
    if (orchestrator?.running ?? false) {
      orchestrator!.cancel();
    } else if (state.phase == SetupUiPhase.cancelling &&
        state.tasks.isNotEmpty) {
      state = state.copyWith(phase: SetupUiPhase.cancelled);
      notifyListeners();
    }
    _releaseOperationIfTerminal();
  }

  Future<void> retry() async {
    if (state.phase != SetupUiPhase.failed) return;
    if (_orchestrator == null) {
      await _startWith(_lastPrepare ?? _prepare);
    } else {
      await retryFailed();
    }
  }

  Future<void> retryFailed() async {
    if (state.phase != SetupUiPhase.failed) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    if (!_beginOperation()) return;
    state = state.copyWith(phase: SetupUiPhase.running, clearError: true);
    notifyListeners();
    await orchestrator.retryFailed();
    _syncFromOrchestrator();
    if (orchestrator.completed) {
      await _rescanEnvironment();
    }
  }

  Future<void> continueAfterUserAction(String taskId) async {
    if (state.phase != SetupUiPhase.awaitingUser) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    state = state.copyWith(phase: SetupUiPhase.running, clearError: true);
    notifyListeners();
    await orchestrator.resumeAfterUserAction(taskId, verified: true);
    _syncFromOrchestrator();
    if (orchestrator.completed) {
      await _rescanEnvironment();
    }
  }

  Future<void> start() async {
    await _startWith(_prepare);
  }

  Future<void> startSelected(Set<String> componentIds) async {
    if (componentIds.isEmpty) return;
    final prepareSelection = _prepareSelection;
    if (prepareSelection == null) {
      throw StateError('Selected component updates are unavailable');
    }
    final selected = Set<String>.unmodifiable(componentIds);
    await _startWith(() => prepareSelection(selected));
  }

  Future<void> _startWith(SetupOrchestratorPreparer prepare) async {
    if (!_canStart) return;
    if (!_beginOperation()) return;
    _lastPrepare = prepare;
    _clearOrchestrator();
    _cancelRequested = false;
    state = const SetupUiState(phase: SetupUiPhase.preparing);
    notifyListeners();
    try {
      final orchestrator = await prepare();
      if (_cancelRequested) {
        state = state.copyWith(
          phase: SetupUiPhase.cancelled,
          tasks: orchestrator.tasks.map(_mapTask).toList(growable: false),
          pendingPreflight: const [],
          clearError: true,
        );
        notifyListeners();
        _releaseOperationIfTerminal();
        return;
      }
      _orchestrator = orchestrator;
      orchestrator.addListener(_syncFromOrchestrator);
      final taskIds = orchestrator.tasks
          .map((task) => task.definition.id)
          .toSet();
      final pendingPreflight = _preflightConfirmations
          .where((confirmation) => confirmation.taskIds.any(taskIds.contains))
          .toList(growable: false);
      if (pendingPreflight.isNotEmpty) {
        state = state.copyWith(
          phase: SetupUiPhase.awaitingPreflight,
          tasks: orchestrator.tasks.map(_mapTask).toList(growable: false),
          progress: orchestrator.progress,
          pendingPreflight: pendingPreflight,
          clearError: true,
        );
        notifyListeners();
        return;
      }
      state = state.copyWith(
        phase: SetupUiPhase.running,
        tasks: orchestrator.tasks.map(_mapTask).toList(growable: false),
        progress: orchestrator.progress,
        clearError: true,
      );
      notifyListeners();
      await orchestrator.run();
      _syncFromOrchestrator();
      if (orchestrator.completed) {
        await _rescanEnvironment();
      }
    } on Object catch (error) {
      if (_cancelRequested) {
        state = state.copyWith(phase: SetupUiPhase.cancelled, clearError: true);
        notifyListeners();
        _releaseOperationIfTerminal();
        return;
      }
      state = state.copyWith(
        phase: SetupUiPhase.failed,
        errorMessage: _displayError(error),
      );
      notifyListeners();
      _releaseOperationIfTerminal();
    }
  }

  Future<void> confirmPreflight(Set<String> acceptedIds) async {
    if (state.phase != SetupUiPhase.awaitingPreflight) return;
    final requiredIds = state.pendingPreflight
        .map((confirmation) => confirmation.id)
        .toSet();
    if (!acceptedIds.containsAll(requiredIds)) {
      state = state.copyWith(errorMessage: '请先同意全部必需的许可条款。');
      notifyListeners();
      return;
    }
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    _onPreflightAccepted?.call(Set.unmodifiable(acceptedIds));
    state = state.copyWith(
      phase: SetupUiPhase.running,
      pendingPreflight: const [],
      clearError: true,
    );
    notifyListeners();
    _releaseOperationIfTerminal();
    await orchestrator.run();
    _syncFromOrchestrator();
    if (orchestrator.completed) {
      await _rescanEnvironment();
    }
  }

  String _displayError(Object error) {
    return switch (error) {
      RemoteManifestTimeoutException() ||
      RemoteManifestNetworkException() ||
      RemoteManifestHttpException() => '无法获取安装清单，请检查网络后重试。',
      InsecureManifestUriException() ||
      RemoteManifestResponseTooLargeException() ||
      InvalidManifestSignatureEnvelopeException() ||
      UnknownManifestSigningKeyException() ||
      InvalidManifestSignatureException() ||
      InvalidManifestEncodingException() => '安装清单安全验证失败，请联系维护人员。',
      RemoteManifestReleaseConfigurationException() => '在线安装源尚未配置，请联系维护人员。',
      RuntimeManifestValidationException() ||
      ProvisioningPlanException() => '安装清单内容不受支持，请联系维护人员。',
      _ => '配置准备失败，请重试；若问题持续，请联系维护人员。',
    };
  }

  bool get _isBusy => switch (state.phase) {
    SetupUiPhase.preparing ||
    SetupUiPhase.running ||
    SetupUiPhase.cancelling => true,
    _ => false,
  };

  bool get _canStart => switch (state.phase) {
    SetupUiPhase.idle ||
    SetupUiPhase.failed ||
    SetupUiPhase.cancelled ||
    SetupUiPhase.completed => true,
    _ => false,
  };

  bool get _canCancel =>
      _isBusy ||
      state.phase == SetupUiPhase.awaitingPreflight ||
      state.phase == SetupUiPhase.awaitingUser;

  void _syncFromOrchestrator() {
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    final phase = orchestrator.running
        ? state.phase == SetupUiPhase.cancelling
              ? SetupUiPhase.cancelling
              : SetupUiPhase.running
        : _phaseAfterRun(orchestrator);
    state = state.copyWith(
      phase: phase,
      tasks: orchestrator.tasks.map(_mapTask).toList(growable: false),
      progress: orchestrator.progress,
      errorMessage: phase == SetupUiPhase.failed
          ? '部分组件安装失败；不受影响的组件已继续配置。'
          : null,
      clearError: phase != SetupUiPhase.failed,
    );
    notifyListeners();
    _releaseOperationIfTerminal();
  }

  SetupUiPhase _phaseAfterRun(SetupOrchestrator orchestrator) {
    if (orchestrator.completed) return SetupUiPhase.completed;
    if (orchestrator.tasks.any(
      (task) => task.status == SetupTaskStatus.awaitingUser,
    )) {
      return SetupUiPhase.awaitingUser;
    }
    if (orchestrator.tasks.any(
      (task) => task.status == SetupTaskStatus.cancelled,
    )) {
      return SetupUiPhase.cancelled;
    }
    if (orchestrator.tasks.any(
      (task) =>
          task.status == SetupTaskStatus.failed ||
          task.status == SetupTaskStatus.blocked,
    )) {
      return SetupUiPhase.failed;
    }
    return SetupUiPhase.idle;
  }

  SetupUiTaskState _mapTask(SetupTaskState task) {
    return SetupUiTaskState(
      id: task.definition.id,
      label: task.definition.label,
      status: task.status,
      progress: task.progress,
      message: switch (task.status) {
        SetupTaskStatus.failed => _displayTaskFailure(task),
        SetupTaskStatus.blocked => '等待依赖项完成。',
        SetupTaskStatus.cancelled => '已取消',
        _ => task.message,
      },
      userActionRequest: task.userActionRequest,
    );
  }

  String _displayTaskFailure(SetupTaskState task) {
    final failure = task.failure;
    return switch (failure) {
      MySqlInitializationException(
        exitCode: final exitCode,
        details: final details,
      ) =>
        _mysqlInitializationFailure(exitCode, details),
      DownloadTimeoutException() || DownloadSourcesExhaustedException()
          when task.definition.id == 'mysql' =>
        'MySQL 下载失败，请检查网络或切换下载源后重试。',
      DownloadIntegrityException() when task.definition.id == 'mysql' =>
        'MySQL 下载文件校验失败，已拒绝安装；请重新下载。',
      ArtifactInstallException() when task.definition.id == 'mysql' =>
        'MySQL 安装文件无法解压或内容不完整，请重新下载。',
      AutoStartCommandException() when task.definition.id == 'mysql' =>
        'MySQL 已完成初始化，但自动启动失败，请重试。',
      MySqlServiceStartException(:final message) => message,
      ProcessException() when task.definition.id == 'mysql' =>
        Platform.isWindows
            ? 'MySQL 程序无法启动，请确认 Windows 安全软件未拦截后重试。'
            : 'MySQL 程序无法启动，请重试。',
      _ when task.definition.id == 'mysql' => 'MySQL 安装失败，请重试；若仍失败，请查看该项显示的错误。',
      _ => '安装失败，请重试。',
    };
  }

  String _mysqlInitializationFailure(int exitCode, String details) {
    if (Platform.isWindows &&
        (exitCode == -1073741515 || exitCode == 3221225781)) {
      return 'MySQL 无法启动：Windows 缺少 Microsoft VC++ 运行库。';
    }
    final normalized = details.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return 'MySQL 初始化失败（退出码 $exitCode），请重试。';
    }
    final summary = normalized.length <= 240
        ? normalized
        : '${normalized.substring(0, 237)}...';
    return 'MySQL 初始化失败（退出码 $exitCode）：$summary';
  }

  void _clearOrchestrator() {
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    orchestrator.removeListener(_syncFromOrchestrator);
    orchestrator.dispose();
    _orchestrator = null;
  }

  bool _beginOperation() {
    if (_operationLease != null) return true;
    final coordinator = _operations;
    if (coordinator == null) return true;
    final lease = coordinator.tryAcquire('configure-environment');
    if (lease == null) {
      state = state.copyWith(
        phase: SetupUiPhase.failed,
        errorMessage: '另一项环境操作正在进行，请稍后重试。',
      );
      notifyListeners();
      return false;
    }
    _operationLease = lease;
    return true;
  }

  void _releaseOperationIfTerminal() {
    final terminal = switch (state.phase) {
      SetupUiPhase.idle ||
      SetupUiPhase.failed ||
      SetupUiPhase.cancelled ||
      SetupUiPhase.completed => true,
      _ => false,
    };
    if (!terminal) return;
    _operationLease?.release();
    _operationLease = null;
  }

  @override
  void dispose() {
    _clearOrchestrator();
    _operationLease?.release();
    _operationLease = null;
    super.dispose();
  }
}
