# modules/logging

Cluster log aggregation: **VictoriaLogs** (store + query) + **Vector**
(per-node collector) + a **Grafana** datasource. Replaces node-local kubelet
log rotation (≈50 MiB/container, lost on pod delete) with a time-retained,
searchable store.

```
every node:  /var/log/pods/*  →  Vector DaemonSet (kubernetes_logs)
                                       │  HTTP ingest :9428
                                       ▼
                             VictoriaLogs (1 pod, -retentionPeriod, Longhorn PV)
                                       ▲
                             Grafana (kube-prometheus-stack) ── LogsQL datasource
```

## Design

- **Namespace `monitoring`** — co-located with Grafana/Prometheus/Alertmanager
  so the Grafana datasource sidecar discovers the emitted ConfigMap
  (`grafana_datasource=1`) with no cross-namespace wiring.
- **Storage = Longhorn** by default — VictoriaLogs has no object-storage
  tiering, so the replicated PV is the durability story (survives node loss,
  pod reschedules anywhere). Set `storage_class = ""` for node-local
  `local-path` (faster, pinned, lost on node loss).
- **Retention is time-based** (`retention_period`, default `30d`) — the win
  over the kubelet's size cap: real history across the whole cluster,
  surviving pod deletes and rollouts.
- **Vector runs on every node** (`vector_tolerations` defaults to tolerate
  all) — log collection must cover the whole cluster, including tainted nodes.
- **Grafana plugin** — the datasource uses `victoriametrics-logs-datasource`
  (full LogsQL + Explore field/time UI). The plugin is installed via the
  addons module's `monitoring_grafana_extra_values.plugins`, wired at the root
  (gated on this service being enabled). Without the plugin, a Loki-compatible
  datasource type is the fallback (reduced query surface).

## Inputs / outputs

See `variables.tf` / `outputs.tf`. Toggle via `services.logging` in
`config/platform.yaml`.

## Not in this module

Alerting (vmalert evaluating LogsQL rules → Alertmanager → email) is a
separate, layered concern wired at the root once a notification channel is
chosen.
