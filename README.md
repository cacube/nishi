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
- Host platform and architecture artifact selection with dependency ordering.
- ZIP/TAR.GZ/RAW staging, traversal checks, executable verification, and atomic activation.
- Explicit user-confirmation/elevation plans for DMG/PKG/MSI/EXE installers.
- Managed environment documents plus reversible macOS LaunchAgent and Windows
  scheduled-task/service plans for MySQL and Redis-compatible services.
- macOS release build with the process access required for tool discovery.

The production signing key and first hosted runtime manifest, installation UI
wiring, and clean-machine Windows/macOS end-to-end verification are not
implemented yet. See [docs/releasing.md](docs/releasing.md) for the offline
Ed25519 signing and GitHub Release publication process.

## Verify

```sh
flutter analyze
flutter test
flutter run -d macos
```
