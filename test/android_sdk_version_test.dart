import 'package:dev_environment_manager/src/environment/android_sdk_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reports the highest installed Android platform as a runtime version',
    () {
      expect(
        latestAndroidSdkPlatformVersion([
          'android-31',
          'android-36',
          'android-34-ext11',
          'sources',
        ]),
        '36.0.0',
      );
    },
  );

  test('returns null when no Android platform is installed', () {
    expect(latestAndroidSdkPlatformVersion(['tools', 'build-tools']), isNull);
  });
}
