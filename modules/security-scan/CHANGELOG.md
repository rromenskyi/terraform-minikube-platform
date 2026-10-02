# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- CRD manifests are `apply_only`: disabling the module or dropping a CRD no
  longer deletes it (and every object of that kind cluster-wide).

### Changed
- **BREAKING: snapshot pipeline removed.** The weekly CronJob that wrote
  `inventory/cve-report.md`, pushed a branch, opened a PR and emailed a
  summary is gone, with its scripts, RBAC, Vault PAT sync and the unused
  trivy cache PV/PVC. It swallowed collection errors (a failed run looked
  like a clean report), mis-deduplicated images and could lose PRs and
  mail for good. Findings now go through Prometheus: new inputs
  `alerts_enabled`, `alert_severities`, `alert_labels` emit a
  PrometheusRule (`ImageVulnerabilities`, `SecurityScanNoData`).
  Migration: drop `cache_node_hostname`, `host_volume_path`,
  `trivy_cache_size`, `snapshot_schedule`, `github_repo`, `branch_prefix`,
  `email_*`, `smtp_server` from the call; route the alerts via
  Alertmanager; revoke the snapshot PAT.
- Operator no longer gets cluster-wide Secret access
  (`accessGlobalSecretsAndServiceAccount=false`); config-audit and SBOM
  reports are off; scans are capped at `scan_jobs_concurrent_limit`
  (default 2) with `scan_job_timeout` / `scan_job_resources` /
  `operator_resources` inputs; `ignore_unfixed` defaults to true; the
  `mail` namespace and `extra_target_namespaces` are scanned.
- Scans run in ClientServer mode against the chart's built-in trivy server
  (`builtin_trivy_server`, default true, DB on a PVC): Standalone scans of
  multi-container workloads failed on the shared cache lock.

### Changed
- **BREAKING (inputs): Telegram notification replaced by email.**
  `telegram_notify_enabled` / `telegram_vault_path` and the Telegram
  VaultStaticSecret are gone; set `email_to`, `email_from`, `email_helo`
  (and optionally `smtp_server`) to get the new/resolved findings and the
  PR link by email through the in-cluster mail server.
- CronJob pods use `restartPolicy: Never`, so a failed run keeps its pod
  and logs instead of the Job controller deleting them.

### Fixed
- Every run failed after pushing: the PR call used `-w '%%{http_code}'`,
  a templatefile escape in a script loaded with `file()`, so curl printed
  the literal format, no status matched and the script exited 1, before
  any notification.
- Unchanged findings no longer produce a weekly commit: the change check
  now ignores only the `Generated:` line instead of also requiring a
  byte-identical file.

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
