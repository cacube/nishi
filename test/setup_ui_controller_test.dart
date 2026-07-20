import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dev_environment_manager/src/download/download_manager.dart';
import 'package:dev_environment_manager/src/environment/environment_controller.dart';
import 'package:dev_environment_manager/src/install/artifact_installer.dart';
import 'package:dev_environment_manager/src/manifest_security/remote_manifest_exceptions.dart';
import 'package:dev_environment_manager/src/manifest_security/remote_manifest_release_configuration.dart';
import 'package:dev_environment_manager/src/operation/runtime_operation_coordinator.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/provisioning/provisioning_workflow.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/setup/setup_orchestrator.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:dev_environment_manager/src/setup_ui/setup_ui_controller.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'does not start setup while another runtime operation owns the lock',
    () async {
      final operations = RuntimeOperationCoordinator();
      final lease = operations.tryAcquire('download-updates')!;
      var prepared = false;
      final controller = SetupUiController(
        prepare: () async {
          prepared = true;
          return SetupOrchestrator(tasks: const [], actions: const {});
        },
        rescanEnvironment: () async {},
        operations: operations,
      );
      addTearDown(controller.dispose);
      addTearDown(operations.dispose);

      await controller.start();

      expect(prepared, isFalse);
      expect(controller.state.phase, SetupUiPhase.failed);
      expect(controller.state.errorMessage, contains('另一项环境操作'));
      lease.release();
    },
  );

  test(
    'starts a selected component update through the selection preparer',
    () async {
      Set<String>? preparedIds;
      final controller = SetupUiController(
        prepare: () async =>
            SetupOrchestrator(tasks: const [], actions: const {}),
        prepareSelection: (componentIds) async {
          preparedIds = componentIds;
          return SetupOrchestrator(
            tasks: const [SetupTaskDefinition(id: 'go', label: 'Go')],
            actions: {'go': _ImmediateAction()},
          );
        },
        rescanEnvironment: () async {},
      );

      await controller.startSelected(const {'go'});

      expect(preparedIds, {'go'});
      expect(controller.state.phase, SetupUiPhase.completed);
    },
  );

  test('prepares the signed manifest and mirrors task progress', () async {
    final preparation = Completer<SetupOrchestrator>();
    final action = _ControlledAction();
    final controller = SetupUiController(
      prepare: () => preparation.future,
      rescanEnvironment: () async {},
    );

    final operation = controller.start();
    expect(controller.state.phase, SetupUiPhase.preparing);

    preparation.complete(
      SetupOrchestrator(
        tasks: const [SetupTaskDefinition(id: 'flutter', label: 'Flutter')],
        actions: {'flutter': action},
      ),
    );
    await action.started.future;
    action.reportProgress(0.4, '正在下载');

    expect(controller.state.phase, SetupUiPhase.running);
    expect(controller.state.progress, 0.4);
    expect(controller.state.tasks.single.id, 'flutter');
    expect(controller.state.tasks.single.message, '正在下载');

    action.complete();
    await operation;
  });

  test('holds the runtime operation lock until setup completes', () async {
    final operations = RuntimeOperationCoordinator();
    final action = _ControlledAction();
    final controller = SetupUiController(
      prepare: () async => SetupOrchestrator(
        tasks: const [SetupTaskDefinition(id: 'flutter', label: 'Flutter')],
        actions: {'flutter': action},
      ),
      rescanEnvironment: () async {},
      operations: operations,
    );
    addTearDown(controller.dispose);
    addTearDown(operations.dispose);

    final setup = controller.start();
    await action.started.future;

    expect(operations.activeOperation, 'configure-environment');
    expect(operations.tryAcquire('clear-cache'), isNull);

    action.complete();
    await setup;
    expect(operations.busy, isFalse);
  });

  test('rescans the environment after every task succeeds', () async {
    var scanCount = 0;
    final controller = SetupUiController(
      prepare: () async => SetupOrchestrator(
        tasks: const [SetupTaskDefinition(id: 'go', label: 'Go')],
        actions: {'go': _ImmediateAction()},
      ),
      rescanEnvironment: () async => scanCount++,
    );

    await controller.start();

    expect(controller.state.phase, SetupUiPhase.completed);
    expect(scanCount, 1);
  });

  test('cancels the active setup task', () async {
    final action = _CancellableBlockingAction();
    final controller = SetupUiController(
      prepare: () async => SetupOrchestrator(
        tasks: const [SetupTaskDefinition(id: 'android', label: 'Android SDK')],
        actions: {'android': action},
      ),
      rescanEnvironment: () async {},
    );

    final operation = controller.start();
    await action.started.future;
    controller.cancel();
    expect(controller.state.phase, SetupUiPhase.cancelling);
    await operation;

    expect(action.cancelled, isTrue);
    expect(controller.state.phase, SetupUiPhase.cancelled);
    expect(controller.state.tasks.single.status, SetupTaskStatus.cancelled);
  });

  test('retries only failed branches and rescans after recovery', () async {
    var shouldFail = true;
    var successfulRuns = 0;
    var scanCount = 0;
    final controller = SetupUiController(
      prepare: () async => SetupOrchestrator(
        tasks: const [
          SetupTaskDefinition(id: 'jdk', label: 'JDK'),
          SetupTaskDefinition(id: 'git', label: 'Git'),
        ],
        actions: {
          'jdk': _CallbackAction(() {
            if (shouldFail) throw StateError('secret=/tmp/release.key');
          }),
          'git': _CallbackAction(() => successfulRuns++),
        },
      ),
      rescanEnvironment: () async => scanCount++,
    );

    await controller.start();
    expect(controller.state.phase, SetupUiPhase.failed);
    expect(controller.state.tasks.first.message, '安装失败，请重试。');
    expect(
      controller.state.tasks.first.message,
      isNot(contains('release.key')),
    );

    shouldFail = false;
    await controller.retryFailed();

    expect(controller.state.phase, SetupUiPhase.completed);
    expect(successfulRuns, 1);
    expect(scanCount, 1);
  });

  test(
    'exposes a user action request and continues after confirmation',
    () async {
      final request = Object();
      var dependantRuns = 0;
      var scanCount = 0;
      final controller = SetupUiController(
        prepare: () async => SetupOrchestrator(
          tasks: const [
            SetupTaskDefinition(id: 'mysql', label: 'MySQL'),
            SetupTaskDefinition(
              id: 'database',
              label: '数据库服务',
              dependencies: ['mysql'],
            ),
          ],
          actions: {
            'mysql': _CallbackAction(
              () => throw SetupUserActionRequiredException(
                message: '需要系统授权',
                request: request,
              ),
            ),
            'database': _CallbackAction(() => dependantRuns++),
          },
        ),
        rescanEnvironment: () async => scanCount++,
      );

      await controller.start();

      expect(controller.state.phase, SetupUiPhase.awaitingUser);
      expect(controller.state.tasks.first.userActionRequest, same(request));
      expect(controller.state.tasks.first.message, '需要系统授权');

      await controller.continueAfterUserAction('mysql');

      expect(controller.state.phase, SetupUiPhase.completed);
      expect(dependantRuns, 1);
      expect(scanCount, 1);
    },
  );

  test('does not expose signing key details in preparation errors', () async {
    final controller = SetupUiController(
      prepare: () async {
        throw InvalidManifestSignatureException('private-release-key-id');
      },
      rescanEnvironment: () async {},
    );

    await controller.start();

    expect(controller.state.phase, SetupUiPhase.failed);
    expect(controller.state.errorMessage, '安装清单安全验证失败，请联系维护人员。');
    expect(
      controller.state.errorMessage,
      isNot(contains('private-release-key-id')),
    );
  });

  test(
    'retry starts preparation again when no task graph was created',
    () async {
      var attempts = 0;
      final controller = SetupUiController(
        prepare: () async {
          attempts++;
          if (attempts == 1) {
            throw RemoteManifestNetworkException(
              uri: Uri.parse('https://example.invalid/manifest.json'),
              resource: RemoteManifestResource.manifest,
              cause: const SocketException('offline'),
            );
          }
          return SetupOrchestrator(tasks: const [], actions: const {});
        },
        rescanEnvironment: () async {},
      );

      await controller.start();
      expect(controller.state.phase, SetupUiPhase.failed);

      await controller.retry();

      expect(attempts, 2);
      expect(controller.state.phase, SetupUiPhase.completed);
    },
  );

  test(
    'does not run a licensed component before explicit preflight consent',
    () async {
      var actionRuns = 0;
      final acceptedLicenses = <String>{};
      final controller = SetupUiController(
        prepare: () async => SetupOrchestrator(
          tasks: const [
            SetupTaskDefinition(id: 'android-sdk', label: 'Android SDK'),
          ],
          actions: {'android-sdk': _CallbackAction(() => actionRuns++)},
        ),
        rescanEnvironment: () async {},
        preflightConfirmations: [androidSdkLicensePreflight],
        onPreflightAccepted: acceptedLicenses.addAll,
      );

      await controller.start();

      expect(controller.state.phase, SetupUiPhase.awaitingPreflight);
      expect(
        controller.state.pendingPreflight.single.id,
        'android-sdk-license',
      );
      expect(actionRuns, 0);

      await controller.retryFailed();
      await controller.continueAfterUserAction('android-sdk');
      await controller.start();
      expect(controller.state.phase, SetupUiPhase.awaitingPreflight);
      expect(actionRuns, 0);

      await controller.confirmPreflight(const {});
      expect(controller.state.phase, SetupUiPhase.awaitingPreflight);
      expect(controller.state.errorMessage, '请先同意全部必需的许可条款。');
      expect(actionRuns, 0);

      await controller.confirmPreflight(const {'android-sdk-license'});
      expect(controller.state.phase, SetupUiPhase.completed);
      expect(actionRuns, 1);
      expect(acceptedLicenses, {'android-sdk-license'});
    },
  );

  test(
    'requires the Memurai development license before its task runs',
    () async {
      var actionRuns = 0;
      final controller = SetupUiController(
        prepare: () async => SetupOrchestrator(
          tasks: const [SetupTaskDefinition(id: 'memurai', label: 'Memurai')],
          actions: {'memurai': _CallbackAction(() => actionRuns++)},
        ),
        rescanEnvironment: () async {},
        preflightConfirmations: [memuraiLicensePreflight],
      );

      await controller.start();

      expect(controller.state.phase, SetupUiPhase.awaitingPreflight);
      expect(controller.state.pendingPreflight.single.id, 'memurai-license');
      expect(actionRuns, 0);
    },
  );

  test(
    'cancelling during preparation prevents orchestration from starting',
    () async {
      final preparation = Completer<SetupOrchestrator>();
      var actionRuns = 0;
      final controller = SetupUiController(
        prepare: () => preparation.future,
        rescanEnvironment: () async {},
      );

      final operation = controller.start();
      controller.cancel();
      preparation.complete(
        SetupOrchestrator(
          tasks: const [SetupTaskDefinition(id: 'go', label: 'Go')],
          actions: {'go': _CallbackAction(() => actionRuns++)},
        ),
      );
      await operation;

      expect(controller.state.phase, SetupUiPhase.cancelled);
      expect(actionRuns, 0);
    },
  );

  test(
    'remote release factory prepares the workflow and uses environment scan',
    () async {
      final directory = await Directory.systemTemp.createTemp('setup_ui_');
      addTearDown(() => directory.delete(recursive: true));
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': directory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      final downloads = DownloadManager();
      addTearDown(() => downloads.close(force: true));
      final environment = _CountingEnvironmentController();
      final controller = SetupUiController.forRemoteRelease(
        workflow: ProvisioningWorkflow(
          layout: layout,
          downloads: downloads,
          installer: ArtifactInstaller(layout: layout),
          target: const RuntimeTarget(
            platform: RuntimePlatform.macos,
            architecture: RuntimeArchitecture.arm64,
          ),
        ),
        releaseConfiguration: RemoteManifestReleaseConfiguration.fromValues(
          signingKeyId: 'test-key',
          signingPublicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        ),
        environmentController: environment,
        preflightConfirmations: const [],
        manifestSourceOverride: () async => RuntimeManifest(
          schemaVersion: 1,
          components: [
            RuntimeComponent(
              id: 'xcode',
              displayName: 'Xcode',
              version: '1.0.0',
              minimumCompatibleVersion: '1.0.0',
              provisioning: RuntimeProvisioning.external,
              artifacts: const [],
              executables: [
                RuntimeExecutable(
                  platform: RuntimePlatform.macos,
                  architectures: const [
                    RuntimeArchitecture.x64,
                    RuntimeArchitecture.arm64,
                  ],
                  path: 'xcodebuild',
                ),
              ],
              dependencies: const [],
            ),
          ],
        ),
      );

      await controller.start();

      expect(controller.state.phase, SetupUiPhase.completed);
      expect(controller.state.tasks.single.id, 'xcode');
      expect(environment.scanCount, 1);
    },
  );
}

