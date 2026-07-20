import 'dart:convert';

import 'remote_runtime_manifest_loader.dart';

final class RemoteManifestReleaseConfigurationException implements Exception {
  const RemoteManifestReleaseConfigurationException({
    required this.environmentKey,
    required this.message,
  });

  final String environmentKey;
  final String message;

  @override
  String toString() {
    return 'Remote manifest release configuration error for '
        '$environmentKey: $message';
  }
}

final class RemoteManifestReleaseConfiguration {
  RemoteManifestReleaseConfiguration._({
    required this.manifestUri,
    required this.signatureUri,
    required this.signingKeyId,
    required List<int> signingPublicKeyBytes,
  }) : signingPublicKeyBytes = List<int>.unmodifiable(signingPublicKeyBytes);

  static const manifestUrlEnvironmentKey = 'NISHI_RUNTIME_MANIFEST_URL';
  static const signatureUrlEnvironmentKey =
      'NISHI_RUNTIME_MANIFEST_SIGNATURE_URL';
  static const signingKeyIdEnvironmentKey = 'NISHI_MANIFEST_SIGNING_KEY_ID';
  static const signingPublicKeyEnvironmentKey =
      'NISHI_MANIFEST_SIGNING_PUBLIC_KEY_BASE64';

  static const defaultManifestUrl =
      'https://github.com/cacube/nishi/releases/latest/download/'
      'runtime-manifest.json';
  static const defaultSignatureUrl =
      'https://github.com/cacube/nishi/releases/latest/download/'
      'runtime-manifest.sig.json';
  static const defaultSigningKeyId = 'nishi-release-2026-01';
  static const defaultSigningPublicKeyBase64 =
      'oGGZLXQMCkOFmfFbbyEd7S6ht5/f5zSm5qtK551FGis=';

  factory RemoteManifestReleaseConfiguration.fromEnvironment() {
    return RemoteManifestReleaseConfiguration.fromValues(
      manifestUrl: const String.fromEnvironment(
        manifestUrlEnvironmentKey,
        defaultValue: defaultManifestUrl,
      ),
      signatureUrl: const String.fromEnvironment(
        signatureUrlEnvironmentKey,
        defaultValue: defaultSignatureUrl,
      ),
      signingKeyId: const String.fromEnvironment(
        signingKeyIdEnvironmentKey,
        defaultValue: defaultSigningKeyId,
      ),
      signingPublicKeyBase64: const String.fromEnvironment(
        signingPublicKeyEnvironmentKey,
        defaultValue: defaultSigningPublicKeyBase64,
      ),
    );
  }

  factory RemoteManifestReleaseConfiguration.fromValues({
    String manifestUrl = defaultManifestUrl,
    String signatureUrl = defaultSignatureUrl,
    required String signingKeyId,
    required String signingPublicKeyBase64,
  }) {
    if (signingKeyId.trim().isEmpty) {
      throw const RemoteManifestReleaseConfigurationException(
        environmentKey: signingKeyIdEnvironmentKey,
        message: 'must be provided with --dart-define',
      );
    }

    if (signingPublicKeyBase64.isEmpty) {
      throw const RemoteManifestReleaseConfigurationException(
        environmentKey: signingPublicKeyEnvironmentKey,
        message: 'must be provided with --dart-define',
      );
    }
    final List<int> signingPublicKeyBytes;
    try {
      signingPublicKeyBytes = base64Decode(signingPublicKeyBase64);
    } on FormatException {
      throw const RemoteManifestReleaseConfigurationException(
        environmentKey: signingPublicKeyEnvironmentKey,
        message: 'must be valid base64',
      );
    }
    if (signingPublicKeyBytes.length != 32) {
      throw const RemoteManifestReleaseConfigurationException(
        environmentKey: signingPublicKeyEnvironmentKey,
        message: 'must decode to exactly 32 bytes for Ed25519',
      );
    }

    return RemoteManifestReleaseConfiguration._(
      manifestUri: _parseHttpsEndpoint(
        manifestUrl,
        environmentKey: manifestUrlEnvironmentKey,
      ),
      signatureUri: _parseHttpsEndpoint(
        signatureUrl,
        environmentKey: signatureUrlEnvironmentKey,
      ),
      signingKeyId: signingKeyId,
      signingPublicKeyBytes: signingPublicKeyBytes,
    );
  }

  final Uri manifestUri;
  final Uri signatureUri;
  final String signingKeyId;
  final List<int> signingPublicKeyBytes;

  /// Creates a loader that trusts only the release key in this configuration.
  /// The caller owns the loader and must close it after use.
  RemoteRuntimeManifestLoader createLoader() {
    return RemoteRuntimeManifestLoader(
      trustedPublicKeys: {signingKeyId: signingPublicKeyBytes},
    );
  }
}

Uri _parseHttpsEndpoint(String source, {required String environmentKey}) {
  final uri = Uri.tryParse(source);
  if (source != source.trim() ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw RemoteManifestReleaseConfigurationException(
      environmentKey: environmentKey,
      message: 'must be an HTTPS URL without credentials or a fragment',
    );
  }
  return uri;
}
