# ADR 0001: Online Bootstrap Installer

Status: Accepted

The Environment Manager will ship as a small Windows or macOS installer and
download pinned, platform-specific runtime packages during setup. A full
offline bundle would multiply a very large Flutter and Android toolchain across
Windows, macOS Intel, and macOS Apple Silicon releases. Downloaded artifacts
must be checksum-verified and retained in a local cache so setup is
reproducible and repair does not normally require another download.
