# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `service_name` (default `postgres`) and `superuser_password` (default null =
  generated): the Service name and the superuser password can come from the
  caller, so another engine can take over the same name and credentials.

### Fixed
- Superuser password is re-asserted after start over the local socket
  (`postStart`, never fails the container); the image sets it only on an
  empty data dir.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
