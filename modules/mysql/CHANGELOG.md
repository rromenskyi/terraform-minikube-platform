# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `preferred_node_affinity` (label => values): soft node preference (`preferredDuringScheduling`, weight 100).

### Added
- `storage_class` / `storage_seed_node`: datadir on a StorageClass (PVC
  `data-mysql`, datadir = its `data/`), with a one-time copy of the old
  hostPath datadir on the first start (modules/volume-seed).

### Fixed
- Root password is re-asserted on every start (`--init-file` from the
  `mysql-root-init` Secret); the image sets it only on an empty data dir.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
