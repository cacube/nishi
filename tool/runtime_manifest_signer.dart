import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}

Future<int> run(
  List<String> arguments, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) async {
  final output = stdoutSink ?? stdout;
  final errors = stderrSink ?? stderr;
  if (arguments.isEmpty) {
    errors.writeln(_usage);
    return 64;
  }

  try {
    switch (arguments.first) {
      case 'generate-key':
        final options = _Options.parse(arguments.skip(1));
        await _generateKey(options);
        final publicKeyFile = File(options.requiredValue('--public-key'));
        final publicKey =
            jsonDecode(await publicKeyFile.readAsString())
                as Map<String, Object?>;
        output.writeln('publicKeyBase64=${publicKey['publicKey']}');
        return 0;
      case 'sign':
        final options = _Options.parse(arguments.skip(1));
        await _sign(options);
        output.writeln('Manifest signature written successfully.');
        return 0;
      case 'verify':
        final options = _Options.parse(arguments.skip(1));
        await _verify(options);
        output.writeln('Manifest signature verified successfully.');
        return 0;
      default:
        errors.writeln('Unknown command: ${arguments.first}');
        errors.writeln(_usage);
        return 64;
    }
  } on _ManifestVerificationException catch (error) {
    errors.writeln(error.message);
    return 65;
  } on FormatException catch (error) {
    errors.writeln(error.message);
    return 64;
  } on FileSystemException catch (error) {
    errors.writeln(error.message);
    return 74;
  }
}

Future<void> _verify(_Options options) async {
  final manifestFile = File(options.requiredValue('--manifest'));
  final signatureFile = File(options.requiredValue('--signature'));
  final envelope = await _readJsonObject(signatureFile, 'signature');
  final keyId = _requiredString(envelope, 'keyId', 'signature');
  final signatureBytes = _decodeBase64Field(
    envelope,
    'signature',
    'signature',
    expectedLength: 64,
  );
  final inlinePublicKey = options.value('--public-key');
  final publicKeyPath = options.value('--public-key-file');
  if ((inlinePublicKey == null) == (publicKeyPath == null)) {
    throw const FormatException(
      'Specify exactly one of --public-key or --public-key-file',
    );
  }

  final List<int> publicKeyBytes;
  if (inlinePublicKey != null) {
    final expectedKeyId = options.value('--key-id');
    if (expectedKeyId != null && expectedKeyId != keyId) {
      throw FormatException(
        'Signature keyId "$keyId" does not match expected key '
        '"$expectedKeyId"',
      );
    }
    publicKeyBytes = _decodeBase64(
      inlinePublicKey,
      '--public-key',
      expectedLength: 32,
    );
  } else {
    final publicKeyDocument = await _readJsonObject(
      File(publicKeyPath!),
      'public key',
    );
    if (_requiredString(publicKeyDocument, 'algorithm', 'public key') !=
        'Ed25519') {
      throw const FormatException(
        'Public key algorithm must be exactly "Ed25519"',
      );
    }
    final publicKeyId = _requiredString(
      publicKeyDocument,
      'keyId',
      'public key',
    );
    if (publicKeyId != keyId) {
      throw FormatException(
        'Signature keyId "$keyId" does not match public key "$publicKeyId"',
      );
    }
    publicKeyBytes = _decodeBase64Field(
      publicKeyDocument,
      'publicKey',
      'public key',
      expectedLength: 32,
    );
  }

  final isValid = await Ed25519().verify(
    await manifestFile.readAsBytes(),
    signature: Signature(
      signatureBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    ),
  );
  if (!isValid) {
    throw _ManifestVerificationException(
      'Manifest signature verification failed for keyId "$keyId"',
    );
  }
}

final class _ManifestVerificationException implements Exception {
  const _ManifestVerificationException(this.message);

  final String message;
}

