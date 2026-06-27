# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`vmalert_external_url` + a vmalert `Service`.** vmalert had no Service, so
  the `Source`/generator links it stamps on alerts fell back to the raw pod
  address (`vmalert-<hash>:8880`) — unreachable from a browser, the dead
  "Source" button on alert emails. Now the module always emits
  `kubernetes_service_v1.vmalert` (ClusterIP, port 8880) so a consumer can
  route a hostname to the UI, and `vmalert_external_url` (default `""` = no-op)
  sets vmalert's `-external.url` so the generated links use that host.
- **Alerting — vmalert (LogsQL rules) → existing Alertmanager → email.** When
  `alert_email` is set, deploys a vmalert Deployment that evaluates a
  `type: vlogs` rule group (from `alert_rules`, two starter templates:
  critical-pattern + error-burst) against VictoriaLogs and fires to the
  kube-prometheus-stack Alertmanager. An `AlertmanagerConfig` adds an email
  receiver routed to the operator's mailbox through the in-cluster Stalwart
  SMTP listener (local delivery — no relay-trust change or credentials).
  `alert_rules` is caller-supplied (default empty); the root wires a generic
  baseline (panic/fatal/OOM) merged with the operator's app-specific rules, so
  operator config lists only additions. Each rule's LogsQL ends in
  `stats count() as <name> | filter <name>:>N` (window in `_time:`, threshold
  in `filter`).
  Notes: alerts carry an `alert_source=log` label and the route matches it, so
  the receiver gets ONLY log alerts (not the built-in metric alerts that also
  carry `namespace=monitoring`); the email `hello` (EHLO) is a real FQDN
  (`alertmanager.ipsupport.us`) because Stalwart rejects the pod hostname with
  `550 Invalid EHLO domain`; `requireTLS=false` for the in-cluster hop. Empty
  `alert_email` deploys none of this (store + collector only). Verified e2e: a
  panic log line → vmalert fires → email delivered to the mailbox.
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
