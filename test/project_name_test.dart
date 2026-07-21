import 'package:dev_environment_manager/src/project_init/project_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes a display name for Flutter and MySQL', () {
    final name = ProjectName.parse('My Great-App 2');

    expect(name.directoryName, 'My Great-App 2');
    expect(name.packageName, 'my_great_app_2');
    expect(name.databaseName, name.packageName);
  });

  test('prefixes identifiers that cannot start a Dart package name', () {
    expect(ProjectName.parse('123 shop').packageName, 'lc_123_shop');
    expect(ProjectName.parse('class').packageName, 'lc_class');
  });

  test('creates a stable ASCII identifier for a Chinese display name', () {
    final first = ProjectName.parse('商城');
    final second = ProjectName.parse('商城');

    expect(first.packageName, matches(RegExp(r'^lc_project_[0-9a-f]{8}$')));
    expect(first.packageName, second.packageName);
  });

  test('rejects unsafe or unusable directory names', () {
    for (final value in <String>[
      '',
      '.',
      '..',
      'a/b',
      r'a\b',
      'bad:name',
      'trailing.',
      'trailing ',
      'CON',
      'com1.txt',
    ]) {
      expect(
        () => ProjectName.parse(value),
        throwsA(isA<ProjectNameException>()),
        reason: value,
      );
    }
  });
}
