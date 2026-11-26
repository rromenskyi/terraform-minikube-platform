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

variable "device_shares" {
  description = "Consumable `shares` capacity each GPU publishes; a claim takes one unless it asks for more. 0 publishes none (behaviour as before)."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.device_shares >= 0 && floor(var.device_shares) == var.device_shares
    error_message = "device_shares must be a whole number >= 0."
  }
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
