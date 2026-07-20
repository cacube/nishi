import 'dart:io';

import '../activation/activation_boundaries.dart';
import '../activation/autostart_coordinator.dart';
import '../activation/autostart_plans.dart';
import '../activation/environment_activation.dart';
import '../activation/host_environment_installer.dart';
import '../android_sdk/android_sdk_configurator.dart';
import '../download/download_manager.dart';
import '../environment/environment_scanner.dart';
import '../install/artifact_installer.dart';
import '../runtime_manifest/runtime_manifest.dart';
import '../mysql/mysql_configurator.dart';
import '../setup/license_acceptance.dart';
import '../setup/setup_orchestrator.dart';
import '../setup/setup_task.dart';
import '../storage/runtime_layout.dart';
import 'provisioning_plan.dart';
import 'runtime_provisioning_action.dart';
import 'runtime_target.dart';

typedef RuntimeManifestSource = Future<RuntimeManifest> Function();

final class ProvisioningWorkflow {
  ProvisioningWorkflow({
    required RuntimeLayout layout,
    required DownloadManager downloads,
    required ArtifactInstaller installer,
    RuntimeTarget? target,
    LicenseAcceptanceRegistry? licenseAcceptance,
    this.activateHostEnvironment = true,
  }) : _layout = layout,
       _downloads = downloads,
       _installer = installer,
       _target = target ?? RuntimeTarget.current(),
       _licenseAcceptance = licenseAcceptance ?? LicenseAcceptanceRegistry();

  final RuntimeLayout _layout;
  final DownloadManager _downloads;
  final ArtifactInstaller _installer;
  final RuntimeTarget _target;
  final LicenseAcceptanceRegistry _licenseAcceptance;
  final bool activateHostEnvironment;

  Future<SetupOrchestrator> prepare(RuntimeManifestSource source) async {
    await _layout.ensureCreated();
    final manifest = await source();
    final activeVersions = await _layout.readActiveVersions();
    final plan = ProvisioningPlan.fromManifest(manifest, _target);
    final tasks = <SetupTaskDefinition>[];
    final actions = <String, SetupTaskAction>{};

    for (final entry in plan.entries) {
      final component = entry.component;
      tasks.add(
        SetupTaskDefinition(
          id: component.id,
          label: component.displayName,
          dependencies: component.dependencies,
          externallyManaged: component.isExternal,
        ),
      );
      final artifact = entry.artifact;
      if (artifact != null) {
        if (activeVersions[component.id] == component.version) {
          actions[component.id] = const _AlreadyInstalledAction();
          continue;
        }
        final androidSdk = component.androidSdk;
        AndroidSdkConfigurator? androidConfigurator;
        MySqlConfigurator? mysqlConfigurator;
        if (androidSdk != null) {
          final jdk = manifest.componentById('jdk');
          if (jdk == null) {
            throw StateError('Android SDK requires the jdk component');
          }
          androidConfigurator = AndroidSdkConfigurator(
            sdkRoot: _layout
                .componentVersion(component.id, component.version)
                .path,
            jdkRoot: _layout.componentVersion(jdk.id, jdk.version).path,
            packages: androidSdk.packages,
            repositoryMirrorUrls: androidSdk.repositoryMirrorUrls,
            isWindows: artifact.platform == RuntimePlatform.windows,
          );
        }
        if (component.id == 'mysql') {
          mysqlConfigurator = MySqlConfigurator(
            mysqlRoot: _layout
                .componentVersion(component.id, component.version)
                .path,
            dataDirectory: Directory(
              '${_layout.data.path}${Platform.pathSeparator}mysql',
            ),
            logDirectory: Directory(
              '${_layout.logs.path}${Platform.pathSeparator}mysql',
            ),
            isWindows: artifact.platform == RuntimePlatform.windows,
          );
        }
        RuntimePostInstall? postInstall;
        void Function()? cancelPostInstall;
        if (androidConfigurator != null) {
          postInstall = (_, onProgress) => androidConfigurator!.configure(
            licensesAccepted: _licenseAcceptance.contains(
              androidSdk!.license.id,
            ),
            onProgress: (progress) {
              onProgress(progress.fraction, progress.message);
            },
          );
          cancelPostInstall = androidConfigurator.cancel;
        } else if (mysqlConfigurator != null) {
          postInstall = (_, onProgress) =>
              _configureMySql(mysqlConfigurator!, component, onProgress);
          cancelPostInstall = mysqlConfigurator.cancel;
        }
        actions[component.id] = RuntimeProvisioningAction(
          component: component,
          artifact: artifact,
          layout: _layout,
          downloads: _downloads,
          installer: _installer,
          postInstall: postInstall,
          cancelPostInstall: cancelPostInstall,
        );
      }
    }

    final managedTaskIds = plan.entries
        .where((entry) => entry.component.isManaged)
        .map((entry) => entry.component.id)
        .toList(growable: false);
    if (activateHostEnvironment && managedTaskIds.isNotEmpty) {
      const taskId = 'host-environment';
      tasks.add(
        SetupTaskDefinition(
          id: taskId,
          label: '激活开发环境',
          dependencies: managedTaskIds,
        ),
      );
      actions[taskId] = _HostEnvironmentAction(
        layout: _layout,
        target: _target,
      );
    }

    return SetupOrchestrator(tasks: tasks, actions: actions);
  }

