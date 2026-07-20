import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dev_environment_manager/src/manifest_security/manifest_security.dart';
import 'package:dev_environment_manager/src/runtime_manifest/runtime_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Ed25519 algorithm;
  late SimpleKeyPair keyPair;
  late SimplePublicKey publicKey;
  late List<int> manifestBytes;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    algorithm = Ed25519();
    keyPair = await algorithm.newKeyPair();
    publicKey = await keyPair.extractPublicKey();
    manifestBytes = utf8.encode(jsonEncode(_validManifestFixture()));
  });

  tearDown(() async {
    await server.close(force: true);
  });

  RemoteRuntimeManifestLoader testLoader(List<int> trustedKey) {
    return RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': trustedKey},
      allowInsecureForTesting: true,
    );
  }

  Uri serverUri(String path) {
    return Uri.parse('http://${server.address.host}:${server.port}$path');
  }

  void serve({
    required List<int> manifest,
    required Map<String, Object?> signatureEnvelope,
  }) {
    server.listen((request) async {
      if (request.uri.path == '/manifest.json') {
        request.response.add(manifest);
      } else {
        request.response.write(jsonEncode(signatureEnvelope));
      }
      await request.response.close();
    });
  }

  test('verifies the raw bytes before loading a remote manifest', () async {
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
    server.listen((request) async {
      if (request.uri.path == '/manifest.json') {
        request.response.add(manifestBytes);
      } else {
        request.response.write(
          jsonEncode({
            'keyId': 'test-key',
            'signature': base64Encode(signature.bytes),
          }),
        );
      }
      await request.response.close();
    });
    final httpClient = HttpClient();
    addTearDown(() => httpClient.close(force: true));
    final loader = RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': publicKey.bytes},
      httpClient: httpClient,
      allowInsecureForTesting: true,
    );

    final manifest = await loader.load(
      manifestUri: serverUri('/manifest.json'),
      signatureUri: serverUri('/manifest.sig'),
    );

    expect(manifest.schemaVersion, 1);
    expect(manifest.componentById('git')?.version, '2.52.0-test');
  });

  test('rejects HTTP unless it is explicitly enabled for testing', () async {
    var requests = 0;
    server.listen((request) async {
      requests += 1;
      await request.response.close();
    });
    final loader = RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': publicKey.bytes},
    );

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(isA<InsecureManifestUriException>()),
    );
    expect(requests, 0);
    loader.close(force: true);
  });

  test('testing override only permits loopback HTTP endpoints', () async {
    final loader = RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': publicKey.bytes},
      allowInsecureForTesting: true,
    );

    await expectLater(
      loader.load(
        manifestUri: Uri.parse('http://example.invalid/manifest.json'),
        signatureUri: Uri.parse('http://example.invalid/manifest.sig'),
      ),
      throwsA(isA<InsecureManifestUriException>()),
    );
    loader.close(force: true);
  });

  test('rejects an unknown signing key', () async {
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
    serve(
      manifest: manifestBytes,
      signatureEnvelope: {
        'keyId': 'retired-key',
        'signature': base64Encode(signature.bytes),
      },
    );
    final loader = testLoader(publicKey.bytes);

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(
        isA<UnknownManifestSigningKeyException>().having(
          (error) => error.keyId,
          'keyId',
          'retired-key',
        ),
      ),
    );
    loader.close(force: true);
  });

  test('rejects invalid base64 in the detached signature', () async {
    serve(
      manifest: manifestBytes,
      signatureEnvelope: {'keyId': 'test-key', 'signature': 'not base64 !'},
    );
    final loader = testLoader(publicKey.bytes);

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(isA<InvalidManifestSignatureEnvelopeException>()),
    );
    loader.close(force: true);
  });

  test('rejects a signature that does not match the raw response', () async {
    final signature = await algorithm.sign(
      utf8.encode('different bytes'),
      keyPair: keyPair,
    );
    serve(
      manifest: utf8.encode('{'),
      signatureEnvelope: {
        'keyId': 'test-key',
        'signature': base64Encode(signature.bytes),
      },
    );
    final loader = testLoader(publicKey.bytes);

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(isA<InvalidManifestSignatureException>()),
    );
    loader.close(force: true);
  });

  test('passes a validly signed payload to RuntimeManifestLoader', () async {
    final invalidManifest = utf8.encode('{');
    final signature = await algorithm.sign(invalidManifest, keyPair: keyPair);
    serve(
      manifest: invalidManifest,
      signatureEnvelope: {
        'keyId': 'test-key',
        'signature': base64Encode(signature.bytes),
      },
    );
    final loader = testLoader(publicKey.bytes);

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(isA<RuntimeManifestValidationException>()),
    );
    loader.close(force: true);
  });

  test('times out a stalled response', () async {
    final releaseResponse = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/manifest.json') {
        await releaseResponse.future;
      }
      try {
        await request.response.close();
      } on Object {
        // The client aborts the request when its deadline expires.
      }
    });
    final loader = RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': publicKey.bytes},
      timeout: const Duration(milliseconds: 50),
      allowInsecureForTesting: true,
    );

    try {
      await expectLater(
        loader.load(
          manifestUri: serverUri('/manifest.json'),
          signatureUri: serverUri('/manifest.sig'),
        ),
        throwsA(isA<RemoteManifestTimeoutException>()),
      );
    } finally {
      releaseResponse.complete();
      loader.close(force: true);
    }
  });

  test(
    'rejects a manifest response larger than its configured limit',
    () async {
      server.listen((request) async {
        request.response.contentLength = manifestBytes.length;
        request.response.add(manifestBytes);
        await request.response.close();
      });
      final loader = RemoteRuntimeManifestLoader(
        trustedPublicKeys: {'test-key': publicKey.bytes},
        maxManifestBytes: manifestBytes.length - 1,
        allowInsecureForTesting: true,
      );

      await expectLater(
        loader.load(
          manifestUri: serverUri('/manifest.json'),
          signatureUri: serverUri('/manifest.sig'),
        ),
        throwsA(
          isA<RemoteManifestResponseTooLargeException>().having(
            (error) => error.resource,
            'resource',
            RemoteManifestResource.manifest,
          ),
        ),
      );
      loader.close(force: true);
    },
  );

  test('rejects an oversized detached signature response', () async {
    server.listen((request) async {
      if (request.uri.path == '/manifest.json') {
        request.response.add(manifestBytes);
      } else {
        request.response.add(List<int>.filled(128, 97));
      }
      await request.response.close();
    });
    final loader = RemoteRuntimeManifestLoader(
      trustedPublicKeys: {'test-key': publicKey.bytes},
      maxSignatureBytes: 64,
      allowInsecureForTesting: true,
    );

    await expectLater(
      loader.load(
        manifestUri: serverUri('/manifest.json'),
        signatureUri: serverUri('/manifest.sig'),
      ),
      throwsA(
        isA<RemoteManifestResponseTooLargeException>().having(
          (error) => error.resource,
          'resource',
          RemoteManifestResource.signature,
        ),
      ),
    );
    loader.close(force: true);
  });
}

Map<String, Object?> _validManifestFixture() {
  return {
    'schemaVersion': 1,
    'components': [
      {
        'id': 'git',
        'displayName': 'Git test fixture',
        'version': '2.52.0-test',
        'minimumCompatibleVersion': '2.40.0',
        'provisioning': 'external',
        'artifacts': <Object?>[],
        'executables': [
          {
            'platform': 'macos',
            'architectures': ['x64', 'arm64'],
            'path': '/usr/bin/git',
          },
        ],
        'dependencies': <Object?>[],
      },
    ],
  };
}
