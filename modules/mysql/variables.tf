variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy the MySQL StatefulSet. When `false`, no resources are created and every output collapses to null — a disabled MySQL cleanly cascades into `modules/project` (components with `db: true` fail a precondition instead of silently deploying a broken StatefulSet)."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the MySQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it so the sibling Postgres/Redis/Ollama modules can share the same namespace without piggybacking on this module. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for MySQL data. MySQL lands at <volume_base_path>/<namespace>/mysql/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol)."
  type        = string
  default     = "/data/vol"
}

variable "storage_class" {
  description = "StorageClass for the data directory. Empty: a hostPath PV under `volume_base_path` (the original layout). Set: a dynamic PVC `data-mysql`, layout per modules/volume-seed (the datadir is the volume's `data/`, so `lost+found` never reaches mysqld)."
  type        = string
  default     = ""
}

variable "storage_seed_node" {
  description = "With `storage_class` set: the node holding the old hostPath datadir. On the first start an init container copies it into the new volume (only into an empty one, once; MySQL is stopped, so the copy is consistent), and the pod is pinned to this node meanwhile. Clear it once the data has moved."
  type        = string
  default     = ""
}

variable "node_selector" {
  description = "Node-selector labels the MySQL pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the MySQL pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "resources" {
  description = "CPU/memory requests and limits for the MySQL container. Size the memory request to the server's working set (InnoDB buffer pool plus per-connection buffers) and leave the limit enough headroom above it: hitting the limit OOM-kills the database."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "500m", memory = "1Gi" }
  }
  nullable = false
}
