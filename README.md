# lc

A Flutter desktop application that prepares and maintains a zero-knowledge development environment for Flutter and the official stable Gin-Vue-Admin stack.

## Product Boundary

The application installs, detects, configures, updates, and repairs development runtimes on Windows and macOS. Its companion `lc` CLI creates a matching Flutter and Gin-Vue-Admin workspace. It does not edit source code or embed Codex; after setup and project creation, users work in the separate Codex application.

## Current Milestone

- Windows and macOS Flutter desktop shells.
- Real host checks for Flutter, JDK, Android SDK, browser, Go, Node.js/npm, MySQL, Redis, Git, Codex, Xcode, and Windows C++ build tools.
- MySQL and Redis port health checks.
- Required versus optional readiness rules.
- Strict runtime manifest parsing and validation for platform artifacts,
  dependencies, services, HTTPS sources, and SHA-256 digests.
- Resumable downloads with verified cache reuse, cancellation, timeouts,
  progress reporting, integrity checks, signed-manifest-constrained official
  and exact-byte China mirror policies, and safe target activation.
- Version compatibility checks plus protocol-level MySQL and Redis probes.
- User-scoped cache, runtime, data, and log directory layout.
- Dependency-aware setup orchestration with isolated failures and focused retry.
- Ed25519 verification of detached remote manifest signatures before JSON parsing.
- A production runtime manifest with pinned Flutter, JDK, Android SDK, Go,
  Node.js, and MySQL artifacts, official HTTPS endpoints, reviewed exact-byte
  China mirrors where available, and verified SHA-256 digests.
- Host platform and architecture artifact selection with dependency ordering.
- ZIP/TAR.GZ/RAW staging, traversal checks, executable verification, and atomic activation.
- Explicit user-confirmation/elevation plans for DMG/PKG/MSI/EXE installers.
- A one-click setup UI with download/install progress, cancellation, retry,
  Android license acceptance, and system-installer confirmation.
- A signed-manifest update center with current-to-target version comparison,
  per-component or all-component updates, safe no-downgrade behavior, and
  optional verified package pre-download without automatic installation.
- Persistent settings for startup checks, installed-component pre-download,
  automatic/official-only/China-mirror-first source selection, cache and old
  runtime cleanup, environment repair, directory access, and diagnostics.
- A shared runtime-operation lock that prevents installation, pre-download,
  cache cleanup, old-version cleanup, and environment repair from racing.
- Managed user-environment persistence plus reversible macOS LaunchAgent and
  Windows scheduled-task plans, including MySQL initialization and autostart.
- macOS release build with the process access required for tool discovery.
- Joint Windows and macOS installers that install the desktop application and
  standalone `lc` CLI together and add the CLI to the current user's `PATH`.
- Transactional `lc init <project-name>` generation with safe names, pinned
  Gin-Vue-Admin source verification, source fallback, and failure rollback.

The first production manifest exists at
[`release/runtime-manifest.json`](release/runtime-manifest.json), and the
trusted production Ed25519 public key is embedded in the application. The
private key is stored outside this repository and must never be committed. The
default remote URLs serve only a detached-signature-verified copy published as
GitHub Release assets. Clean Windows 2025 and macOS 15 runners have completed
the managed Flutter/Android/Web/desktop and Gin-Vue-Admin server installation
smokes. The recorded workflow runs and the required release procedure are in
[docs/releasing.md](docs/releasing.md).

lc application updates currently open the project's GitHub Releases page;
the application does not replace its own desktop bundle in place. Automatic
component downloads only populate the verified cache for already installed
components. Installation remains an explicit user action.

Redis is optional for the targeted Gin-Vue-Admin v3.0.0 release because its
default configuration sets `use-redis` to `false`. lc does not currently
install Redis on macOS because Redis does not publish an official macOS binary.
Memurai remains external on Windows because the vendor MSI had no published
SHA-256 and returned HTTP 403 during release verification.

After one-click setup changes the user environment, completely quit and reopen
Codex and any Terminal application before starting development. Processes that
were already running cannot inherit the updated `PATH`, `JAVA_HOME`, Android,
Flutter, Go, Node.js, or MySQL variables.

## Install lc

The packaged installer installs the desktop application and CLI in one action:

- Windows GUI: `%LOCALAPPDATA%\Programs\lc`; CLI:
  `%LOCALAPPDATA%\DevEnvironmentManager\bin\lc.exe`.
- macOS GUI: `~/Applications/lc.app`; CLI:
  `~/Library/Application Support/DevEnvironmentManager/bin/lc`.

Close and reopen Terminal and Codex after installation. Current packages are
intentionally unsigned for private use, so Windows SmartScreen or macOS
Gatekeeper may require explicit confirmation.

## Create a Project

After the desktop application reports the environment as ready, open a new
terminal in the parent directory and run:

```sh
lc init my_project
```

The command publishes the project directory only after every step succeeds:

```text
my_project/
├── client/                 Flutter application
├── admin/
│   ├── server/             Gin-Vue-Admin Go server
│   └── web/                Gin-Vue-Admin Vue admin
└── lc-project.json         Secret-free project metadata
```

The server uses `admin/server/config.lc.local.yaml`, which is ignored by the
upstream repository. From `admin/server`, start it with
`go run . -c config.lc.local.yaml`, then complete the official browser database
initialization. From `admin/web`, use `npm run serve`. Gin-Vue-Admin v3.0.0 is
BSL 1.1 software; preserve its license and notices and obtain any license
required for use outside its permitted scope.

## Verify

```sh
flutter analyze
flutter test
flutter run -d macos
dart run bin/lc.dart --help
scripts/build_macos_installer.sh
```
