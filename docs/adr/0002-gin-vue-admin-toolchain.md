# ADR 0002: Gin-Vue-Admin Toolchain

Status: Accepted

The managed server-side development stack targets the official stable
Gin-Vue-Admin project instead of XYGo Admin. The environment therefore
provisions compatible Go and Node.js/npm runtimes plus its database and cache
services, and does not provision the GoFrame CLI. MySQL is the default database
family because it is Gin-Vue-Admin's documented default; Redis support is
installed for projects that enable it. Exact runtime versions remain pinned in
the downloadable package manifest so they can be upgraded independently of the
desktop application.
