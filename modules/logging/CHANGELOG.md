# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module: cluster log aggregation with **VictoriaLogs** (single-binary
  store + LogsQL query API on :9428, data on a Longhorn PV, time-based
  `-retentionPeriod`) and a **Vector** DaemonSet collector (tails every node's
  `/var/log/pods` via the `kubernetes_logs` source, ships to VictoriaLogs over
  the Elasticsearch-compatible ingest endpoint). Registers a **Grafana
  datasource** via the kube-prometheus-stack datasource sidecar (ConfigMap
  labelled `grafana_datasource=1`) using the native VictoriaLogs plugin for
  full LogsQL + the Explore UI. Vector tolerates all taints (collects from
  every node); VictoriaLogs runs as a single hardened non-root pod. Alerting
  (vmalert + Alertmanager receiver) is layered separately. CHANGELOG / README /
  variables / outputs per AGENT.md module conventions.
