variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy the PostgreSQL StatefulSet. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the PostgreSQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for PostgreSQL data. Lands at <volume_base_path>/<namespace>/postgres/."
  type        = string
  default     = "/data/vol"
}

variable "node_selector" {
  description = "Node-selector labels the Postgres pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the Postgres pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "service_selector" {
  description = "Pod selector of the `postgres` Service. Empty = this module's own pod (`app = postgres`). Set it to another server's primary (e.g. a CloudNativePG cluster's `cnpg.io/cluster` + `cnpg.io/instanceRole = primary` labels) to move every client that connects to `postgres` over to that server without touching the clients; clearing it moves them back."
  type        = map(string)
  default     = {}
}

variable "server_enabled" {
  description = "Run this module's own Postgres server (StatefulSet, data volume, extensions Job). False keeps only the `postgres` Service and the superuser Secret, for when another server took over through `service_selector`: clients keep their host and credentials. The data directory on the host stays in place (the PersistentVolume is `Retain`)."
  type        = bool
  default     = true
}
