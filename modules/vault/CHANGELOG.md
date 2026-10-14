# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- `snapshot_backup`: kubernetes-auth role `backup-snapshot` with read on
  `sys/storage/raft/snapshot` only, for the backup Job.

### Added
- `vso_tenants`: per-tenant VSO policy (`tenants/<slug>/*`) and kubernetes-auth
  role `vso-tenant-<slug>` bound to the tenant's namespaces.
  `vso_shared_namespaces` limits the shared `vso` role (all tenants +
  platform) to the platform namespaces that need it. VSO caches Vault
  tokens (TTL 24h): restart it after narrowing so stale tokens go.

### Changed
- CRD manifests are `apply_only`: disabling the module or dropping a CRD no
  longer deletes it (and every object of that kind cluster-wide).

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
