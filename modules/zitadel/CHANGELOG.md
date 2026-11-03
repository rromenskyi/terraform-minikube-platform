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

### Fixed
- Login UI probes use `/ui/v2/login/ready` (startup, readiness) and `/ui/v2/login/healthy` (liveness), as the upstream chart does. Probing the login page made Zitadel log `unable to set instance ... Instance.NotFound` for the pod IP several times per probe.

### Changed
- Zitadel and its login UI v4.20.0; `bitnami/kubectl` digest of 2026-10-31 (kubectl 1.37.2). v4.20 is built with Go 1.26.10: outbound TLS (SMTP, IdPs, webhooks) rejects chains through the compromised eMudhra intermediate CAs, so endpoints behind them need new certificates; URLs with invalid colons in the host are rejected; post-quantum hybrid key exchange is on by default (`GODEBUG=urlstrictcolons=0` / `tlssecpmlkem=0` restore the old behavior). Users in the middle of a device authorization must re-enter the code.
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