  Future<void> _configureMySql(
    MySqlConfigurator configurator,
    RuntimeComponent component,
    SetupProgressCallback onProgress,
  ) async {
    onProgress(0.1, '正在初始化 MySQL');
    final result = await configurator.configure();
    final service = component.service;
    if (service?.startAutomatically ?? false) {
      onProgress(0.65, '正在启动 MySQL 服务');
      await _enableMySqlAutoStart(result.launchConfiguration);
    }
    onProgress(1, 'MySQL 配置完成');
  }

  Future<void> _enableMySqlAutoStart(MySqlLaunchConfiguration launch) async {
    const files = IoActivationFileStore();
    const processes = IoActivationProcessRunner();
    final coordinator = AutoStartCoordinator(
      files: files,
      processes: processes,
    );
    if (Platform.isMacOS) {
      final uidResult = await Process.run('/usr/bin/id', ['-u']);
      if (uidResult.exitCode != 0) {
        throw StateError('无法读取当前 macOS 用户 ID');
      }
      final userId = int.tryParse(uidResult.stdout.toString().trim());
      final home = Platform.environment['HOME'];
      if (userId == null || home == null || home.isEmpty) {
        throw StateError('无法创建 macOS MySQL 登录服务');
      }
      final plistPath =
          '$home/Library/LaunchAgents/com.devenvironmentmanager.mysql.plist';
      final plan = MacOsLaunchAgentPlan.build(
        userId: userId,
        label: 'com.devenvironmentmanager.mysql',
        plistPath: plistPath,
        executable: launch.executable,
        arguments: launch.serverArguments,
        stdoutPath: launch.stdoutPath,
        stderrPath: launch.stderrPath,
      );
      if (await File(plistPath).exists()) {
        await coordinator.update(plan);
      } else {
        await coordinator.enable(plan);
      }
      return;
    }

    final plan = WindowsAutoStartPlan.userTask(
      id: 'mysql',
      taskName: r'DevEnvironmentManager\MySQL',
      executable: launch.executable,
      arguments: launch.serverArguments,
    );
    await coordinator.enable(plan);
    final start = await processes.run(
      const ActivationCommand(
        executable: 'schtasks.exe',
        arguments: ['/Run', '/TN', r'DevEnvironmentManager\MySQL'],
      ),
    );
    if (start.exitCode != 0) {
      throw AutoStartCommandException(
        const ActivationCommand(
          executable: 'schtasks.exe',
          arguments: ['/Run', '/TN', r'DevEnvironmentManager\MySQL'],
        ),
        start,
      );
    }
  }
}

final class _AlreadyInstalledAction implements SetupTaskAction {
  const _AlreadyInstalledAction();

  @override
  Future<void> execute(SetupProgressCallback onProgress) async {
    onProgress(1, '已是最新版本');
  }
}

final class _HostEnvironmentAction implements SetupTaskAction {
  const _HostEnvironmentAction({required this.layout, required this.target});

  final RuntimeLayout layout;
  final RuntimeTarget target;

  @override
  Future<void> execute(SetupProgressCallback onProgress) async {
    onProgress(0.1, '正在写入用户环境');
    final commandEnvironment = EnvironmentScanner(
      layout: layout,
    ).commandEnvironment();
    const keys = {
      'PATH',
      'JAVA_HOME',
      'ANDROID_HOME',
      'ANDROID_SDK_ROOT',
      'FLUTTER_ROOT',
      'GOROOT',
      'NODE_HOME',
      'MYSQL_HOME',
    };
    final environment = <String, String>{
      'DEV_ENVIRONMENT_MANAGER_ROOT': layout.root.path,
      for (final entry in commandEnvironment.entries)
        if (keys.contains(entry.key)) entry.key: entry.value,
    };
    final host = target.platform == RuntimePlatform.windows
        ? ActivationHost.windows
        : ActivationHost.macos;
    final home = Platform.environment['HOME'];
    if (host == ActivationHost.macos && (home == null || home.isEmpty)) {
      throw StateError('无法确定 macOS 用户目录');
    }
    final paths = switch (host) {
      ActivationHost.windows => HostEnvironmentInstallPaths.windows(
        stateFile:
            '${layout.root.path}${Platform.pathSeparator}host-environment.json',
      ),
      ActivationHost.macos => HostEnvironmentInstallPaths.macos(
        stateFile:
            '${layout.root.path}${Platform.pathSeparator}host-environment.json',
        replayScript:
            '${layout.root.path}${Platform.pathSeparator}replay-environment.sh',
        launchAgentPlist:
            '$home/Library/LaunchAgents/'
            'com.cacube.nishi.environment.plist',
      ),
    };
    await HostEnvironmentInstaller(
      files: const IoActivationFileStore(),
      processes: const IoActivationProcessRunner(),
    ).install(host: host, paths: paths, environment: environment);
    onProgress(1, '用户环境已激活');
  }
}
