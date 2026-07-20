import 'dart:convert';

import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const loader = RuntimeManifestLoader();

  test('loads a strongly typed managed and external component manifest', () {
    final manifest = loader.decode(jsonEncode(_validTestFixture()));

    expect(manifest.schemaVersion, 1);
    expect(manifest.components, hasLength(2));

    final mysql = manifest.componentById('mysql')!;
    expect(mysql.displayName, 'MySQL test fixture');
    expect(mysql.minimumCompatibleVersion, '8.0.0');
    expect(mysql.provisioning, RuntimeProvisioning.managed);
    expect(mysql.dependencies, ['jdk']);
    expect(mysql.artifacts.single.platform, RuntimePlatform.windows);
    expect(mysql.artifacts.single.architecture, RuntimeArchitecture.x64);
    expect(mysql.artifacts.single.archiveType, RuntimeArchiveType.zip);
    expect(mysql.artifacts.single.archiveRoot, 'mysql-test');
    expect(mysql.artifacts.single.installSubdirectory, 'runtime');
    expect(mysql.artifacts.single.mirrorUrls, [
      Uri.parse('https://mirror.example.invalid/non-production/mysql.zip'),
    ]);
    expect(mysql.artifacts.single.downloadUrls, [
      Uri.parse('https://downloads.example.invalid/non-production/mysql.zip'),
      Uri.parse('https://mirror.example.invalid/non-production/mysql.zip'),
    ]);
    expect(mysql.service?.defaultPort, 3306);
    expect(mysql.service?.startAutomatically, isTrue);
    expect(mysql.executables.single.path, r'bin\mysql.exe');

    final jdk = manifest.componentById('jdk')!;
    expect(jdk.isExternal, isTrue);
    expect(jdk.artifacts, isEmpty);
    expect(jdk.executables.single.architectures, [
      RuntimeArchitecture.x64,
      RuntimeArchitecture.arm64,
    ]);
  });

  test('loaded collections are immutable', () {
    final manifest = loader.fromJson(_validTestFixture());

    expect(
      () => manifest.components.add(manifest.components.first),
      throwsUnsupportedError,
    );
    expect(
      () => manifest.components.first.dependencies.add('another'),
      throwsUnsupportedError,
    );
    expect(
      () => manifest.components.first.executables.first.architectures.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => manifest.components.first.artifacts.first.mirrorUrls.clear(),
      throwsUnsupportedError,
    );
  });

  test('reports semantic errors with JSON paths', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final mysql = components.first! as Map<String, Object?>;
    final jdk = components.last! as Map<String, Object?>;
    final artifacts = mysql['artifacts']! as List<Object?>;
    final artifact = artifacts.first! as Map<String, Object?>;

    artifact['officialUrl'] = 'http://downloads.example.invalid/mysql.zip';
    artifact['sha256'] = 'not-a-production-checksum';
    artifact['archiveRoot'] = '../outside';
    artifact['installSubdirectory'] = '../runtime';
    mysql['artifacts'] = [...artifacts, Map<String, Object?>.from(artifact)];
    mysql['dependencies'] = ['missing-component'];
    jdk['artifacts'] = [Map<String, Object?>.from(artifact)];

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.map((item) => item.path),
          'error paths',
          containsAll([
            r'$.components[0].artifacts[0].officialUrl',
            r'$.components[0].artifacts[0].sha256',
            r'$.components[0].artifacts[0].archiveRoot',
            r'$.components[0].artifacts[0].installSubdirectory',
            r'$.components[0].artifacts[1]',
            r'$.components[0].dependencies[0]',
            r'$.components[1].artifacts',
          ]),
        ),
      ),
    );
  });

  test('rejects dependency cycles', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final jdk = components.last! as Map<String, Object?>;
    jdk['dependencies'] = ['mysql'];

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.any(
            (item) => item.message.contains('dependency cycle detected'),
          ),
          'cycle error',
          isTrue,
        ),
      ),
    );
  });

  test('reports malformed field types without leaking cast errors', () {
    final fixture = _validTestFixture();
    fixture['schemaVersion'] = '1';
    fixture['components'] = [42];

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.map((item) => item.path),
          'error paths',
          containsAll([r'$.schemaVersion', r'$.components[0]']),
        ),
      ),
    );
  });

  test('rejects non-object and malformed JSON roots', () {
    expect(
      () => loader.decode('[]'),
      throwsA(isA<RuntimeManifestValidationException>()),
    );
    expect(
      () => loader.decode('{'),
      throwsA(isA<RuntimeManifestValidationException>()),
    );
  });

  test('accepts a missing mirrorUrls field for old manifests', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final mysql = components.first! as Map<String, Object?>;
    final artifacts = mysql['artifacts']! as List<Object?>;
    final artifact = artifacts.first! as Map<String, Object?>;
    artifact.remove('mirrorUrls');

    final loaded = loader.fromJson(fixture);

    expect(loaded.componentById('mysql')!.artifacts.single.mirrorUrls, isEmpty);
  });

  test('rejects a non-array mirrorUrls field', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final mysql = components.first! as Map<String, Object?>;
    final artifacts = mysql['artifacts']! as List<Object?>;
    final artifact = artifacts.first! as Map<String, Object?>;
    artifact['mirrorUrls'] = 'not-an-array';

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.map((item) => item.path),
          'error paths',
          contains(r'$.components[0].artifacts[0].mirrorUrls'),
        ),
      ),
    );
  });

  test('rejects insecure and duplicate mirror URLs', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final mysql = components.first! as Map<String, Object?>;
    final artifacts = mysql['artifacts']! as List<Object?>;
    final artifact = artifacts.first! as Map<String, Object?>;
    artifact['mirrorUrls'] = [
      artifact['officialUrl'],
      'http://mirror.example.invalid/mysql.zip',
      'https://user@mirror.example.invalid/mysql.zip#fragment',
      'https://mirror.example.invalid/mysql.zip',
      'https://mirror.example.invalid/mysql.zip',
    ];

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.map((item) => item.path),
          'error paths',
          containsAll([
            r'$.components[0].artifacts[0].mirrorUrls[0]',
            r'$.components[0].artifacts[0].mirrorUrls[1]',
            r'$.components[0].artifacts[0].mirrorUrls[2]',
            r'$.components[0].artifacts[0].mirrorUrls[4]',
          ]),
        ),
      ),
    );
  });

  test('loads and validates Android SDK package and license metadata', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    fixture['components'] = [...components, _androidSdkFixture()];

    final manifest = loader.fromJson(fixture);
    final android = manifest.componentById('android-sdk')!.androidSdk!;

    expect(android.packages, [
      'platform-tools',
      'platforms;android-36',
      'build-tools;36.0.0',
    ]);
    expect(android.repositoryMirrorUrls, [
      Uri.parse('https://googledownloads.example.invalid/android/repository/'),
    ]);
    expect(android.license.id, 'android-sdk-license');
    expect(
      android.license.url,
      Uri.parse('https://developer.android.com/studio/terms'),
    );
  });

  test('rejects unsafe Android SDK metadata', () {
    final fixture = _validTestFixture();
    final components = fixture['components']! as List<Object?>;
    final android = _androidSdkFixture();
    final metadata = android['androidSdk']! as Map<String, Object?>;
    metadata['packages'] = ['platform-tools', 'platform-tools', 'bad\npackage'];
    metadata['repositoryMirrorUrls'] = [
      'https://dl.google.com/android/repository/',
      'http://mirror.example.invalid/android/repository/',
      'https://mirror.example.invalid/android/repository',
    ];
    final license = metadata['license']! as Map<String, Object?>;
    license['url'] = 'http://example.invalid/license';
    fixture['components'] = [...components, android];

    expect(
      () => loader.fromJson(fixture),
      throwsA(
        isA<RuntimeManifestValidationException>().having(
          (error) => error.errors.map((item) => item.path),
          'error paths',
          containsAll([
            r'$.components[2].androidSdk.packages[1]',
            r'$.components[2].androidSdk.packages[2]',
            r'$.components[2].androidSdk.repositoryMirrorUrls[0]',
            r'$.components[2].androidSdk.repositoryMirrorUrls[1]',
            r'$.components[2].androidSdk.repositoryMirrorUrls[2]',
            r'$.components[2].androidSdk.license.url',
          ]),
        ),
      ),
    );
  });
}

