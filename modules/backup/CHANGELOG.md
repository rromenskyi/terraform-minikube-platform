# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
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
- `image_alpine` default `alpine:3.22` -> `alpine:3.24`; the Postgres dump
  installs `postgresql18-client` (a 16 client cannot dump an 18 server).
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
