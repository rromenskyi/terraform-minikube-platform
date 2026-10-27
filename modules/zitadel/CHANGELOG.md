# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- Zitadel and the login UI default to v4.19.5 (Next.js 16.3.6 in the login image), fixing several unauthenticated remote code execution bugs in Next.js 16.2.
- The login route refuses `/ui/v2/login/_next/image` (403). The login UI does not use Next.js's image optimizer, which had unauthenticated RCE bugs still open in Next.js 16.3 (GHSA-2464-fhr4-w9xw).

### Added
- `preferred_node_affinity` (label => values): soft node preference (`preferredDuringScheduling`, weight 100).

### Security
- Postgres setup Job reads the password from a Secret instead of the command.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
