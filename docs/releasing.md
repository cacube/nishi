# Release and Runtime Manifest Signing

Nishi downloads runtime metadata from GitHub Releases. Runtime binaries remain
on their vendors' official HTTPS download endpoints; GitHub Releases contains
only the signed manifest and its detached signature envelope.

## Trust Model

- Ed25519 authenticates the exact bytes of `runtime-manifest.json`.
- Every vendor artifact in the manifest has an expected SHA-256 digest. The app
  verifies that digest after download and before installation.
- A signature does not make an untrusted artifact safe. Only use official vendor
  HTTPS URLs, confirm the vendor's published checksum when available, and review
  every manifest change before signing it.
- The private Ed25519 key is generated and stored offline, outside this
  repository. Never commit it, embed it in the application, or add it to GitHub
  Actions or GitHub Secrets.
- The public key is not secret. It is compiled into production builds and is
  also configured as a GitHub Actions repository variable so the publish
  workflow can reject invalid signatures.

## One-Time Setup

Create the key pair on a trusted offline machine. Choose a stable key ID that is
also passed to the application build:

```sh
dart run tool/runtime_manifest_signer.dart generate-key \
  --key-id nishi-release-2026 \
  --private-key /secure/offline/nishi-release-2026.private.json \
  --public-key /secure/offline/nishi-release-2026.public.json
```

Back up the private key in an encrypted offline location with limited access.
Keep a written key rotation and revocation procedure. Copy only the public key
value into the repository configuration:

1. Create the Actions repository variables
   `RUNTIME_MANIFEST_PUBLIC_KEY_BASE64` and `RUNTIME_MANIFEST_KEY_ID` for
   manifest publication checks.
2. Supply the same public key and key ID to production application builds using
   `NISHI_MANIFEST_SIGNING_PUBLIC_KEY_BASE64` and
   `NISHI_MANIFEST_SIGNING_KEY_ID`.

GitHub Secrets are appropriate for unrelated platform release credentials such
as Apple signing certificates or Windows code-signing credentials. They must
not contain the runtime-manifest Ed25519 private key, because manifest signing
is deliberately an offline operation.

## Prepare and Sign a Manifest

Use official stable vendor URLs for each supported host and architecture. Record
the SHA-256 digest of the exact file served at each URL. Keep the manifest bytes
unchanged after signing; even whitespace changes invalidate the signature.

Sign the reviewed manifest on the offline signing machine:

```sh
dart run tool/runtime_manifest_signer.dart sign \
  --private-key /secure/offline/nishi-release-2026.private.json \
  --manifest release/runtime-manifest.json \
  --signature release/runtime-manifest.sig.json
```

Verify the two files before transferring them back to the release workstation:

```sh
dart run tool/runtime_manifest_signer.dart verify \
  --manifest release/runtime-manifest.json \
  --signature release/runtime-manifest.sig.json \
  --public-key-file /secure/offline/nishi-release-2026.public.json
```

The signature file is a JSON envelope containing `keyId` and a Base64 Ed25519
signature. Both `release/runtime-manifest.json` and
`release/runtime-manifest.sig.json` are release inputs and may be committed for
review; private key files and signing scratch directories must never be
committed.

## Publish to GitHub Releases

1. Review the manifest, official source URLs, SHA-256 values, and detached
   signature in a pull request.
2. Create and push the release tag that should own the assets.
3. Run the `Publish runtime manifest` workflow from GitHub Actions. Enter the
   existing tag and repository-relative paths to the manifest and signature.
4. The workflow verifies the detached signature with the configured public key
   and rejects a signature whose key ID differs from the application build. It
   then creates the release if needed and uploads exactly these asset names:
   `runtime-manifest.json` and `runtime-manifest.sig.json`.
5. Confirm the latest-release URLs return the expected files before distributing
   an application build.

The production defaults are:

```text
https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.json
https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.sig.json
```

## Production Build Configuration

Production builds must include the trusted public key and key ID. URLs have
official GitHub Release defaults but can be overridden for staging:

```sh
flutter build macos --release \
  --dart-define=NISHI_RUNTIME_MANIFEST_URL=https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.json \
  --dart-define=NISHI_RUNTIME_MANIFEST_SIGNATURE_URL=https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.sig.json \
  --dart-define=NISHI_MANIFEST_SIGNING_PUBLIC_KEY_BASE64=<public-key-base64> \
  --dart-define=NISHI_MANIFEST_SIGNING_KEY_ID=nishi-release-2026
```

Use the same four defines for Windows builds. A public key supplied through a
`dart-define` becomes part of the application binary; this is expected and does
not require a GitHub Secret. Never pass the private key through a `dart-define`.
