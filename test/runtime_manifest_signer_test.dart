import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/runtime_manifest_signer.dart' as signing_tool;

void main() {
  late Directory temporaryDirectory;
  late StringBuffer stdoutBuffer;
  late StringBuffer stderrBuffer;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'runtime_manifest_signer_test_',
    );
    stdoutBuffer = StringBuffer();
    stderrBuffer = StringBuffer();
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  Future<({File manifest, File signature, String publicKey})>
  createSignedFixture() async {
    final privateKeyFile = File(
      '${temporaryDirectory.path}/fixture.private.json',
    );
    final publicKeyFile = File(
      '${temporaryDirectory.path}/fixture.public.json',
    );
    final manifestFile = File(
      '${temporaryDirectory.path}/fixture.manifest.json',
    );
    final signatureFile = File('${temporaryDirectory.path}/fixture.sig.json');
    await manifestFile.writeAsString('{"schemaVersion":1}\n');
    final generateExitCode = await signing_tool.run(
      [
        'generate-key',
        '--key-id',
        'fixture-key',
        '--private-key',
        privateKeyFile.path,
        '--public-key',
        publicKeyFile.path,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );
    final signExitCode = await signing_tool.run(
      [
        'sign',
        '--private-key',
        privateKeyFile.path,
        '--manifest',
        manifestFile.path,
        '--signature',
        signatureFile.path,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );
    expect((generateExitCode, signExitCode), (0, 0));
    final publicKeyDocument =
        jsonDecode(await publicKeyFile.readAsString()) as Map<String, Object?>;
    stdoutBuffer.clear();
    stderrBuffer.clear();
    return (
      manifest: manifestFile,
      signature: signatureFile,
      publicKey: publicKeyDocument['publicKey']! as String,
    );
  }

  test(
    'generate-key writes explicit Ed25519 private and public key files',
    () async {
      final privateKeyFile = File(
        '${temporaryDirectory.path}/release.private.json',
      );
      final publicKeyFile = File(
        '${temporaryDirectory.path}/release.public.json',
      );

      final exitCode = await signing_tool.run(
        [
          'generate-key',
          '--key-id',
          'release-2026',
          '--private-key',
          privateKeyFile.path,
          '--public-key',
          publicKeyFile.path,
        ],
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      expect(exitCode, 0);
      expect(stderrBuffer.toString(), isEmpty);
      final privateKey = jsonDecode(await privateKeyFile.readAsString()) as Map;
      final publicKey = jsonDecode(await publicKeyFile.readAsString()) as Map;
      expect(privateKey['keyId'], 'release-2026');
      expect(privateKey['algorithm'], 'Ed25519');
      expect(base64Decode(privateKey['privateKey'] as String), hasLength(32));
      expect(base64Decode(privateKey['publicKey'] as String), hasLength(32));
      expect(publicKey, {
        'keyId': 'release-2026',
        'algorithm': 'Ed25519',
        'publicKey': privateKey['publicKey'],
      });
      expect(
        stdoutBuffer.toString(),
        contains(privateKey['publicKey'] as String),
      );
      if (!Platform.isWindows) {
        final mode = (await privateKeyFile.stat()).mode;
        expect(
          mode & 0x3f,
          0,
          reason: 'private key must not be group/world accessible',
        );
      }
    },
  );

  test('generate-key refuses to overwrite an existing key file', () async {
    final privateKeyFile = File(
      '${temporaryDirectory.path}/release.private.json',
    );
    final publicKeyFile = File(
      '${temporaryDirectory.path}/release.public.json',
    );
    await privateKeyFile.writeAsString('existing private key');

    final exitCode = await signing_tool.run(
      [
        'generate-key',
        '--key-id',
        'release-2026',
        '--private-key',
        privateKeyFile.path,
        '--public-key',
        publicKeyFile.path,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );

    expect(exitCode, isNonZero);
    expect(await privateKeyFile.readAsString(), 'existing private key');
    expect(await publicKeyFile.exists(), isFalse);
    expect(stderrBuffer.toString(), contains('already exists'));
  });

  test('sign signs the raw manifest bytes into a detached envelope', () async {
    final privateKeyFile = File(
      '${temporaryDirectory.path}/release.private.json',
    );
    final publicKeyFile = File(
      '${temporaryDirectory.path}/release.public.json',
    );
    expect(
      await signing_tool.run(
        [
          'generate-key',
          '--key-id',
          'release-2026',
          '--private-key',
          privateKeyFile.path,
          '--public-key',
          publicKeyFile.path,
        ],
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      ),
      0,
    );
    stdoutBuffer.clear();
    stderrBuffer.clear();
    final manifestFile = File('${temporaryDirectory.path}/manifest.json');
    final manifestBytes = utf8.encode('{\n  "schemaVersion": 1\n}\n');
    await manifestFile.writeAsBytes(manifestBytes);
    final signatureFile = File('${temporaryDirectory.path}/manifest.sig.json');

    final exitCode = await signing_tool.run(
      [
        'sign',
        '--private-key',
        privateKeyFile.path,
        '--manifest',
        manifestFile.path,
        '--signature',
        signatureFile.path,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );

    expect(exitCode, 0);
    expect(stderrBuffer.toString(), isEmpty);
    final envelope =
        jsonDecode(await signatureFile.readAsString()) as Map<String, Object?>;
    expect(envelope.keys, unorderedEquals(['keyId', 'signature']));
    expect(envelope['keyId'], 'release-2026');
    final publicKeyDocument =
        jsonDecode(await publicKeyFile.readAsString()) as Map<String, Object?>;
    final publicKey = SimplePublicKey(
      base64Decode(publicKeyDocument['publicKey']! as String),
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        manifestBytes,
        signature: Signature(
          base64Decode(envelope['signature']! as String),
          publicKey: publicKey,
        ),
      ),
      isTrue,
    );
  });

  test('verify accepts a valid signature with a base64 public key', () async {
    final fixture = await createSignedFixture();

    final exitCode = await signing_tool.run(
      [
        'verify',
        '--manifest',
        fixture.manifest.path,
        '--signature',
        fixture.signature.path,
        '--public-key',
        fixture.publicKey,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );

    expect(exitCode, 0);
    expect(stderrBuffer.toString(), isEmpty);
    expect(stdoutBuffer.toString(), contains('verified'));
  });

  test('verify rejects a manifest changed after signing', () async {
    final fixture = await createSignedFixture();
    await fixture.manifest.writeAsString('{"schemaVersion":2}\n');

    final exitCode = await signing_tool.run(
      [
        'verify',
        '--manifest',
        fixture.manifest.path,
        '--signature',
        fixture.signature.path,
        '--public-key',
        fixture.publicKey,
      ],
      stdoutSink: stdoutBuffer,
      stderrSink: stderrBuffer,
    );

    expect(exitCode, 65);
    expect(stdoutBuffer.toString(), isEmpty);
    expect(stderrBuffer.toString(), contains('verification failed'));
  });

  test(
    'verify rejects an unexpected key id with an inline public key',
    () async {
      final fixture = await createSignedFixture();

      final exitCode = await signing_tool.run(
        [
          'verify',
          '--manifest',
          fixture.manifest.path,
          '--signature',
          fixture.signature.path,
          '--public-key',
          fixture.publicKey,
          '--key-id',
          'production-key',
        ],
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      expect(exitCode, 64);
      expect(stdoutBuffer.toString(), isEmpty);
      expect(stderrBuffer.toString(), contains('does not match expected key'));
    },
  );
}
