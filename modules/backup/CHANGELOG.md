# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Postgres dump runs with `pipefail`: a failing `pg_dump` piped into gzip
  used to upload an empty archive and report success.

### Changed
- `image_alpine` default `alpine:3.22` -> `alpine:3.24`; the Postgres dump
  installs `postgresql18-client` (a 16 client cannot dump an 18 server).
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
