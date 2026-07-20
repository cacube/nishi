import 'dart:io';

enum RemoteManifestResource { manifest, signature }

sealed class RemoteManifestException implements Exception {
  const RemoteManifestException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InsecureManifestUriException extends RemoteManifestException {
  InsecureManifestUriException(this.uri)
    : super('Remote manifest endpoints must use HTTPS: $uri');

  final Uri uri;
}

final class RemoteManifestTimeoutException extends RemoteManifestException {
  RemoteManifestTimeoutException({
    required this.uri,
    required this.resource,
    required this.timeout,
  }) : super('Timed out fetching ${resource.name} from $uri after $timeout');

  final Uri uri;
  final RemoteManifestResource resource;
  final Duration timeout;
}

final class RemoteManifestNetworkException extends RemoteManifestException {
  RemoteManifestNetworkException({
    required this.uri,
    required this.resource,
    required this.cause,
  }) : super('Could not fetch ${resource.name} from $uri: $cause');

  final Uri uri;
  final RemoteManifestResource resource;
  final IOException cause;
}

final class RemoteManifestHttpException extends RemoteManifestException {
  RemoteManifestHttpException({
    required this.uri,
    required this.resource,
    required this.statusCode,
  }) : super('Fetching ${resource.name} from $uri returned HTTP $statusCode');

  final Uri uri;
  final RemoteManifestResource resource;
  final int statusCode;
}

final class RemoteManifestResponseTooLargeException
    extends RemoteManifestException {
  RemoteManifestResponseTooLargeException({
    required this.uri,
    required this.resource,
    required this.maximumBytes,
  }) : super('${resource.name} response from $uri exceeds $maximumBytes bytes');

  final Uri uri;
  final RemoteManifestResource resource;
  final int maximumBytes;
}

final class InvalidManifestSignatureEnvelopeException
    extends RemoteManifestException {
  InvalidManifestSignatureEnvelopeException(String reason)
    : super('Invalid detached signature envelope: $reason');
}

final class UnknownManifestSigningKeyException extends RemoteManifestException {
  UnknownManifestSigningKeyException(this.keyId)
    : super('Detached signature uses unknown keyId "$keyId"');

  final String keyId;
}

final class InvalidManifestSignatureException extends RemoteManifestException {
  InvalidManifestSignatureException(this.keyId)
    : super('Manifest signature verification failed for keyId "$keyId"');

  final String keyId;
}

final class InvalidManifestEncodingException extends RemoteManifestException {
  InvalidManifestEncodingException()
    : super('Verified manifest bytes are not valid UTF-8');
}