Map<String, Object?> _androidSdkFixture() {
  return {
    'id': 'android-sdk',
    'displayName': 'Android SDK test fixture',
    'version': '36-test',
    'minimumCompatibleVersion': '36',
    'provisioning': 'managed',
    'artifacts': [
      {
        'platform': 'macos',
        'architecture': 'arm64',
        'officialUrl':
            'https://downloads.example.invalid/non-production/android.zip',
        'sha256': 'b' * 64,
        'archiveType': 'zip',
      },
    ],
    'executables': [
      {
        'platform': 'macos',
        'architectures': ['arm64'],
        'path': 'cmdline-tools/latest/bin/sdkmanager',
      },
    ],
    'dependencies': ['jdk'],
    'androidSdk': {
      'packages': [
        'platform-tools',
        'platforms;android-36',
        'build-tools;36.0.0',
      ],
      'repositoryMirrorUrls': [
        'https://googledownloads.example.invalid/android/repository/',
      ],
      'license': {
        'id': 'android-sdk-license',
        'displayName': 'Android SDK License Agreement',
        'url': 'https://developer.android.com/studio/terms',
      },
    },
  };
}

// This fixture is intentionally non-production. Its example.invalid URL and
// repeated test digest must never be copied into a release manifest.
Map<String, Object?> _validTestFixture() {
  return {
    'schemaVersion': 1,
    'components': [
      {
        'id': 'mysql',
        'displayName': 'MySQL test fixture',
        'version': '8.4.0-test',
        'minimumCompatibleVersion': '8.0.0',
        'provisioning': 'managed',
        'artifacts': [
          {
            'platform': 'windows',
            'architecture': 'x64',
            'officialUrl':
                'https://downloads.example.invalid/non-production/mysql.zip',
            'mirrorUrls': [
              'https://mirror.example.invalid/non-production/mysql.zip',
            ],
            'sha256': 'a' * 64,
            'archiveType': 'zip',
            'archiveRoot': 'mysql-test',
            'installSubdirectory': 'runtime',
          },
        ],
        'executables': [
          {
            'platform': 'windows',
            'architectures': ['x64'],
            'path': r'bin\mysql.exe',
          },
        ],
        'dependencies': ['jdk'],
        'service': {
          'serviceName': 'mysql-test-only',
          'defaultPort': 3306,
          'startAutomatically': true,
          'dataDirectory': 'data/mysql-test-only',
          'healthCheckCommand': [r'bin\mysqladmin.exe', 'ping'],
        },
      },
      {
        'id': 'jdk',
        'displayName': 'External JDK test fixture',
        'version': '17-test',
        'minimumCompatibleVersion': '17',
        'provisioning': 'external',
        'artifacts': <Object?>[],
        'executables': [
          {
            'platform': 'macos',
            'architectures': ['x64', 'arm64'],
            'path': '/usr/bin/java',
          },
        ],
        'dependencies': <Object?>[],
      },
    ],
  };
}
