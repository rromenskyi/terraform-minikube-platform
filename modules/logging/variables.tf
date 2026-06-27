variable "context" {
  description = "Serialized null-label context from the platform root (`module.platform_label.context`). Chains this module's labels off the platform-wide tag set."
  type        = any
  default     = null
}

variable "enabled" {
  description = "Master toggle. When false every resource collapses to zero via the `instances` toset, so disabling the service after the fact tears the whole stack (VictoriaLogs + Vector + datasource) down cleanly."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace for VictoriaLogs + Vector. Defaults to `monitoring` so the stack sits next to Grafana/Prometheus/Alertmanager and the Grafana datasource sidecar (which watches this namespace) picks up the emitted datasource ConfigMap with no cross-namespace plumbing."
  type        = string
  default     = "monitoring"
}

variable "victorialogs_image" {
  description = "VictoriaLogs container image. Single static binary; HTTP ingest + query API on :9428, data on a local path."
  type        = string
  default     = "victoriametrics/victoria-logs:v1.51.0"
}

variable "vector_image" {
  description = "Vector collector image (the DaemonSet agent that tails every node's container logs and ships them to VictoriaLogs)."
  type        = string
  default     = "timberio/vector:0.43.1-distroless-static"
}

variable "retention_period" {
  description = "VictoriaLogs `-retentionPeriod`. TIME-based retention (unlike the kubelet's 50 MiB/container size cap) — logs older than this are dropped regardless of volume. Accepts VictoriaMetrics duration form (`30d`, `90d`, `1y`)."
  type        = string
  default     = "30d"
}

variable "storage_class" {
  description = "StorageClass for the VictoriaLogs data PVC. Default `longhorn` (replicated network block storage) so the log store survives a node loss and the pod reschedules anywhere — VictoriaLogs has no S3/object-storage tiering, so the PV is the durability story. Set to `\"\"` for the node-local `local-path` default (faster, but pinned to one node + lost on node loss)."
  type        = string
  default     = "longhorn"
}

variable "storage_size" {
  description = "VictoriaLogs data PVC size. VictoriaLogs compresses ~10x, so a small cluster's 30d of logs fits comfortably in tens of GiB; size for peak-volume headroom."
  type        = string
  default     = "50Gi"
}

variable "node_selector" {
  description = "Node placement for the VictoriaLogs StatefulSet pod. Empty (default) lets the scheduler pick — fine with a Longhorn PV (it follows the pod). Pin only if using node-local storage."
  type        = map(string)
  default     = {}
}

variable "victorialogs_resources" {
  description = "Resource requests/limits for the VictoriaLogs pod. VictoriaLogs is light for a small cluster; raise limits if ingest volume grows."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "2", memory = "1Gi" }
  }
}

variable "vector_tolerations" {
  description = "Tolerations for the Vector DaemonSet so it runs on EVERY node (including tainted ones) — log collection must cover the whole cluster. Default tolerates everything (operate-everywhere collector); narrow it to exclude specific nodes."
  type        = list(any)
  default = [
    { operator = "Exists" },
  ]
}

variable "vector_resources" {
  description = "Resource requests/limits per Vector DaemonSet pod (one per node)."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { cpu = "500m", memory = "256Mi" }
  }
}

# ── Alerting (vmalert → Alertmanager → email) ────────────────────────────────

variable "alert_email" {
  description = "Destination address for log alerts. Empty (default) deploys NO alerting (no vmalert, no Alertmanager receiver) — the store + collector run alone. Set it to wire vmalert (evaluates the LogsQL rules against VictoriaLogs) + an AlertmanagerConfig email receiver on the existing kube-prometheus-stack Alertmanager."
  type        = string
  default     = ""
}

variable "smtp_smarthost" {
  description = "SMTP host:port Alertmanager sends through. Default is the in-cluster Stalwart inbound listener, which accepts unauthenticated submission for LOCAL recipients (e.g. an `@ipsupport.us` mailbox) — no relay-trust change or credentials needed. External recipients would require auth/relay changes (out of scope)."
  type        = string
  default     = "stalwart-smtp.mail.svc.cluster.local:25"
}

variable "smtp_from" {
  description = "Envelope/From address for alert emails."
  type        = string
  default     = "alerts@ipsupport.us"
}

variable "smtp_hello" {
  description = "EHLO hostname Alertmanager presents to the SMTP server. Must be a valid FQDN — the default pod hostname is not, and Stalwart rejects the session with `550 Invalid EHLO domain`."
  type        = string
  default     = "alertmanager.ipsupport.us"
}

variable "vmalert_image" {
  description = "vmalert container image (VictoriaMetrics' alerting evaluator). Runs the LogsQL rule groups against VictoriaLogs and fires to Alertmanager."
  type        = string
  default     = "victoriametrics/vmalert:v1.106.0"
}

variable "alertmanager_url" {
  description = "In-cluster Alertmanager endpoint vmalert fires alerts to (the existing kube-prometheus-stack Alertmanager)."
  type        = string
  default     = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
}

variable "vmalert_external_url" {
  description = "Browser-reachable base URL for vmalert (e.g. https://vmalert.example.com). Passed as `-external.url` so the `Source`/generator links vmalert stamps on alerts point at this host instead of the in-cluster pod address (a notification's \"Source\" button otherwise dead-ends). Empty (default) omits the flag — vmalert falls back to its pod address, unchanged. The module always emits a `kubernetes_service_v1.vmalert` (port 8880) so a consumer can route a hostname to it; this var only fixes the link vmalert generates."
  type        = string
  default     = ""
}

variable "alert_rules" {
  description = "Log alert rules the module renders into a vmalert `type: vlogs` rule group. Each: `query` is a LogsQL stats query ending in `stats count() as <name> | filter <name>:>N` (the time window lives in the query's `_time:` filter, the threshold in `| filter`); `for` is the sustain duration; `summary` is the notification text. The caller supplies these — the root wires a generic default set (panic/fatal/OOM) merged with the operator's `services.logging.alert_rules`."
  type = map(object({
    query    = string
    for      = optional(string, "5m")
    severity = optional(string, "warning")
    summary  = string
  }))
  default = {}
}
