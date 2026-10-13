# cnpg Changelog

All notable changes to this module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial module: CloudNativePG operator (chart 0.29.1, operator 1.30.1) and
  Barman Cloud plugin (chart 0.8.1), a Postgres 18 cluster with required
  anti-affinity, optional node list, synchronous replication with
  `dataDurability: preferred`, data checksums and an enabled `postgres`
  superuser; WAL archiving and scheduled base backups to S3-compatible
  storage; PodMonitor and PrometheusRule (missing instances, replication
  lag, WAL archiving failures).
