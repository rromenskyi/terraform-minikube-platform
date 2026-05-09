variable "enabled" {
  description = "Whether to deploy Longhorn. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Longhorn lives in. Convention is `longhorn-system`; the chart hardcodes it for several internal references, so override only if a fleet-wide policy requires a different one."
  type        = string
  default     = "longhorn-system"
}

variable "version_pin" {
  description = "Helm chart version for longhorn/longhorn. Pinned so an upstream re-tag doesn't change behavior across applies."
  type        = string
  default     = "1.11.1"
}

variable "default_replica_count" {
  description = "Number of replicas Longhorn maintains for every new volume. 3 = one per node on a 3-node cluster (default). 1 keeps the volume single-node — useful for single-node dev clusters where the durability guarantee doesn't apply anyway."
  type        = number
  default     = 3
}

variable "tag_pools" {
  description = "Operator-defined topology pools. Each entry causes the engine to emit a sibling StorageClass named `longhorn-<key>` whose volumes are constrained to nodes carrying the specified Longhorn node tag (and optionally with a custom replica count + reclaim policy). Operator decides which pools exist (keys are operator-named, e.g. `home`, `edge`, `fast-ssd`) and tags the matching nodes one-time via `kubectl -n longhorn-system patch node.longhorn.io <name> --type=merge -p '{\"spec\":{\"tags\":[\"<key>\"]}}'`. Consumers (e.g. `services.redis.storage_class`) opt in by referencing `longhorn-<key>` SC name. Empty map (default) emits no extra SCs — only the default `longhorn` SC the chart creates is in play."
  type = map(object({
    replicas       = optional(number, 2)
    reclaim_policy = optional(string, "Delete")
    fs_type        = optional(string, "ext4")
    data_locality  = optional(string, "best-effort")
  }))
  default = {}
}

variable "default_data_path" {
  description = "Host directory each Longhorn instance-manager pod writes replica data to. Should NOT be the same path the platform's hostPath PVs use — keep blast radius separate."
  type        = string
  default     = "/var/lib/longhorn/"
}

variable "tolerations" {
  description = "Tolerations propagated to every Longhorn pod (manager DaemonSet, CSI components, UI, instance-managers). Empty = Longhorn pods land only on un-tainted nodes; on a tainted-edge or tainted-control-plane setup the storage layer must tolerate the same taints workloads do, otherwise replicas can't bind to those nodes and `replicaCount` can't be satisfied. Standard k8s toleration shape — passed both to the chart's `longhornManager` / `longhornUI` / `longhornDriver` values AND rendered into the Longhorn-format `taintToleration` setting for dynamic instance-managers."
  type = list(object({
    key                = optional(string)
    operator           = optional(string, "Exists")
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "backup_b2_bucket" {
  description = "B2 bucket for Longhorn native backups. May share the bucket with the restic backup pipeline; Longhorn's data lands under a separate `longhorn-volumes/` prefix automatically. Empty disables backup-target configuration; volumes still work, just can't be backed up via Longhorn's `BackupTarget` API."
  type        = string
  default     = ""
}

variable "backup_b2_endpoint" {
  description = "S3-compatible endpoint URL for the B2 region (`https://s3.<region>.backblazeb2.com`). Required when `backup_b2_bucket` is set."
  type        = string
  default     = ""
}

variable "backup_b2_region" {
  description = "Token Longhorn embeds in the `s3://<bucket>@<region>/` URL. B2 doesn't enforce AWS regional routing; the value just has to be non-empty. Uses the bucket region name from the endpoint by default."
  type        = string
  default     = "us-east-005"
}

variable "backup_b2_access_key_id" {
  description = "B2 application key id with read/write to `backup_b2_bucket`. Sourced from the operator's gitignored `.env`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_b2_secret_access_key" {
  description = "B2 application key secret matching `backup_b2_access_key_id`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "recurring_backup_cron" {
  description = "Cron schedule (UTC) for the per-volume daily backup RecurringJob applied to the `longhorn` StorageClass. Default 04:30 UTC — late enough that the platform restic backups (03:00–04:00 UTC) are done so the two pipelines don't compete for B2 bandwidth."
  type        = string
  default     = "30 4 * * *"
}

variable "recurring_backup_retain" {
  description = "Number of daily backups Longhorn keeps per volume before pruning. Pair with `recurring_backup_cron` — together they define the per-volume retention window."
  type        = number
  default     = 7
}
