import 'dart:convert';

import 'package:dev_environment_manager/src/manifest_security/manifest_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteManifestReleaseConfiguration', () {
    test('uses the nishi latest-release endpoints by default', () {
      final configuration = RemoteManifestReleaseConfiguration.fromValues(
        signingKeyId: 'release-key-2026',
        signingPublicKeyBase64: base64Encode(List<int>.filled(32, 7)),
      );

      expect(
        configuration.manifestUri,
        Uri.parse(
          'https://github.com/cacube/nishi/releases/latest/download/'
          'runtime-manifest.json',
        ),
      );
      expect(
        configuration.signatureUri,
        Uri.parse(
          'https://github.com/cacube/nishi/releases/latest/download/'
          'runtime-manifest.sig.json',
        ),
      );
    });

    test('fails explicitly when the signing key is not configured', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          signingKeyId: '',
          signingPublicKeyBase64: '',
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.signingKeyIdEnvironmentKey,
          ),
        ),
      );
    });

    test('fails explicitly when the public key is not configured', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          signingKeyId: 'release-key-2026',
          signingPublicKeyBase64: '',
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.signingPublicKeyEnvironmentKey,
          ),
        ),
      );
    });

    test('rejects malformed base64 public key material', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          signingKeyId: 'release-key-2026',
          signingPublicKeyBase64: 'not base64!',
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.signingPublicKeyEnvironmentKey,
          ),
        ),
      );
    });

    test('rejects a public key that is not 32 bytes', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          signingKeyId: 'release-key-2026',
          signingPublicKeyBase64: base64Encode(List<int>.filled(31, 7)),
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>()
              .having(
                (error) => error.environmentKey,
                'environmentKey',
                RemoteManifestReleaseConfiguration
                    .signingPublicKeyEnvironmentKey,
              )
              .having(
                (error) => error.message,
                'message',
                contains('32 bytes'),
              ),
        ),
      );
    });

    test('production environment entry point fails without dart-defines', () {
      expect(
        RemoteManifestReleaseConfiguration.fromEnvironment,
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.signingKeyIdEnvironmentKey,
          ),
        ),
      );
    });

    test('rejects an insecure manifest URL', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          manifestUrl: 'http://example.com/runtime-manifest.json',
          signingKeyId: 'release-key-2026',
          signingPublicKeyBase64: base64Encode(List<int>.filled(32, 7)),
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.manifestUrlEnvironmentKey,
          ),
        ),
      );
    });

    test('reports the signature URL define when that endpoint is invalid', () {
      expect(
        () => RemoteManifestReleaseConfiguration.fromValues(
          signatureUrl: 'https://example.com/runtime-manifest.sig.json#bad',
          signingKeyId: 'release-key-2026',
          signingPublicKeyBase64: base64Encode(List<int>.filled(32, 7)),
        ),
        throwsA(
          isA<RemoteManifestReleaseConfigurationException>().having(
            (error) => error.environmentKey,
            'environmentKey',
            RemoteManifestReleaseConfiguration.signatureUrlEnvironmentKey,
          ),
        ),
      );
    });

    test('creates a remote loader with the configured trusted key', () {
      final configuration = RemoteManifestReleaseConfiguration.fromValues(
        signingKeyId: 'release-key-2026',
        signingPublicKeyBase64: base64Encode(List<int>.filled(32, 7)),
      );

      final loader = configuration.createLoader();
      addTearDown(() => loader.close(force: true));

      expect(loader, isA<RemoteRuntimeManifestLoader>());
    });
  });
}
