# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module: `prometheus-smartctl-exporter` DaemonSet (exporter
  v0.15.0, digest-pinned) with a ServiceMonitor that labels series with
  the node name, and an optional "Disk health" Grafana dashboard. The
  dashboard lists every physical drive the exporter sees (SSD, NVMe and
  HDD — anchored on `smartctl_device`, not on wear, so spinning disks are
  not dropped): SMART overall status, wear, estimated days left at the
  recent write rate, bytes written, spare, media errors, reallocated and
  pending sectors, temperature and power-on days, plus disk write rate,
  write latency and the top writing namespaces per node.
