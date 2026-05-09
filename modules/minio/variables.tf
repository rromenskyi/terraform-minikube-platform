variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to deploy MinIO. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace MinIO lives in. Convention is `platform`; the chart's bucket Secrets land in the consumer namespaces (see `var.buckets`), not here."
  type        = string
  default     = "platform"
}

variable "image" {
  description = "MinIO server container image. Pinned by tag — auto-update is opt-in via operator bumping the tag."
  type        = string
  default     = "minio/minio:RELEASE.2025-09-07T16-13-09Z"
}

variable "mc_image" {
  description = "MinIO Client image used by the bucket-provisioning Job. `mc admin user svcacct` shape is stable across recent releases. Tag is verified-pullable; bump as upstream cuts new releases."
  type        = string
  default     = "minio/mc:RELEASE.2025-08-13T08-35-41Z"
}

variable "storage_class" {
  description = "StorageClass for the MinIO PVC. Empty = cluster default (typically `local-path` on k3s, single-node hostPath). Set to a Longhorn pool SC name (e.g. `longhorn-stateful`) for cross-node replication so node-loss events re-attach the volume to a surviving node."
  type        = string
  default     = ""
}

variable "storage_size" {
  description = "PVC size for the MinIO data volume. Sized by what's archived — recordings dominate (typical sip-recorder WAV is ~1 MB / minute of call). Bump when archival cardinality grows."
  type        = string
  default     = "50Gi"
}

variable "node_selector" {
  description = "Node selector for the MinIO pod. Empty = scheduler picks. Pin to the `stateful` tier on a single-node-PV cluster so the PVC's local data dir is always reachable."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the MinIO pod. Empty = un-tainted nodes only."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "distributed" {
  description = "Optional distributed MinIO topology — `enabled = true` switches the module from a single-replica `Deployment` + one PVC to a `StatefulSet` with N replicas, each backed by its own PVC, with a headless Service for pod-to-pod traffic and `MINIO_VOLUMES` pointing at the per-pod hostnames so MinIO erasure-codes objects across the pool. The minimum legal `replica_count` is 4 (MinIO erasure coding requires at least 4 disks); `5` matches a single-pod-per-node spread on this 5-node cluster. Per-pod `storage_size` (set on `var.storage_size`) — total raw capacity is `storage_size × replica_count`, usable capacity is roughly `(replica_count - parity) × storage_size` (default parity 1, so 4 of 5 = 80% efficient on a 5-pod cluster). Anti-affinity spreads pods one-per-node by `kubernetes.io/hostname`. Empty / `enabled = false` keeps the standalone Deployment shape unchanged. Optional `hostpath_pvs` block opts into operator-pinned static `PersistentVolume`s (one per replica) backed by `hostPath` on a specific node — engine emits the PVs with `claimRef` pre-binding to the StatefulSet's `data-minio-<N>` PVCs, MinIO's app-layer erasure coding handles HA, no dynamic provisioner / Longhorn replication double-redundancy. When set: `node_hosts` is the per-replica hostname pin (length must equal `replica_count`) and `base_path` is the parent dir on each node — pod N gets `<base_path>/<N>` with `hostPath.type: DirectoryOrCreate`, kubelet auto-mkdir's at first attach. When omitted, the StatefulSet falls back to dynamic PVCs via `var.storage_class`."
  type = object({
    enabled       = optional(bool, false)
    replica_count = optional(number, 4)
    hostpath_pvs = optional(object({
      base_path  = string
      node_hosts = list(string)
    }))
  })
  default = {}
  validation {
    condition     = !try(var.distributed.enabled, false) || try(var.distributed.replica_count, 4) >= 4
    error_message = "distributed.replica_count must be at least 4 — MinIO erasure coding requires 4+ disks."
  }
  validation {
    condition     = try(var.distributed.hostpath_pvs, null) == null || length(try(var.distributed.hostpath_pvs.node_hosts, [])) == try(var.distributed.replica_count, 4)
    error_message = "distributed.hostpath_pvs.node_hosts length must equal distributed.replica_count — one hostname per replica."
  }
}

variable "buckets" {
  description = "Buckets the engine pre-creates and exposes via per-consumer Secrets. Map key is the bucket name (must match S3 naming rules: lowercase + dash). Each entry: `region` (string the SDK expects in `S3_REGION`; MinIO ignores it but boto3 / aws-sdk-go demand a value — default `auto` is universally accepted), `consumers` (list of `{namespace, secret_name}` — every consumer gets its own MinIO service-account key + its own Secret in its own namespace, so leakage of one Secret limits blast radius to that service-account and is revocable without bucket recreation; multiple consumers on the same bucket share data — same `s3:*` policy on the bucket per service-account, no per-consumer prefix scoping yet). Empty map = MinIO server runs but no buckets are pre-created."
  type = map(object({
    region = optional(string, "auto")
    consumers = list(object({
      namespace   = string
      secret_name = string
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, b in var.buckets : length(b.consumers) > 0
    ])
    error_message = "Every bucket must declare at least one consumer — a bucket with no consumers gets no Secret and is unreachable from any tenant."
  }
}
