variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context (still works, just doesn't carry the platform-tier tags)."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to install trivy-operator. False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace trivy-operator lands in. Module owns the namespace creation, so the name must not collide with one already managed elsewhere. It is always part of the scan allowlist."
  type        = string
  default     = "security-scan"
}

variable "trivy_operator_chart_version" {
  description = "Version of the upstream `trivy-operator` Helm chart (https://github.com/aquasecurity/trivy-operator). Pin to a known-good release; bump deliberately when upstream cuts a security fix or major version. Chart repo: https://aquasecurity.github.io/helm-charts/ ."
  type        = string
  default     = "0.36.0"
}

variable "trivy_operator_crds" {
  description = "CRD manifests of the trivy-operator chart at the pinned version (e.g. `data.helm_template` with `include_crds = true`, `.crds`), server-side applied by this module. Helm installs a chart's `crds/` once and never upgrades them, so without this the CRDs stay at the version first installed. Rendered by the caller because a data source inside a module with a module-level `depends_on` is deferred to apply whenever that dependency has pending changes, leaving the for_each keys unknown at plan."
  type        = list(string)
  default     = []
}

variable "extra_target_namespaces" {
  description = "Namespaces scanned in addition to the built-in platform-system allowlist."
  type        = list(string)
  default     = []
}

variable "node_selector" {
  description = "Node selector for the trivy-operator Deployment and its scan Jobs. Scan Jobs pull every scanned image and the vulnerability DB, so a node with fast egress keeps scans short. Empty (default) lets the scheduler pick."
  type        = map(string)
  default     = {}
}

variable "severity" {
  description = "Comma-separated severities trivy records in reports and metrics."
  type        = string
  default     = "HIGH,CRITICAL"
}

variable "ignore_unfixed" {
  description = "Drop findings that have no fixed version yet. They cannot be acted on, so with them every alert stays open forever."
  type        = bool
  default     = true
}

variable "scan_jobs_concurrent_limit" {
  description = "Maximum scan Jobs running at once. Scans share one trivy cache and one node; too many in parallel fail on the cache lock and starve the node."
  type        = number
  default     = 2
}

variable "scan_job_timeout" {
  description = "Deadline of one scan Job. Large images (databases, identity servers) need several minutes in slow mode."
  type        = string
  default     = "15m"
}

variable "scan_job_resources" {
  description = "Resources of each scan Job, in the chart's `trivy.resources` shape."
  type        = any
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "1", memory = "2Gi" }
  }
}

variable "operator_resources" {
  description = "Resources of the operator Deployment, in the chart's `resources` shape. The chart sets none."
  type        = any
  default = {
    requests = { cpu = "50m", memory = "256Mi" }
    limits   = { memory = "512Mi" }
  }
}

variable "service_monitor_enabled" {
  description = "Whether to emit a `ServiceMonitor` for trivy-operator's metrics endpoint, scraped by kube-prometheus-stack. Requires the ServiceMonitor CRD."
  type        = bool
  default     = false
}

variable "alerts_enabled" {
  description = "Whether to emit the PrometheusRule (image vulnerabilities + scanner no-data). Requires `service_monitor_enabled` and the PrometheusRule CRD."
  type        = bool
  default     = false

  validation {
    condition     = !var.alerts_enabled || var.service_monitor_enabled
    error_message = "alerts_enabled needs service_monitor_enabled: the rules evaluate the scanner's metrics."
  }
}

variable "alert_severities" {
  description = "Vulnerability severities (as in the `trivy_image_vulnerabilities` `severity` label) that raise an alert."
  type        = list(string)
  default     = ["Critical"]
}

variable "alert_labels" {
  description = "Extra labels on the alerts, typically what the Alertmanager routing matches on."
  type        = map(string)
  default     = {}
}

variable "grafana_dashboard_enabled" {
  description = "Emit a findings-table dashboard as a ConfigMap labelled `grafana_dashboard=1` in this module's namespace. Needs a Grafana dashboard sidecar that watches all namespaces (kube-prometheus-stack's does)."
  type        = bool
  default     = false
}

variable "builtin_trivy_server" {
  description = "Run trivy-operator's built-in trivy server and scan in ClientServer mode. The DB lives once on a PVC instead of in every scan Pod, and multi-container workloads no longer fail on the shared local cache lock."
  type        = bool
  default     = true
}

variable "trivy_server_storage_class" {
  description = "StorageClass of the trivy server's DB PVC. Empty = cluster default."
  type        = string
  default     = ""
}

variable "trivy_server_storage_size" {
  description = "Size of the trivy server's DB PVC (the vulnerability DB is under 1 GiB)."
  type        = string
  default     = "5Gi"
}

variable "trivy_server_resources" {
  description = "Resources of the built-in trivy server, in the chart's `trivy.server.resources` shape."
  type        = any
  default = {
    requests = { cpu = "100m", memory = "512Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}
