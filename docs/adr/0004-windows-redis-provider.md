# ADR 0004: Windows Redis Provider

Status: Accepted for development builds

Windows uses Memurai Developer Edition as the Redis-compatible local
development service. Redis documents Memurai as its official partner for native
Windows compatibility, while the alternative WSL2 path adds virtualization,
elevation, and possible reboot requirements that conflict with zero-knowledge
setup. Memurai Developer Edition is restricted to development and testing and
requires a restart after ten days, so the installer must present its license
for explicit acceptance, register the service with recovery enabled, and label
it as a development-only component. This decision must be reviewed if Memurai
changes its license or distribution terms.
