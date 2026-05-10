variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy the Redis StatefulSet. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the Redis StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for Redis AOF data. Redis lands at <volume_base_path>/<namespace>/redis/. Must resolve to a real writable directory from the kubelet's point of view."
  type        = string
  default     = "/data/vol"
}

variable "memory_request" {
  description = "Memory request for the Redis pod. Redis mmaps its dataset, so this should comfortably cover the working set — anything less than 256Mi is cramped for AOF rewrites."
  type        = string
  default     = "256Mi"
}

variable "memory_limit" {
  description = "Memory limit for the Redis pod. Hitting this cap kills the pod and takes all tenants down — bump if you expect many large values."
  type        = string
  default     = "1Gi"
}

variable "node_selector" {
  description = "Node-selector labels the Redis pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "storage_class" {
  description = "StorageClass name for the Redis PVC. Empty (default) = no `storageClassName` field is set on the PVC, so the cluster's default StorageClass is used (typically `local-path` on k3s, hostPath-backed and node-pinned). Set to a HA-capable SC (e.g. one of `services.longhorn.tag_pools`'s `longhorn-<pool>` outputs) to opt the Redis volume into distributed block storage that survives node failure. The choice is operator-side per `services.redis.storage_class` in `config/platform.yaml` — engine stays generic and does not assume Longhorn or any particular SC implementation is present."
  type        = string
  default     = ""
}

variable "tolerations" {
  description = "Taints the Redis pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "affinity" {
  description = "Optional pod / node affinity rendered into the Bitnami `valkey` chart's `replica.affinity` block (sentinel mode). Standard Kubernetes affinity shape — `nodeAffinity`, `podAffinity`, `podAntiAffinity` map keys, native v1 schema. Common use: `nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution` excluding a high-latency node from the sentinel pool when the chart's default cluster-wide pod-anti-affinity would otherwise scatter a replica there. Single-instance mode ignores this input. Empty map (default) preserves the chart's default placement."
  type        = any
  default     = {}
}

variable "sentinel" {
  description = "Optional Valkey Sentinel HA topology. When `enabled = true`, the module switches from the default single-StatefulSet implementation to a Bitnami `valkey` Helm release running `architecture: replication` + `sentinel.enabled: true`, plus an HAProxy Deployment in front (sentinel-aware health checks via `tcp-check expect role:master`) so consumers keep talking to the flat `redis.<ns>.svc:6379` Service without any client-side changes. **Operator opts in** via `services.redis.sentinel:` in `config/platform.yaml`. Default `enabled = false` preserves the simple single-instance path. Switching `false → true` is a one-way data wipe (the existing single-instance PVC is destroyed when its for_each collapses; tenant ACL Jobs need re-trigger to repopulate per-tenant users on the fresh chart deploy)."
  type = object({
    enabled       = optional(bool, false)
    replica_count = optional(number, 3)
    quorum        = optional(number, 2)
    chart_version = optional(string, "5.6.1")
    # `image_tag` and `sentinel_image_tag` default to `latest` because
    # Bitnami / Broadcom moved every versioned `bitnami/<X>:<ver>` tag
    # to the paid Bitnami Secure Images registry in August 2025. The
    # free `docker.io/bitnami/*` images now ship ONLY `:latest` (every
    # prior `:9.x.y` is `404 not found`; the `bitnamilegacy/*` archive
    # does not back-fill). Pinning options short of paying:
    #   1. Digest-pin (`bitnami/valkey@sha256:...`) — works but needs
    #      manual digest bumps per upgrade, defeats reusable defaults.
    #   2. Switch off the Bitnami chart (run upstream `valkey/valkey`
    #      under our own StatefulSet, or move to the
    #      `valkeyio/valkey-helm-chart` community chart) — real long-
    #      term answer, deferred until a chart switch is on the table.
    # Operator may override here per-deployment if they hit a working
    # tag — but expect 404s on anything other than `latest`.
    image_repo          = optional(string, "bitnami/valkey")
    image_tag           = optional(string, "latest")
    sentinel_image_repo = optional(string, "bitnami/valkey-sentinel")
    sentinel_image_tag  = optional(string, "latest")
    haproxy_image       = optional(string, "haproxytech/haproxy-alpine:3.0")
    haproxy_replicas    = optional(number, 2)
  })
  default = {}
}
