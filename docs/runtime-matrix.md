# Runtime Compatibility Matrix

The first lc runtime profile targets the official stable
`flipped-aurora/gin-vue-admin` v3.0.0 release (commit
`a890e99f7f98029cdef19ffcbb48d3f9cc5e6259`). The desktop application prepares
compatible development runtimes, and the separately compiled `lc init` CLI
downloads and verifies this exact source when creating a project.

| Component | Pinned version | Provisioning | Notes |
| --- | --- | --- | --- |
| Flutter | 3.44.6 stable | Managed | Android 36 and web; Windows target needs Visual Studio Build Tools; Xcode enables iOS/macOS. |
| JDK | Eclipse Temurin 17.0.19+10 | Managed | Android toolchain runtime. |
| Android SDK | Command-line Tools 22.0 / API 36 / Build Tools 36.0.0 | Managed | Minimum build profile; Android licenses require explicit acceptance. |
| Go | 1.26.5 | Managed | Gin-Vue-Admin declares Go 1.24.0 and toolchain 1.24.2; lc requires 1.24.2 or newer. |
| Node.js | 24.18.0 LTS | Managed | Satisfies Vite 8's `^20.19.0 || >=22.12.0` requirement. |
| MySQL | 8.4.10 LTS | Managed | Default Gin-Vue-Admin database; macOS vendor archives require macOS 15. |
| Redis | 8.8.0 | External/optional on macOS | Redis publishes source, containers, and package-manager instructions, but no official macOS binary. |
| Memurai | 4.2.3 Developer | External/optional on Windows | Vendor MSI has no published SHA-256 and returned HTTP 403 during release verification. |
| Git | 2.40+ | External | macOS distribution is supplied by Xcode CLT or a package manager. |

Redis is optional because Gin-Vue-Admin v3.0.0 defaults `use-redis` to `false`.
The managed Android profile installs the minimum packages required to build for
Android. Emulator images, AVD creation, NDK, and CMake are a separate optional
profile because they are large and require host virtualization checks.

Every managed artifact in `release/runtime-manifest.json` keeps the vendor's
official HTTPS endpoint first and has a pinned SHA-256 digest. Reviewed China
mirror URLs are optional fallbacks and must serve the exact same bytes. lc
discards partial data when changing sources and verifies the same SHA-256 before
installation. Components without a verified exact-byte mirror remain
official-only. The signed release manifest is the source of truth for updates.

Android command-line tools follow that artifact rule. The later API,
build-tools, and platform-tools installation is delegated to the pinned Google
`sdkmanager`: it tries Google's international repository first and then the
Google China repository from the signed manifest. Those dynamic repository
packages use the checksums supplied by Google's repository metadata and are not
claimed as separate lc SHA-256-pinned artifacts.