Future<void> _sign(_Options options) async {
  final privateKeyFile = File(options.requiredValue('--private-key'));
  final manifestFile = File(options.requiredValue('--manifest'));
  final signatureFile = File(options.requiredValue('--signature'));
  final keyDocument = await _readJsonObject(privateKeyFile, 'private key');
  final keyId = _requiredString(keyDocument, 'keyId', 'private key');
  if (_requiredString(keyDocument, 'algorithm', 'private key') != 'Ed25519') {
    throw const FormatException(
      'Private key algorithm must be exactly "Ed25519"',
    );
  }
  final privateKeyBytes = _decodeBase64Field(
    keyDocument,
    'privateKey',
    'private key',
    expectedLength: 32,
  );
  final publicKeyBytes = _decodeBase64Field(
    keyDocument,
    'publicKey',
    'private key',
    expectedLength: 32,
  );
  final keyPair = SimpleKeyPairData(
    privateKeyBytes,
    publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );
  try {
    final manifestBytes = await manifestFile.readAsBytes();
    final signature = await Ed25519().sign(manifestBytes, keyPair: keyPair);
    await signatureFile.writeAsString(
      '${jsonEncode({'keyId': keyId, 'signature': base64Encode(signature.bytes)})}\n',
    );
  } finally {
    keyPair.destroy();
  }
}

Future<void> _generateKey(_Options options) async {
  final keyId = options.requiredValue('--key-id');
  if (keyId.trim().isEmpty) {
    throw const FormatException('--key-id must not be blank');
  }
  final privateKeyFile = File(options.requiredValue('--private-key'));
  final publicKeyFile = File(options.requiredValue('--public-key'));
  for (final keyFile in [privateKeyFile, publicKeyFile]) {
    if (await keyFile.exists()) {
      throw FileSystemException('Key file already exists', keyFile.path);
    }
  }
  final keyPair = await Ed25519().newKeyPair();
  final extractedKeyPair = await keyPair.extract();
  try {
    final publicKeyBase64 = base64Encode(extractedKeyPair.publicKey.bytes);
    await privateKeyFile.writeAsString(
      '${jsonEncode({'keyId': keyId, 'algorithm': 'Ed25519', 'privateKey': base64Encode(extractedKeyPair.bytes), 'publicKey': publicKeyBase64})}\n',
    );
    await publicKeyFile.writeAsString(
      '${jsonEncode({'keyId': keyId, 'algorithm': 'Ed25519', 'publicKey': publicKeyBase64})}\n',
    );
  } finally {
    extractedKeyPair.destroy();
  }
}

Future<Map<String, Object?>> _readJsonObject(
  File file,
  String description,
) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on FormatException {
    throw FormatException('$description file must contain valid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$description file must contain a JSON object');
  }
  return decoded;
}

String _requiredString(
  Map<String, Object?> document,
  String field,
  String description,
) {
  final value = document[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(
      '$description field "$field" must be a non-blank string',
    );
  }
  return value;
}

List<int> _decodeBase64Field(
  Map<String, Object?> document,
  String field,
  String description, {
  required int expectedLength,
}) {
  final source = _requiredString(document, field, description);
  return _decodeBase64(
    source,
    '$description field "$field"',
    expectedLength: expectedLength,
  );
}

List<int> _decodeBase64(
  String source,
  String description, {
  required int expectedLength,
}) {
  final List<int> bytes;
  try {
    bytes = base64Decode(source);
  } on FormatException {
    throw FormatException('$description must contain valid base64');
  }
  if (bytes.length != expectedLength) {
    throw FormatException(
      '$description must decode to exactly $expectedLength bytes',
    );
  }
  return bytes;
}

final class _Options {
  _Options(this._values);

  factory _Options.parse(Iterable<String> arguments) {
    final values = <String, String>{};
    final iterator = arguments.iterator;
    while (iterator.moveNext()) {
      final option = iterator.current;
      if (!option.startsWith('--')) {
        throw FormatException('Unexpected argument: $option');
      }
      if (!iterator.moveNext()) {
        throw FormatException('Missing value for $option');
      }
      values[option] = iterator.current;
    }
    return _Options(values);
  }

  final Map<String, String> _values;

  String? value(String name) => _values[name];

  String requiredValue(String name) {
    final value = _values[name];
    if (value == null || value.isEmpty) {
      throw FormatException('Missing required option: $name');
    }
    return value;
  }
}

const _usage = '''
Usage:
  dart run tool/runtime_manifest_signer.dart generate-key --key-id <id> --private-key <path> --public-key <path>
  dart run tool/runtime_manifest_signer.dart sign --private-key <path> --manifest <path> --signature <path>
  dart run tool/runtime_manifest_signer.dart verify --manifest <path> --signature <path> (--public-key <base64> [--key-id <id>] | --public-key-file <path>)
''';