final class _ControlledAction implements CancellableSetupTaskAction {
  final started = Completer<void>();
  final _completed = Completer<void>();
  SetupProgressCallback? _onProgress;

  @override
  Future<void> execute(SetupProgressCallback onProgress) {
    _onProgress = onProgress;
    started.complete();
    return _completed.future;
  }

  void reportProgress(double progress, String? message) {
    _onProgress!(progress, message);
  }

  void complete() => _completed.complete();

  @override
  void cancel() => _completed.complete();
}

final class _ImmediateAction implements SetupTaskAction {
  @override
  Future<void> execute(SetupProgressCallback onProgress) async {}
}

final class _CancellableBlockingAction implements CancellableSetupTaskAction {
  final started = Completer<void>();
  final _completed = Completer<void>();
  bool cancelled = false;

  @override
  Future<void> execute(SetupProgressCallback onProgress) {
    started.complete();
    return _completed.future;
  }

  @override
  void cancel() {
    cancelled = true;
    _completed.completeError(StateError('cancelled with private detail'));
  }
}

final class _CallbackAction implements SetupTaskAction {
  _CallbackAction(this.callback);

  final void Function() callback;

  @override
  Future<void> execute(SetupProgressCallback onProgress) async => callback();
}

final class _CountingEnvironmentController extends EnvironmentController {
  int scanCount = 0;

  @override
  Future<void> scan() async => scanCount++;
}
