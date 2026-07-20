# Runtime Compatibility Matrix

The first Nishi runtime profile targets the official stable
`flipped-aurora/gin-vue-admin` v3.0.0 release (commit
`a890e99f7f98029cdef19ffcbb48d3f9cc5e6259`). It does not download or create a
Gin-Vue-Admin project; it only prepares compatible development runtimes.

| Component | Pinned version | Provisioning | Notes |
| --- | --- | --- | --- |
| Flutter | 3.44.6 stable | Managed | Android 36 and web; Windows target needs Visual Studio Build Tools; Xcode enables iOS/macOS. |
| JDK | Eclipse Temurin 17.0.19+10 | Managed | Android toolchain runtime. |
| Android SDK | Command-line Tools 22.0 / API 36 / Build Tools 36.0.0 | Managed | Minimum build profile; Android licenses require explicit acceptance. |
| Go | 1.26.5 | Managed | Gin-Vue-Admin requires Go 1.24.0/toolchain 1.24.2 or newer. |
| Node.js | 24.18.0 LTS | Managed | Satisfies Vite 8's Node requirement. |
| MySQL | 8.4.10 LTS | Managed | Default Gin-Vue-Admin database; macOS vendor archives require macOS 15. |
| Redis | 8.8.0 | External/optional on macOS | Redis publishes source, containers, and package-manager instructions, but no official macOS binary. |
| Memurai | 4.2.3 Developer | External/optional on Windows | Vendor MSI has no published SHA-256 and returned HTTP 403 during release verification. |
| Git | 2.40+ | External | macOS distribution is supplied by Xcode CLT or a package manager. |

Redis is optional because Gin-Vue-Admin v3.0.0 defaults `use-redis` to `false`.
The managed Android profile installs the minimum packages required to build for
Android. Emulator images, AVD creation, NDK, and CMake are a separate optional
profile because they are large and require host virtualization checks.

Every managed artifact URL in `release/runtime-manifest.json` uses the vendor's
official HTTPS endpoint and has a pinned SHA-256 digest. The signed release
manifest is the source of truth for updates.
