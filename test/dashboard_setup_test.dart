import 'package:dev_environment_manager/src/dashboard/dashboard_page.dart';
import 'package:dev_environment_manager/src/environment/environment_component.dart';
import 'package:dev_environment_manager/src/environment/environment_controller.dart';
import 'package:dev_environment_manager/src/mysql/mysql_credentials.dart';
import 'package:dev_environment_manager/src/setup/setup_orchestrator.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:dev_environment_manager/src/setup_ui/setup_composition.dart';
import 'package:dev_environment_manager/src/setup_ui/setup_ui_controller.dart';
import 'package:dev_environment_manager/src/settings/settings.dart';
import 'package:dev_environment_manager/src/provisioning/runtime_target.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:dev_environment_manager/src/update/update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('navigates to functional update and settings centers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final environment = _StaticEnvironmentController();
    final setup = SetupUiController(
      prepare: () async =>
          SetupOrchestrator(tasks: const [], actions: const {}),
      prepareSelection: (_) async => SetupOrchestrator(
        tasks: const [SetupTaskDefinition(id: 'flutter', label: 'Flutter SDK')],
        actions: {'flutter': _CallbackAction(() {})},
      ),
      rescanEnvironment: environment.scan,
    );
    final settings = SettingsController(store: MemorySettingsStore());
    final updates = UpdateController(
      manifestSource: () async => RuntimeManifest(
        schemaVersion: 1,
        components: [_managedComponent('flutter', '3.44.6')],
      ),
      readActiveVersions: () async => const {},
      readDetectedVersions: () async => {'flutter': '3.41.4'},
      target: const RuntimeTarget(
        platform: RuntimePlatform.macos,
        architecture: RuntimeArchitecture.arm64,
      ),
    );
    final composition = SetupComposition.forTesting(
      environment: environment,
      setup: setup,
      settings: settings,
      updates: updates,
    );
    addTearDown(setup.dispose);
    addTearDown(environment.dispose);
    addTearDown(settings.dispose);
    addTearDown(updates.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DashboardPage(composition: composition)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更新').first);
    await tester.pumpAndSettle();
    expect(find.text('组件更新'), findsOneWidget);
    expect(find.text('Flutter SDK'), findsOneWidget);
    expect(find.text('3.41.4  →  3.44.6'), findsOneWidget);
    expect(find.text('更新全部'), findsOneWidget);
    expect(find.text('下载更新包'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('更新设置'), findsOneWidget);
    expect(find.text('下载源'), findsOneWidget);
    expect(find.text('缓存与存储'), findsOneWidget);

    for (final element in find.byType(ListTile).evaluate()) {
      var foundMaterial = false;
      var foundDecoratedBoxBeforeMaterial = false;
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is Material) {
          foundMaterial = true;
          return false;
        }
        if (ancestor.widget is DecoratedBox) {
          foundDecoratedBoxBeforeMaterial = true;
        }
        return true;
      });
      expect(foundMaterial, isTrue);
      expect(foundDecoratedBoxBeforeMaterial, isFalse);
    }

    await tester.tap(find.text('国内优先'));
    await tester.pumpAndSettle();
    expect(
      settings.settings.downloadSourcePreference,
      DownloadSourcePreference.mirrorFirst,
    );
  });

  testWidgets('one-click setup requires license consent before execution', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var actionRuns = 0;
    final environment = _StaticEnvironmentController();
    final setup = SetupUiController(
      prepare: () async => SetupOrchestrator(
        tasks: const [
          SetupTaskDefinition(id: 'android-sdk', label: 'Android SDK'),
        ],
        actions: {'android-sdk': _CallbackAction(() => actionRuns++)},
      ),
      rescanEnvironment: environment.scan,
      preflightConfirmations: [androidSdkLicensePreflight],
    );
    addTearDown(setup.dispose);
    addTearDown(environment.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          composition: SetupComposition.forTesting(
            environment: environment,
            setup: setup,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('一键配置'));
    await tester.pumpAndSettle();

    expect(find.text('需要许可确认'), findsOneWidget);
    expect(find.text('同意并继续'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(actionRuns, 0);
    var foundMaterial = false;
    var foundDecoratedBoxBeforeMaterial = false;
    tester.element(find.byType(CheckboxListTile)).visitAncestorElements((
      element,
    ) {
      if (element.widget is Material) {
        foundMaterial = true;
        return false;
      }
      if (element.widget is DecoratedBox) {
        foundDecoratedBoxBeforeMaterial = true;
      }
      return true;
    });
    expect(foundMaterial, isTrue);
    expect(foundDecoratedBoxBeforeMaterial, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();

    expect(actionRuns, 1);
    expect(find.text('配置已完成'), findsOneWidget);
  });

  testWidgets('manual setup includes dependencies for the selected component', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Set<String>? preparedIds;
    final environment = _StaticEnvironmentController();
    environment.components = const [
      EnvironmentComponent(
        id: 'flutter',
        name: 'Flutter SDK',
        group: ComponentGroup.flutter,
        icon: Icons.flutter_dash,
        required: true,
        status: ComponentStatus.missing,
      ),
    ];
    final setup = SetupUiController(
      prepare: () async =>
          SetupOrchestrator(tasks: const [], actions: const {}),
      prepareSelection: (componentIds) async {
        preparedIds = componentIds;
        return SetupOrchestrator(tasks: const [], actions: const {});
      },
      rescanEnvironment: environment.scan,
    );
    addTearDown(setup.dispose);
    addTearDown(environment.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          composition: SetupComposition.forTesting(
            environment: environment,
            setup: setup,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('一键配置'), findsOneWidget);
    expect(find.text('选择安装'), findsOneWidget);
    await tester.tap(find.text('选择安装'));
    await tester.pumpAndSettle();

    expect(find.text('选择安装组件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('install-flutter')));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('install-jdk')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('install-android-sdk')),
          )
          .value,
      isTrue,
    );
    expect(find.text('安装所选 (3)'), findsOneWidget);

    await tester.tap(find.text('安装所选 (3)'));
    await tester.pumpAndSettle();

    expect(preparedIds, {'jdk', 'android-sdk', 'flutter'});
    expect(setup.state.phase, SetupUiPhase.completed);
  });

  testWidgets('shows generated MySQL credentials on explicit user request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final environment = _StaticEnvironmentController();
    environment.components = const [
      EnvironmentComponent(
        id: 'mysql',
        name: 'MySQL',
        group: ComponentGroup.services,
        icon: Icons.storage,
        required: true,
        status: ComponentStatus.ready,
        version: '8.4.10',
      ),
    ];
    final setup = SetupUiController(
      prepare: () async =>
          SetupOrchestrator(tasks: const [], actions: const {}),
      rescanEnvironment: environment.scan,
    );
    addTearDown(setup.dispose);
    addTearDown(environment.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardPage(
          composition: SetupComposition.forTesting(
            environment: environment,
            setup: setup,
            mysqlCredentials: const _MemoryMySqlCredentialsReader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mysql-credentials-button')));
    await tester.pumpAndSettle();

    expect(find.text('MySQL 连接信息'), findsOneWidget);
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('3306'), findsOneWidget);
    expect(find.text('root'), findsOneWidget);
    expect(find.text('********'), findsOneWidget);
    expect(find.text('generated-password'), findsNothing);

    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(find.text('generated-password'), findsOneWidget);
  });
}

RuntimeComponent _managedComponent(String id, String version) {
  return RuntimeComponent(
    id: id,
    displayName: 'Flutter SDK',
    version: version,
    minimumCompatibleVersion: version,
    provisioning: RuntimeProvisioning.managed,
    artifacts: [
      RuntimeArtifact(
        platform: RuntimePlatform.macos,
        architecture: RuntimeArchitecture.arm64,
        officialUrl: Uri.parse('https://example.invalid/$id.zip'),
        sha256: 'a' * 64,
        archiveType: RuntimeArchiveType.zip,
      ),
    ],
    executables: [
      RuntimeExecutable(
        platform: RuntimePlatform.macos,
        architectures: const [RuntimeArchitecture.arm64],
        path: 'bin/$id',
      ),
    ],
    dependencies: const [],
  );
}

final class _StaticEnvironmentController extends EnvironmentController {
  @override
  Future<void> scan() async {}
}

final class _CallbackAction implements SetupTaskAction {
  const _CallbackAction(this.callback);

  final void Function() callback;

  @override
  Future<void> execute(SetupProgressCallback onProgress) async => callback();
}

final class _MemoryMySqlCredentialsReader implements MySqlCredentialsReader {
  const _MemoryMySqlCredentialsReader();

  @override
  Future<MySqlCredentials?> read() async => const MySqlCredentials(
    host: '127.0.0.1',
    port: 3306,
    username: 'root',
    password: 'generated-password',
  );
}
