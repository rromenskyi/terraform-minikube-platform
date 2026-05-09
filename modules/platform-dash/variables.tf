variable "enabled" {
  description = "Whether to deploy the dashboard. Off → all resources count = 0."
  type        = bool
}

variable "namespace" {
  description = "Namespace to deploy into. Conventionally the shared `platform` namespace once promoted to first-class infra."
  type        = string
}

variable "image" {
  description = "Container image, tag included."
  type        = string
}

variable "replicas" {
  description = "Replica count. Defaults to 1; the dashboard is read-mostly so a single pod is enough."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Pod resource requests/limits."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
}

variable "hostname" {
  description = "Public hostname the dashboard answers on. Embedded as ORIGIN / AUTH_URL so cookie + OIDC redirect generation produces the right scheme + host even when behind cloudflared."
  type        = string
}

variable "oidc_secret_name" {
  description = "Name of the Secret in `namespace` that holds AUTH_ZITADEL_ISSUER / AUTH_ZITADEL_ID / AUTH_ZITADEL_SECRET / AUTH_SECRET. Produced by modules/zitadel-app."
  type        = string
}

variable "oidc_secret_checksum" {
  description = "SHA1 of the OIDC Secret data, mounted as a `checksum/oidc` annotation so a Zitadel app rotation rolls the pod automatically."
  type        = string
}

variable "node_selector" {
  description = "Node-selector labels the platform-dash pod must match. Empty = scheduler picks. The dash is stateless and can run anywhere; pin via `{ workload-tier = general }` or similar to keep it off the data node."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the platform-dash pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}
