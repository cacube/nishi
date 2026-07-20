# Development Environment Manager

A Flutter desktop application that prepares and maintains a zero-knowledge development environment for Flutter and the official stable Gin-Vue-Admin stack.

## Product Boundary

The application installs, detects, configures, updates, and repairs development runtimes on Windows and macOS. It does not create projects, edit source code, or embed Codex. After setup, users work in the separate Codex application.

## Current Milestone

- Windows and macOS Flutter desktop shells.
- Real host checks for Flutter, JDK, Android SDK, browser, Go, Node.js/npm, MySQL, Redis, Git, Codex, Xcode, and Windows C++ build tools.
- MySQL and Redis port health checks.
- Required versus optional readiness rules.
- Strict runtime manifest parsing and validation for platform artifacts,
  dependencies, services, HTTPS sources, and SHA-256 digests.
- Resumable downloads with verified cache reuse, cancellation, timeouts,
  progress reporting, integrity checks, and safe target activation.
- Version compatibility checks plus protocol-level MySQL and Redis probes.
- User-scoped cache, runtime, data, and log directory layout.
- Dependency-aware setup orchestration with isolated failures and focused retry.
- Ed25519 verification of detached remote manifest signatures before JSON parsing.
- A production runtime manifest with pinned Flutter, JDK, Android SDK, Go,
  Node.js, and MySQL artifacts from official HTTPS endpoints and verified
  SHA-256 digests.
- Host platform and architecture artifact selection with dependency ordering.
- ZIP/TAR.GZ/RAW staging, traversal checks, executable verification, and atomic activation.
- Explicit user-confirmation/elevation plans for DMG/PKG/MSI/EXE installers.
- A one-click setup UI with download/install progress, cancellation, retry,
  Android license acceptance, and system-installer confirmation.
- Managed user-environment persistence plus reversible macOS LaunchAgent and
  Windows scheduled-task plans, including MySQL initialization and autostart.
- macOS release build with the process access required for tool discovery.

The first production manifest exists at
[`release/runtime-manifest.json`](release/runtime-manifest.json), and the
trusted production Ed25519 public key is embedded in the application. The
private key is stored outside this repository and must never be committed. The
default remote URLs serve only a detached-signature-verified copy published as
GitHub Release assets. Clean Windows 2025 and macOS 15 runners have completed
the managed Flutter/Android/Web/desktop and Gin-Vue-Admin server installation
smokes. The recorded workflow runs and the required release procedure are in
[docs/releasing.md](docs/releasing.md).

Redis is optional for the targeted Gin-Vue-Admin v3.0.0 release because its
default configuration sets `use-redis` to `false`. Nishi does not currently
install Redis on macOS because Redis does not publish an official macOS binary.
Memurai remains external on Windows because the vendor MSI had no published
SHA-256 and returned HTTP 403 during release verification.

After one-click setup changes the user environment, completely quit and reopen
Codex and any Terminal application before starting development. Processes that
were already running cannot inherit the updated `PATH`, `JAVA_HOME`, Android,
Flutter, Go, Node.js, or MySQL variables.

## Verify

```sh
flutter analyze
flutter test
flutter run -d macos
```
