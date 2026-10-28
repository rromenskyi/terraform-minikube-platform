# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `pv_paths` entries for volumes on a StorageClass: `pvc` + `namespace` +
  `pod_selector` (+ `sub_path`, default `data`). Each gets its own CronJob in
  that namespace, on the node of the pod using the volume, with a copy of the
  credentials Secret there; Pod Security `baseline` compatible.

### Fixed
- `backup-verify` honours the snapshot's UTC offset: snapshots pushed from a
  host in another zone (e.g. `operator-config`, `-06:00`) were aged by the
  offset.

### Added
- `backup-verify` CronJob: snapshot freshness per tag; built-in limits for
  the enabled targets, `freshness_max_age_hours` to override or add.
  `schedule_verify` controls when it runs.
- `BackupJobFailing` PrometheusRule (`prometheus_rule_labels`,
  `alert_labels`): the latest scheduled run of a CronJob in the namespace
  has not succeeded within 2 h.
- The module now requires the `gavinbunney/kubectl` provider.

### Security
- `vault_auth_role`: the Vault snapshot Job logs in with ServiceAccount
  `backup-vault` (kubernetes auth) instead of a root-token Secret.

### Fixed
- `pv_paths[].node`: one PV backup CronJob per node (`backup-pv-<node>`,
  restic host `platform-pv-<node>`), since hostPath data exists only on its
  node; `restore-pv.sh` defaults to the newest snapshot holding the archive.
- PV backups capture SQLite databases listed under the entry's `sqlite:`
  with `VACUUM INTO` (+ `PRAGMA quick_check`) instead of tarring the live
  db/-wal/-shm, which could restore corrupt. The README no longer claims
  live tars of WAL stores recover cleanly.
- Restore scripts rewritten after a restore drill: Postgres/MySQL restore
  one database from the combined `all.sql.gz` (they only looked for
  `<db>.sql.gz`), Postgres gains `--all`; `restore-pv.sh` validates the
  target and archive and keeps the old content instead of `rm -rf`;
  `restore-redis.sh` works with Sentinel (temporary server + MIGRATE).
  Destructive modes require `CONFIRM=yes`.
- The init Job's name carries a hash of the restore scripts, so editing
  them re-uploads the copy under tag `scripts`; it runs on the restic image
  (`image_restic`) instead of installing restic at start.
- Postgres dump runs with `pipefail`: a failing `pg_dump` piped into gzip
  used to upload an empty archive and report success.

### Changed
- Vault backup image hashicorp/vault:2.1.2.
- `image_alpine` default `alpine:3.22` -> `alpine:3.24`; the Postgres dump
  installs `postgresql18-client` (a 16 client cannot dump an 18 server).
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
