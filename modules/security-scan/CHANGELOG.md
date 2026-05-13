# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial release. Two-layer setup: upstream `trivy-operator` Helm chart
  scans Pods cluster-wide and emits VulnerabilityReport CRDs; a weekly
  snapshot CronJob collects HIGH + CRITICAL findings, formats them into
  `inventory/cve-report.md`, and opens a PR against the platform repo if
  the report changed since last run.
- HostPath PV pinned to a stateful tier node persists trivy's ~700 MB
  vulnerability DB across operator pod restarts.
- Vault-mode GitHub PAT consumption via VSO — operator places a classic
  PAT (scope `repo`) at `secret/data/platform/github-deploy-tokens/security-scan`,
  engine emits the matching `VaultStaticSecret` + consuming-namespace SA.
- Snapshot scope is the platform-system namespaces only (allowlist
  hardcoded in `local.target_namespaces`); tenant project namespaces
  are out of v0 scope.
- Optional Telegram DM notification on snapshot changes. When
  `var.telegram_notify_enabled = true`, engine emits a second
  VaultStaticSecret pointing at `var.telegram_vault_path`
  (default `platform/telegram-bots/operator` with keys `bot_token` +
  numeric `chat_id`). The commit-pr CronJob step POSTs to Telegram
  Bot API after a successful PR open/refresh, with a one-line
  link to the PR. Optional `secretKeyRef` so leaving the toggle
  off (default) doesn't break container start.
