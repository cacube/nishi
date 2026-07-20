import 'package:dev_environment_manager/src/setup/setup_orchestrator.dart';
import 'package:dev_environment_manager/src/setup/setup_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs tasks after their dependencies', () async {
    final calls = <String>[];
    final orchestrator = SetupOrchestrator(
      tasks: const [
        SetupTaskDefinition(id: 'git', label: 'Git'),
        SetupTaskDefinition(
          id: 'flutter',
          label: 'Flutter',
          dependencies: ['git'],
        ),
      ],
      actions: {
        'git': _Action(() => calls.add('git')),
        'flutter': _Action(() => calls.add('flutter')),
      },
    );

    await orchestrator.run();

    expect(calls, ['git', 'flutter']);
    expect(orchestrator.completed, isTrue);
    expect(orchestrator.progress, 1);
  });

  test('failure blocks dependants but independent tasks continue', () async {
    final calls = <String>[];
    final orchestrator = SetupOrchestrator(
      tasks: const [
        SetupTaskDefinition(id: 'jdk', label: 'JDK'),
        SetupTaskDefinition(
          id: 'android',
          label: 'Android',
          dependencies: ['jdk'],
        ),
        SetupTaskDefinition(id: 'go', label: 'Go'),
      ],
      actions: {
        'jdk': _Action(() => throw StateError('download failed')),
        'android': _Action(() => calls.add('android')),
        'go': _Action(() => calls.add('go')),
      },
    );

    await orchestrator.run();

    expect(calls, ['go']);
    expect(_status(orchestrator, 'jdk'), SetupTaskStatus.failed);
    expect(_status(orchestrator, 'android'), SetupTaskStatus.blocked);
    expect(_status(orchestrator, 'go'), SetupTaskStatus.succeeded);
  });

  test(
    'retry reruns failed branch without rerunning successful tasks',
    () async {
      var failJdk = true;
      var goRuns = 0;
      final orchestrator = SetupOrchestrator(
        tasks: const [
          SetupTaskDefinition(id: 'jdk', label: 'JDK'),
          SetupTaskDefinition(
            id: 'android',
            label: 'Android',
            dependencies: ['jdk'],
          ),
          SetupTaskDefinition(id: 'go', label: 'Go'),
        ],
        actions: {
          'jdk': _Action(() {
            if (failJdk) throw StateError('download failed');
          }),
          'android': _Action(() {}),
          'go': _Action(() => goRuns++),
        },
      );

      await orchestrator.run();
      failJdk = false;
      await orchestrator.retryFailed();

      expect(orchestrator.completed, isTrue);
      expect(goRuns, 1);
    },
  );

  test('rejects dependency cycles', () {
    expect(
      () => SetupOrchestrator(
        tasks: const [
          SetupTaskDefinition(id: 'a', label: 'A', dependencies: ['b']),
          SetupTaskDefinition(id: 'b', label: 'B', dependencies: ['a']),
        ],
        actions: {'a': _Action(() {}), 'b': _Action(() {})},
      ),
      throwsArgumentError,
    );
  });

  test(
    'pauses for user action and resumes dependants after verification',
    () async {
      var installerRuns = 0;
      var dependantRuns = 0;
      final orchestrator = SetupOrchestrator(
        tasks: const [
          SetupTaskDefinition(id: 'mysql', label: 'MySQL'),
          SetupTaskDefinition(
            id: 'service',
            label: 'MySQL service',
            dependencies: ['mysql'],
          ),
        ],
        actions: {
          'mysql': _Action(() {
            installerRuns++;
            throw const SetupUserActionRequiredException(message: '请完成系统安装');
          }),
          'service': _Action(() => dependantRuns++),
        },
      );

      await orchestrator.run();

      expect(_status(orchestrator, 'mysql'), SetupTaskStatus.awaitingUser);
      expect(_status(orchestrator, 'service'), SetupTaskStatus.blocked);

      await orchestrator.resumeAfterUserAction('mysql', verified: true);

      expect(orchestrator.completed, isTrue);
      expect(installerRuns, 1);
      expect(dependantRuns, 1);
    },
  );
}

SetupTaskStatus _status(SetupOrchestrator orchestrator, String id) {
  return orchestrator.tasks
      .firstWhere((task) => task.definition.id == id)
      .status;
}

class _Action implements SetupTaskAction {
  _Action(this.callback);

  final void Function() callback;

  @override
  Future<void> execute(SetupProgressCallback onProgress) async {
    onProgress(0.5, null);
    callback();
  }
}
