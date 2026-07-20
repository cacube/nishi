import 'dart:collection';

import 'package:cryptography/cryptography.dart';

final class ManifestSigningKeyring {
  ManifestSigningKeyring.fromBytes(Map<String, List<int>> publicKeys)
    : _publicKeys = UnmodifiableMapView(
        publicKeys.map((keyId, bytes) {
          if (keyId.trim().isEmpty) {
            throw ArgumentError.value(keyId, 'publicKeys', 'keyId is blank');
          }
          if (bytes.length != 32) {
            throw ArgumentError.value(
              bytes.length,
              'publicKeys[$keyId]',
              'Ed25519 public keys must contain exactly 32 bytes',
            );
          }
          return MapEntry(
            keyId,
            SimplePublicKey(
              List<int>.unmodifiable(bytes),
              type: KeyPairType.ed25519,
            ),
          );
        }),
      ) {
    if (_publicKeys.isEmpty) {
      throw ArgumentError.value(
        publicKeys,
        'publicKeys',
        'at least one trusted Ed25519 key is required',
      );
    }
  }

  final Map<String, SimplePublicKey> _publicKeys;

  SimplePublicKey? operator [](String keyId) => _publicKeys[keyId];
}
