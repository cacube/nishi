# Release and Runtime Manifest Signing

Nishi downloads runtime metadata from GitHub Releases. Runtime binaries remain
on vendor HTTPS endpoints or reviewed exact-byte China mirrors; GitHub Releases
contains only the signed manifest and its detached signature envelope.

## Current Production State

- The first production manifest exists at `release/runtime-manifest.json`. It
  pins the managed Flutter, JDK, Android SDK, Go, Node.js, and MySQL artifacts,
  including official HTTPS sources, reviewed mirror fallbacks where available,
  and SHA-256 digests.
- The production key ID is `nishi-release-2026-01`. Its public key is embedded
  in `RemoteManifestReleaseConfiguration`, so normal release builds do not need
  signing-key `dart-define` values. The defines remain available for staging or
  future key rotation.
- On the current signing workstation, the production private key is stored at
  `~/.config/nishi/signing/nishi-release-2026-01.private.json`, outside the
  repository, with mode `0600`. It must never be committed, uploaded to GitHub,
  included in a build, or shared with a clean-machine runner.
- The default URLs serve only an exact-byte-signed manifest and detached
  signature published as immutable release assets. Verify those URLs after each
  publication.
- The first production profile passed install-mode clean-machine verification
  on Windows 2025 and macOS 15. The evidence is recorded under
  [Clean-Machine Verification](#clean-machine-verification).

## Trust Model

- Ed25519 authenticates the exact bytes of `runtime-manifest.json`.
- Every vendor artifact in the manifest has an expected SHA-256 digest. The app
  verifies that digest after download and before installation.
- The official source is always attempted first. Network, HTTP, timeout, or
  integrity failure may advance to a signed mirror URL. Partial data is deleted
  before changing sources, and every source must match the same SHA-256.
- A signature does not make an untrusted artifact safe. Use official vendor
  HTTPS URLs and exact-byte mirrors operated by the vendor or a reviewed mirror
  provider. Fully download every mirror candidate, compare it with the canonical
  SHA-256, and review every manifest change before signing it.
- The private Ed25519 key is generated and stored in an access-restricted
  location outside this repository and outside CI. Never commit it, embed it in
  the application, or add it to GitHub Actions or GitHub Secrets. Keep an
  encrypted offline backup.
- The public key is not secret. It is compiled into production builds and is
  also configured as a GitHub Actions repository variable so the publish
  workflow can reject invalid signatures.

## Key Generation or Rotation

The current production key pair has already been generated. Only use this
procedure when creating a replacement key on a trusted signing machine. Choose
a stable key ID, and update the application's embedded public key before
publishing a manifest signed by the replacement key:

```sh
dart run tool/runtime_manifest_signer.dart generate-key \
  --key-id nishi-release-YYYY-NN \
  --private-key /secure/offline/nishi-release-YYYY-NN.private.json \
  --public-key /secure/offline/nishi-release-YYYY-NN.public.json
```

Back up the private key in an encrypted offline location with limited access.
Keep a written key rotation and revocation procedure. Copy only the public key
value into the repository configuration:

1. Create the Actions repository variables
   `RUNTIME_MANIFEST_PUBLIC_KEY_BASE64` and `RUNTIME_MANIFEST_KEY_ID` for
   manifest publication checks.
2. Embed the same public key and key ID in
   `RemoteManifestReleaseConfiguration`. The
   `NISHI_MANIFEST_SIGNING_PUBLIC_KEY_BASE64` and
   `NISHI_MANIFEST_SIGNING_KEY_ID` build defines are overrides for staging and
   controlled key-transition builds, not requirements for the current
   production build.

GitHub Secrets are appropriate for unrelated platform release credentials such
as Apple signing certificates or Windows code-signing credentials. They must
not contain the runtime-manifest Ed25519 private key, because manifest signing
is deliberately performed outside GitHub Actions.

## Prepare and Sign a Manifest

Use official stable vendor URLs for each supported host and architecture. A
`mirrorUrls` entry is optional and may be added only after a full HTTPS download
matches the official artifact SHA-256. Record the digest and verification
evidence. Keep the manifest bytes unchanged after signing; even whitespace
changes invalidate the signature.

Sign the reviewed manifest on the trusted signing workstation:

```sh
dart run tool/runtime_manifest_signer.dart sign \
  --private-key ~/.config/nishi/signing/nishi-release-2026-01.private.json \
  --manifest release/runtime-manifest.json \
  --signature release/runtime-manifest.sig.json
```

Verify the two files immediately after signing and before publication:

```sh
dart run tool/runtime_manifest_signer.dart verify \
  --manifest release/runtime-manifest.json \
  --signature release/runtime-manifest.sig.json \
  --public-key-file ~/.config/nishi/signing/nishi-release-2026-01.public.json
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

Production builds already include the trusted public key and key ID. The latest
GitHub Release URLs and embedded key are the no-argument defaults. Use all four
overrides together only for staging or a controlled key transition:

```sh
flutter build macos --release \
  --dart-define=NISHI_RUNTIME_MANIFEST_URL=https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.json \
  --dart-define=NISHI_RUNTIME_MANIFEST_SIGNATURE_URL=https://github.com/cacube/nishi/releases/latest/download/runtime-manifest.sig.json \
  --dart-define=NISHI_MANIFEST_SIGNING_PUBLIC_KEY_BASE64=<public-key-base64> \
  --dart-define=NISHI_MANIFEST_SIGNING_KEY_ID=nishi-release-2026-01
```

Use the same four defines for Windows builds. A public key supplied through a
`dart-define` becomes part of the application binary; this is expected and does
not require a GitHub Secret. Never pass the private key through a `dart-define`.

## Runtime Provider Limits

The signed manifest intentionally keeps Redis-compatible services external and
optional. Gin-Vue-Admin v3.0.0 defaults `use-redis` to `false`, so Redis does
not block readiness for the supported server profile.

- macOS Redis is external because Redis does not publish an official macOS
  binary that Nishi can pin and verify.
- Windows Memurai is external because the Developer MSI had no vendor-published
  SHA-256 and returned HTTP 403 during release verification. Nishi must not
  invent a checksum or silently mirror an unverified installer.

## Post-Install Process Restart

Nishi persists the managed toolchain variables for future user processes and
updates the active macOS launchd or Windows user environment. Already-running
applications keep the environment with which they started. Completely quit and
reopen Codex and every Terminal application after setup or an environment
update before using the installed tools.

## Clean-Machine Verification

The manual `Runtime clean-machine smoke` workflow supports Windows and macOS
and has `validate`, `download`, and `install` modes.

The first production profile completed these install-mode runs on 2026-07-20:

- [Flutter client toolchain run 29753324985](https://github.com/cacube/nishi/actions/runs/29753324985):
  Windows 2025 and macOS 15 installed the pinned JDK, Android SDK packages, and
  Flutter SDK; built Web and Android APK targets; built Windows desktop on
  Windows; and, after detecting Xcode, built macOS and an unsigned iOS
  simulator target on macOS.
- [Gin-Vue-Admin server toolchain run 29755257509](https://github.com/cacube/nishi/actions/runs/29755257509):
  both hosts installed and version-checked Go, Node.js/npm, and MySQL; initialized
  MySQL, enabled user-level autostart, and verified the MySQL 8.4.10 protocol
  handshake on port 3306.

Before declaring a future runtime profile verified:

1. Run install mode for `flutter,jdk,android-sdk` on both hosts with Android
   license acceptance explicitly enabled, then verify Flutter Android and web.
2. Verify Windows desktop on Windows. On macOS, enable and verify iOS/macOS only
   when Xcode is detected.
3. Run install mode for `go,node,mysql` on both hosts and verify the supported
   Gin-Vue-Admin server environment, including MySQL startup and connectivity.
4. Record the workflow URLs or run IDs in the release notes. Do not claim a host
   has passed when only validation or download mode completed.
