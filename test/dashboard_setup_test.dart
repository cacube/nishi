import 'package:dev_environment_manager/src/dashboard/dashboard_page.dart';
import 'package:dev_environment_manager/src/environment/environment_controller.dart';
import 'package:dev_environment_manager/src/setup/setup_orchestrator.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:dev_environment_manager/src/setup_ui/setup_composition.dart';
import 'package:dev_environment_manager/src/setup_ui/setup_ui_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
