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
}

variable "cache_size" {
  description = "Size of /tmp/cache (memory-backed), where recording segments wait before they are moved to the recordings volume."
  type        = string
  default     = "1Gi"
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
}

variable "quota" {
  description = "ResourceQuota of the namespace (requests and limits share the numbers). Must cover `resources.limits` plus the init container."
  type = object({
    cpu    = string
    memory = string
  })
  default = { cpu = "10", memory = "6Gi" }
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

variable "volume_full_threshold" {
  description = "Alert when the recordings volume is fuller than this fraction."
  type        = number
  default     = 0.85
}
