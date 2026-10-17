variable "enabled" {
  description = "Whether to install the DRA driver for DRM render-node GPUs. False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace of the kubelet plugin DaemonSet."
  type        = string
  default     = "gpu-dra"
}

variable "image" {
  description = "Image of ipsupport-llc/dra-driver-dri."
  type        = string
}

variable "driver_name" {
  description = "DRA driver name: a DNS subdomain the operator owns. Also the DeviceClass name."
  type        = string
}

variable "node_selector" {
  description = "Labels of the nodes that have GPUs; the DaemonSet runs only there."
  type        = map(string)
}

variable "vram_reserve" {
  description = "VRAM held back per GPU for the kernel driver (Kubernetes quantity)."
  type        = string
  default     = "256Mi"
}

variable "rescan_interval" {
  description = "How often the plugin rescans sysfs (Go duration)."
  type        = string
  default     = "30s"
}

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects PodMonitors and PrometheusRules by."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
}
