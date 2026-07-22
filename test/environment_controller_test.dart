import 'dart:async';

import 'package:dev_environment_manager/src/environment/environment_component.dart';
import 'package:dev_environment_manager/src/environment/environment_controller.dart';
import 'package:dev_environment_manager/src/environment/environment_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ready ignores optional components but requires every required component',
    () async {
      final controller = EnvironmentController(
        scanner: _FakeScanner([
          _component('flutter', required: true, status: ComponentStatus.ready),
          _component('xcode', required: false, status: ComponentStatus.missing),
        ]),
      );

      await controller.scan();

      expect(controller.ready, isTrue);
      expect(controller.requiredActionCount, 0);
    },
  );

  test('missing required component prevents ready state', () async {
    final controller = EnvironmentController(
      scanner: _FakeScanner([
        _component('flutter', required: true, status: ComponentStatus.ready),
        _component('mysql', required: true, status: ComponentStatus.attention),
      ]),
    );

    await controller.scan();

    expect(controller.ready, isFalse);
    expect(controller.requiredActionCount, 1);
  });

  test('concurrent scans wait for the same host scan', () async {
    final scanner = _DelayedScanner();
    final controller = EnvironmentController(scanner: scanner);

    final first = controller.scan();
    final second = controller.scan();

    expect(scanner.calls, 1);
    expect(controller.components, isEmpty);

    scanner.complete([
      _component('flutter', required: true, status: ComponentStatus.ready),
    ]);
    await Future.wait([first, second]);

    expect(controller.components.single.id, 'flutter');
    expect(controller.scanning, isFalse);
  });
}

EnvironmentComponent _component(
  String id, {
  required bool required,
  required ComponentStatus status,
}) {
  return EnvironmentComponent(
    id: id,
    name: id,
    group: ComponentGroup.tools,
    icon: Icons.build,
    required: required,
    status: status,
  );
}

class _FakeScanner extends EnvironmentScanner {
  const _FakeScanner(this.result);

  final List<EnvironmentComponent> result;

  @override
  Future<List<EnvironmentComponent>> scan() async => result;
}

class _DelayedScanner extends EnvironmentScanner {
  final _result = Completer<List<EnvironmentComponent>>();
  int calls = 0;

  void complete(List<EnvironmentComponent> components) {
    _result.complete(components);
  }

  @override
  Future<List<EnvironmentComponent>> scan() {
    calls++;
    return _result.future;
  }
}
