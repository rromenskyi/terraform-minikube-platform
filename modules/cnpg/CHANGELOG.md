# cnpg Changelog

All notable changes to this module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `sync`: a Job that copies every database and role from another Postgres
  server (`pg_dumpall --roles-only` + `pg_dump --create --clean` per database)
  and verifies role lists and per-table row counts. Modes: `rehearsal`
  (source keeps running), `cutover` (source frozen first with
  `CONNECTION LIMIT 0`, any difference fails), `thaw` (lifts the freeze).
- `primary_selector` output: the pod labels of the current primary.

### Fixed
- CPU limit on the Postgres containers (default `1`) and requests/limits on
  the Barman Cloud sidecar (`backup_sidecar_resources`): a namespace
  ResourceQuota that requires limits rejected the instance pods.

### Added
- Initial module: CloudNativePG operator (chart 0.29.1, operator 1.30.1) and
  Barman Cloud plugin (chart 0.8.1), a Postgres 18 cluster with required
  anti-affinity, optional node list, synchronous replication with
  `dataDurability: preferred`, data checksums and an enabled `postgres`
  superuser; WAL archiving and scheduled base backups to S3-compatible
  storage; PodMonitor and PrometheusRule (missing instances, replication
  lag, WAL archiving failures).
