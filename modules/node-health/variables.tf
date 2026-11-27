variable "enabled" {
  description = "Install node-problem-detector, node-readiness-controller, the KernelDeadlock taint rule and its alerts. False removes them; the NodeReadinessRule CRD stays (Helm never deletes CRDs)."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Existing namespace both components run in (the module does not create it)."
  type        = string
  default     = "kube-system"
}

variable "node_selector" {
  description = "Labels of the nodes the KernelDeadlock taint rule covers (`spec.nodeSelector.matchLabels` of the NodeReadinessRule). node-readiness-controller rejects an empty selector; the default matches every Linux node. Changing it replaces the rule."
  type        = map(string)
  default     = { "kubernetes.io/os" = "linux" }

  validation {
    condition     = length(var.node_selector) > 0
    error_message = "node_selector must not be empty; use { \"kubernetes.io/os\" = \"linux\" } for every node."
  }
}

variable "dry_run" {
  description = "Run the taint rule in dry-run mode: node-readiness-controller reports in the rule's status.dryRunResults which nodes it would taint, and taints none. The KernelDeadlock condition and its alert work either way."
  type        = bool
  default     = true
}

variable "npd_chart_version" {
  description = "Version of the node-problem-detector Helm chart (https://github.com/deliveryhero/helm-charts, OCI oci://ghcr.io/deliveryhero/helm-charts)."
  type        = string
  default     = "2.4.2"
}

variable "npd_image_repository" {
  description = "node-problem-detector image repository (https://github.com/kubernetes/node-problem-detector)."
  type        = string
  default     = "registry.k8s.io/node-problem-detector/node-problem-detector"
}

variable "npd_image_tag" {
  description = "node-problem-detector image tag, digest-pinned. Ahead of the chart's app version (v1.35.1). `kernel-monitor.json` is the stock config of this version with one rule changed; compare it when upgrading."
  type        = string
  default     = "v1.37.0@sha256:a222c1bc31efe64a5698e8ba4ac7acf7f09f065eb2fbfb5c436488439decd69a"
}

variable "npd_resources" {
  description = "Container resources of node-problem-detector. It only follows the kernel log; the limit is a guard against a log flood."
  type        = any
  default = {
    requests = { cpu = "10m", memory = "40Mi" }
    limits   = { memory = "128Mi" }
  }
}

variable "nrc_chart_version" {
  description = "Version of the node-readiness-controller Helm chart (https://github.com/kubernetes-sigs/node-readiness-controller, OCI oci://registry.k8s.io/node-readiness-controller/charts). The image follows the chart's app version. Alpha project: its API (readiness.node.x-k8s.io/v1alpha1) may change between versions, and Helm installs the CRD only once (never upgrades it): on a bump, apply the new chart's CRD first."
  type        = string
  default     = "0.6.0"
}

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects PrometheusRules by."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
}
