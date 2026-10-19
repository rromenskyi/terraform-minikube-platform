# cnpg Changelog

All notable changes to this module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `managed_roles`: declarative roles on the primary (CNPG
  `spec.managed.roles`), each with its password in a module-written Secret
  (`<name>-role-<role>`). For a provisioner role (`createdb`/`createrole`,
  no superuser) an application can create its own databases without a
  superuser. CNPG reconciles only the listed roles; roles those create at
  runtime are left alone.
- `replica_cluster` / `primary_cluster`: a second Cluster in the same
  namespace (e.g. on another site's nodes, with `nodes` and `tolerations`)
  that follows the main one as a CloudNativePG distributed topology. It is
  bootstrapped with `pg_basebackup`, streams over TLS with the main
  cluster's WAL archive as fallback, and archives and backs up under its own
  name. `primary_cluster` names the cluster that takes writes; the
  `service_name` Service, `host` and `ro_host` follow it. Changing it is a
  failover; the README has the runbook. Per-cluster alerts, plus
  `CNPGReplicaClusterNotStreaming`. Outputs `replica_cluster_name` and
  `primary_cluster`.

### Changed
- The cluster's alerts carry `namespace` and `cnpg_cluster` labels, so two
  clusters' alerts stay distinct in Alertmanager.
- `service_name`: an extra Service under a caller-chosen name that selects
  the current primary; `host` points at it when set.
- `superuser_secret_name` (default `<name>-superuser`); `namespace` output.

### Changed
- The superuser Secret is `Opaque` (the operator reads only the
  `username` / `password` keys), so a former server's Secret can be taken
  over in place.

### Added
- `sync`: a Job that copies every database and role from another Postgres
  server (`pg_dumpall --roles-only` + `pg_dump --create --clean` per database)
  and verifies role lists and per-table row counts. Modes: `rehearsal`
  (source keeps running), `cutover` (source frozen first with
  `CONNECTION LIMIT 0`, any difference fails), `thaw` (lifts the freeze).

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
