# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module: `prometheus-smartctl-exporter` DaemonSet (exporter
  v0.15.0, digest-pinned) with a ServiceMonitor that labels series with
  the node name, and an optional "Disk health" Grafana dashboard: per-drive
  wear, estimated days left at the recent write rate, bytes written, spare,
  media errors, temperature, plus disk write rate, write latency and the
  top writing namespaces per node.
