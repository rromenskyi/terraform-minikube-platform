# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Roundcube 1.7.5 (was 1.6.20). The first start migrates the SQLite schema (`session.changed` becomes `expires_at`, new `uploads` table), so going back to 1.6 needs the pre-upgrade `sqlite.db` from backup. Logout now also ends the Zitadel session (`oauth_logout_uri` was ignored by 1.6). `oauth_auth_type` is pinned to XOAUTH2, the mechanism 1.6 used.

### Added
- `volume_preferred_node_selectors`: with the data on `storage_class`, a soft preference for the nodes holding the volume's copies.

### Added
- `storage_class` / `storage_seed_node`: SQLite volume on a StorageClass (PVC
  `data-roundcube`), with a one-time copy of the old hostPath directory on
  the first start (modules/volume-seed).

### Changed
- Roundcube 1.6.20-apache digest of 2026-10-31 (rebuilt base).
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
