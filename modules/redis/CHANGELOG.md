# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Disable AOF/RDB persistence on the Sentinel cache** via `commonConfiguration`
  (`appendonly no`, `save ""`). The data volume is an emptyDir (no PVC), so the
  cache never survives a restart anyway, but the chart-default `appendonly yes`
  fsynced to the node's local disk every second — under host disk contention
  that fsync stalled ("Asynchronous AOF fsync is taking too long — disk is
  busy?"), briefly wedging the server and dropping in-flight client connections
  (WordPress object-cache logged `Error while reading line from the server` and
  fell back to slow uncached page loads → occasional origin timeouts). Removing
  the fsync removes the stalls. Only overrides the chart's default
  `commonConfiguration`; the default `disableCommands: [FLUSHDB, FLUSHALL]`
  (separate field) is untouched.

### Added
- **`redis-acl-keeper` — per-tenant ACL users that survive Valkey restarts.**
  The Sentinel chart is effectively ephemeral (no `aclfile`, no PVC), so ACL
  users created at runtime vanished on every Valkey pod restart / node reboot,
  `WRONGPASS`-ing every tenant until manual re-application. The keeper is a
  tiny Deployment (+ namespace-scoped `get,list secrets` Role) that lists the
  `redis-acl-<ns>` Secrets each consuming project now writes (one
  `ACL SETUSER` line, password as a SHA-256 hash — no plaintext) and re-applies
  every line to **each** Valkey node directly on a 10s loop. Direct-to-node
  (not via the Service) because Valkey does not replicate ACL changes — every
  node is primed so a Sentinel failover never re-breaks auth. Replaces the
  per-tenant one-shot `redis-setup` Jobs (removed from `modules/project`).

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
