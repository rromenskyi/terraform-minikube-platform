variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context`."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to deploy the NVR (Frigate). False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace of the NVR."
  type        = string
  default     = "nvr"
}

variable "image" {
  description = "Frigate image. Pin a tag and digest."
  type        = string
  default     = "ghcr.io/blakeblackshear/frigate:0.18.2@sha256:fd60f99ffd4eb6c42360ed4e14953e270586f239309ab3983e55b2e97ffac09a"
}

variable "frigate_config" {
  description = "Frigate configuration (the content of config.yml) as an object: cameras, go2rtc streams, detectors, record, objects. Credentials go in as `{FRIGATE_*}` placeholders, filled from the Vault secret at `vault_path`. The module only forces `mqtt.enabled = false` when `mqtt` is absent and the database location."
  type        = any
  default     = {}
}

variable "vault_path" {
  description = "KV v2 path (under mount `secret`) whose keys become environment variables of Frigate, e.g. `FRIGATE_<CAMERA>_USER` / `FRIGATE_<CAMERA>_PASSWORD`. Every key must start with `FRIGATE_` (Frigate substitutes only those)."
  type        = string
  default     = "platform/cameras"
}

variable "vault_auth_role" {
  description = "Narrow Vault role for VSO in this namespace (reads `vault_path` only). Empty uses VSO's default auth."
  type        = string
  default     = ""
}

variable "storage_class" {
  description = "StorageClass of the recordings and config volumes. Use a replicated class so the NVR can restart on another node with its recordings."
  type        = string
  default     = ""
}

variable "recordings_size" {
  description = "Size of the recordings volume (/media/frigate). Can be raised later if the StorageClass allows expansion."
  type        = string
  default     = "500Gi"
}

variable "config_size" {
  description = "Size of the config volume (/config: Frigate's database, model cache)."
  type        = string
  default     = "5Gi"
}

variable "shm_size" {
  description = "Size of /dev/shm (memory-backed). Frigate needs about (width × height × 1.5 + 270480) / 1048576 × 25 MB per camera at the detect resolution, plus ~50 MB."
  type        = string
  default     = "256Mi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.shm_size))
    error_message = "shm_size must be a whole number of Mi or Gi, e.g. 256Mi."
  }
}

variable "cache_size" {
  description = "Size of /tmp/cache (memory-backed), where recording segments wait before they are moved to the recordings volume."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.cache_size))
    error_message = "cache_size must be a whole number of Mi or Gi, e.g. 1Gi."
  }
}

variable "resources" {
  description = "Container resources. Memory-backed /dev/shm and /tmp/cache count against the memory limit."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "1", memory = "1Gi" }
    limits   = { cpu = "8", memory = "4Gi" }
  }

  validation {
    condition = alltrue([
      for q in [var.resources.limits, var.resources.requests] :
      can(regex("^[0-9]+(Mi|Gi)$", q.memory)) && can(regex("^[0-9]+m?$", q.cpu))
    ])
    error_message = "resources.limits and resources.requests: memory a whole number of Mi or Gi, cpu cores or millicores (e.g. 8 or 8000m)."
  }
}

variable "quota" {
  description = "ResourceQuota of the namespace (requests and limits share the numbers). Must cover `resources.limits` plus the init container."
  type = object({
    cpu    = string
    memory = string
  })
  default = { cpu = "10", memory = "6Gi" }

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.quota.memory)) && can(regex("^[0-9]+m?$", var.quota.cpu))
    error_message = "quota.memory must be a whole number of Mi or Gi and quota.cpu cores or millicores."
  }
}

variable "node_selector" {
  description = "Node selector for the NVR pod: nodes that can reach the cameras and hold copies of the volumes."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the NVR pod."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Equal")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "ingress_from_namespaces" {
  description = "Namespaces allowed to reach Frigate's pod (a NetworkPolicy): the ingress controller that fronts it with an authenticating gate and the Prometheus namespace. Port 5000 has no login of its own, so everything else in the cluster is kept out. Empty creates no NetworkPolicy."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.ingress_from_namespaces : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", n))])
    error_message = "ingress_from_namespaces: each entry must be a namespace name (DNS-1123 label); a typo would cut the ingress controller or Prometheus off."
  }
}

variable "volume_full_threshold" {
  description = "Alert when the recordings volume is fuller than this fraction."
  type        = number
  default     = 0.85

  validation {
    condition     = var.volume_full_threshold > 0 && var.volume_full_threshold < 1
    error_message = "volume_full_threshold is a fraction between 0 and 1 (0.85 = 85 %)."
  }
}
