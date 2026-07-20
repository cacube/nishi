import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../runtime_manifest/runtime_manifest.dart';
import 'manifest_signing_keyring.dart';
import 'remote_manifest_exceptions.dart';

final class RemoteRuntimeManifestLoader {
  RemoteRuntimeManifestLoader({
    required Map<String, List<int>> trustedPublicKeys,
    HttpClient? httpClient,
    RuntimeManifestLoader manifestLoader = const RuntimeManifestLoader(),
    Ed25519? signatureAlgorithm,
    this.timeout = const Duration(seconds: 20),
    this.maxManifestBytes = 2 * 1024 * 1024,
    this.maxSignatureBytes = 16 * 1024,
    this.allowInsecureForTesting = false,
  }) : _keyring = ManifestSigningKeyring.fromBytes(trustedPublicKeys),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null,
       _manifestLoader = manifestLoader,
       _signatureAlgorithm = signatureAlgorithm ?? Ed25519() {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    if (maxManifestBytes <= 0) {
      throw ArgumentError.value(
        maxManifestBytes,
        'maxManifestBytes',
        'must be positive',
      );
    }
    if (maxSignatureBytes <= 0) {
      throw ArgumentError.value(
        maxSignatureBytes,
        'maxSignatureBytes',
        'must be positive',
      );
    }
  }

  final ManifestSigningKeyring _keyring;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final RuntimeManifestLoader _manifestLoader;
  final Ed25519 _signatureAlgorithm;
  final Duration timeout;
  final int maxManifestBytes;
  final int maxSignatureBytes;
  final bool allowInsecureForTesting;

  /// Loads a manifest whose detached signature endpoint contains JSON in the
  /// form `{"keyId":"release-key","signature":"<base64>"}`.
  Future<RuntimeManifest> load({
    required Uri manifestUri,
    required Uri signatureUri,
  }) async {
    _validateEndpoint(manifestUri);
    _validateEndpoint(signatureUri);

    final manifestBytes = await _fetchBytes(
      manifestUri,
      resource: RemoteManifestResource.manifest,
      maximumBytes: maxManifestBytes,
    );
    final signatureBytes = await _fetchBytes(
      signatureUri,
      resource: RemoteManifestResource.signature,
      maximumBytes: maxSignatureBytes,
    );
    final envelope = _decodeSignatureEnvelope(signatureBytes);
    final publicKey = _keyring[envelope.keyId];
    if (publicKey == null) {
      throw UnknownManifestSigningKeyException(envelope.keyId);
    }
    if (envelope.signature.length != 64) {
      throw InvalidManifestSignatureException(envelope.keyId);
    }

    final isValid = await _signatureAlgorithm.verify(
      manifestBytes,
      signature: Signature(envelope.signature, publicKey: publicKey),
    );
    if (!isValid) {
      throw InvalidManifestSignatureException(envelope.keyId);
    }

    final String source;
    try {
      source = utf8.decode(manifestBytes, allowMalformed: false);
    } on FormatException {
      throw InvalidManifestEncodingException();
    }
    return _manifestLoader.decode(source);
  }

  void close({bool force = false}) {
    if (_ownsHttpClient) {
      _httpClient.close(force: force);
    }
  }

  void _validateEndpoint(Uri uri) {
    final isHttps = uri.scheme == 'https';
    final parsedAddress = InternetAddress.tryParse(uri.host);
    final isLoopbackHost =
        uri.host == 'localhost' || (parsedAddress?.isLoopback ?? false);
    final isAllowedTestHttp =
        allowInsecureForTesting && uri.scheme == 'http' && isLoopbackHost;
    if ((!isHttps && !isAllowedTestHttp) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw InsecureManifestUriException(uri);
    }
  }

  Future<List<int>> _fetchBytes(
    Uri uri, {
    required RemoteManifestResource resource,
    required int maximumBytes,
  }) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        var currentUri = uri;
        var redirectCount = 0;
        late HttpClientResponse response;
        while (true) {
          _validateEndpoint(currentUri);
          request = await _httpClient.getUrl(currentUri);
          request!.followRedirects = false;
          response = await request!.close();
          if (!_isRedirect(response.statusCode)) break;

          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || redirectCount >= 5) {
            throw RemoteManifestHttpException(
              uri: currentUri,
              resource: resource,
              statusCode: response.statusCode,
            );
          }
          final redirectUri = currentUri.resolve(location);
          _validateEndpoint(redirectUri);
          await response.drain<void>();
          currentUri = redirectUri;
          redirectCount += 1;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw RemoteManifestHttpException(
            uri: currentUri,
            resource: resource,
            statusCode: response.statusCode,
          );
        }
        if (response.contentLength > maximumBytes) {
          request!.abort();
          throw RemoteManifestResponseTooLargeException(
            uri: uri,
            resource: resource,
            maximumBytes: maximumBytes,
          );
        }

        final builder = BytesBuilder(copy: false);
        var byteCount = 0;
        await for (final chunk in response) {
          byteCount += chunk.length;
          if (byteCount > maximumBytes) {
            request!.abort();
            throw RemoteManifestResponseTooLargeException(
              uri: uri,
              resource: resource,
              maximumBytes: maximumBytes,
            );
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      })().timeout(
        timeout,
        onTimeout: () {
          request?.abort();
          throw RemoteManifestTimeoutException(
            uri: uri,
            resource: resource,
            timeout: timeout,
          );
        },
      );
    } on RemoteManifestException {
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw RemoteManifestTimeoutException(
        uri: uri,
        resource: resource,
        timeout: timeout,
      );
    } on IOException catch (error) {
      throw RemoteManifestNetworkException(
        uri: uri,
        resource: resource,
        cause: error,
      );
    }
  }

  bool _isRedirect(int statusCode) {
    return statusCode == HttpStatus.movedPermanently ||
        statusCode == HttpStatus.found ||
        statusCode == HttpStatus.seeOther ||
        statusCode == HttpStatus.temporaryRedirect ||
        statusCode == HttpStatus.permanentRedirect;
  }

  _SignatureEnvelope _decodeSignatureEnvelope(List<int> bytes) {
    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw InvalidManifestSignatureEnvelopeException('must be valid UTF-8');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw InvalidManifestSignatureEnvelopeException('must be valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw InvalidManifestSignatureEnvelopeException('must be a JSON object');
    }
    final keyId = decoded['keyId'];
    final signatureSource = decoded['signature'];
    if (keyId is! String || keyId.trim().isEmpty) {
      throw InvalidManifestSignatureEnvelopeException(
        'keyId must be a non-blank string',
      );
    }
    if (signatureSource is! String || signatureSource.isEmpty) {
      throw InvalidManifestSignatureEnvelopeException(
        'signature must be a non-empty base64 string',
      );
    }

    final List<int> signature;
    try {
      signature = base64Decode(signatureSource);
    } on FormatException {
      throw InvalidManifestSignatureEnvelopeException(
        'signature must be valid base64',
      );
    }
    return _SignatureEnvelope(keyId: keyId, signature: signature);
  }
}

final class _SignatureEnvelope {
  const _SignatureEnvelope({required this.keyId, required this.signature});

  final String keyId;
  final List<int> signature;
}
