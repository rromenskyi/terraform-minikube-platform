variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` so every resource carries the platform-tier tags. Default `null` produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to install the SMART exporter. False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Existing namespace the exporter lands in (the module does not create it). It must be one the cluster's Prometheus watches for ServiceMonitors."
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "Version of the upstream `prometheus-smartctl-exporter` Helm chart (https://github.com/prometheus-community/helm-charts). Chart repo: https://prometheus-community.github.io/helm-charts ."
  type        = string
  default     = "0.17.1"
}

variable "image_repository" {
  description = "smartctl_exporter image repository (https://github.com/prometheus-community/smartctl_exporter)."
  type        = string
  default     = "quay.io/prometheuscommunity/smartctl-exporter"
}

variable "image_tag" {
  description = "smartctl_exporter image tag, digest-pinned. Ahead of the chart's default app version: v0.15.0 handles NVMe drives behind bridges and fixes label conflicts between devices."
  type        = string
  default     = "v0.15.0@sha256:a76e08dbf5db4781fefd1ed81c65ad46ae8d2849dae6b6d3acebcde2fc4e59d6"
}

variable "affinity" {
  description = "Pod affinity of the exporter DaemonSet. SMART data exists only for physical drives, so on a mixed cluster limit it to the bare-metal nodes (virtual disks just log errors). Empty (default) = every node."
  type        = any
  default     = {}
}

variable "resources" {
  description = "Container resources of the exporter. It runs `smartctl` once per device every collection period, so it needs very little."
  type        = any
  default = {
    requests = { cpu = "10m", memory = "32Mi" }
    limits   = { cpu = "200m", memory = "64Mi" }
  }
}

variable "grafana_dashboard_enabled" {
  description = "Emit a disk health dashboard (SMART wear, writes, write latency, top writers) as a ConfigMap labelled `grafana_dashboard=1`. Needs a Grafana dashboard sidecar that watches this namespace (kube-prometheus-stack's does)."
  type        = bool
  default     = false
}
