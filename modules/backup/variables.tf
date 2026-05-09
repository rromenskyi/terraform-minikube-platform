variable "enabled" {
  description = "Whether to provision backup CronJobs + restic init Job. False collapses every resource — fresh clones stay clean."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the backup CronJobs run in. Created by this module so tenant ResourceQuotas stay isolated from backup workload."
  type        = string
  default     = "backups"
}

variable "b2_bucket" {
  description = "Backblaze B2 bucket name for backups. Should NOT be the same bucket the Terraform S3 backend uses for tfstate — keep blast radius separate."
  type        = string
}

variable "b2_endpoint" {
  description = "S3-compatible endpoint URL for the B2 bucket region (e.g. `https://s3.us-east-005.backblazeb2.com`). Same shape as `B2_ENDPOINT` in the operator's `.env` for tfstate."
  type        = string
}

variable "b2_access_key_id" {
  description = "B2 application key ID with write access to `b2_bucket`. Sourced from the operator's `.env`."
  type        = string
  sensitive   = true
}

variable "b2_secret_access_key" {
  description = "B2 application key secret matching `b2_access_key_id`. Sensitive — lands in a k8s Secret in `var.namespace`."
  type        = string
  sensitive   = true
}

variable "passphrase" {
  description = "Passphrase used to encrypt the restic repository. Empty (default) lets the module generate a random 32-char value via `random_password`; operators that prefer to manage the passphrase out-of-band can pass a non-empty value here. Either way, the passphrase MUST be stored in the operator's password manager — losing it bricks every backup forever (restic AES-256 has no recovery path)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "postgres_enabled" {
  description = "Whether to dump the shared Postgres on schedule. Off by default — disable when there's no Postgres in the platform OR when the operator handles dumps out-of-band."
  type        = bool
  default     = false
}

variable "postgres_host" {
  description = "In-cluster hostname for `pg_dump` connections (e.g. `postgres.platform.svc.cluster.local`)."
  type        = string
  default     = ""
}

variable "postgres_superuser_secret" {
  description = "Name of the Secret in `var.namespace` (created by this module via cross-namespace copy from the postgres module's superuser Secret) holding the `POSTGRES_PASSWORD` key. The CronJob mounts it for `pg_dump` auth."
  type        = string
  default     = ""
}

variable "postgres_databases" {
  description = "List of database names to dump on each Postgres backup run. Empty list = uses `pg_dumpall` instead, capturing everything in one stream. Per-database mode is preferred — restic dedup works better on smaller stable streams and a per-DB restore is simpler."
  type        = list(string)
  default     = []
}

variable "mysql_enabled" {
  description = "Whether to dump the shared MySQL on schedule."
  type        = bool
  default     = false
}

variable "mysql_host" {
  description = "In-cluster hostname for `mysqldump` connections."
  type        = string
  default     = ""
}

variable "mysql_root_secret" {
  description = "Name of the Secret in `var.namespace` holding the MySQL root password under `MYSQL_ROOT_PASSWORD`."
  type        = string
  default     = ""
}

variable "mysql_databases" {
  description = "List of MySQL database names to dump. Empty = `mysqldump --all-databases`."
  type        = list(string)
  default     = []
}

variable "redis_enabled" {
  description = "Whether to snapshot Redis on schedule via `redis-cli --rdb`."
  type        = bool
  default     = false
}

variable "redis_host" {
  description = "In-cluster hostname for `redis-cli`."
  type        = string
  default     = ""
}

variable "redis_default_secret" {
  description = "Name of the Secret in `var.namespace` holding the Redis `default` user password under `REDIS_PASSWORD`."
  type        = string
  default     = ""
}

variable "vault_enabled" {
  description = "Whether to take a `vault operator raft snapshot save` on schedule."
  type        = bool
  default     = false
}

variable "vault_addr" {
  description = "In-cluster Vault URL (e.g. `http://vault.platform.svc.cluster.local:8200`)."
  type        = string
  default     = ""
}

variable "vault_token_secret" {
  description = "Name of the Secret in `var.namespace` holding the Vault root token under `VAULT_TOKEN`. Phase 0 sources from the bootstrap Secret; future phases will use a dedicated backup-policy AppRole so the root token isn't day-to-day exposed."
  type        = string
  default     = ""
}

variable "pv_enabled" {
  description = "Whether to tar host-path PV directories on schedule. Pod runs with `hostNetwork = false` but `hostPath` mounts for each entry in `pv_paths`. Must run on the node that owns the data — set `pv_node_selector` accordingly."
  type        = bool
  default     = false
}

variable "pv_paths" {
  description = "List of host-path entries to back up. Each entry is `{ name, path }` where `name` is a stable identifier used as the restic snapshot tag (e.g. `stalwart-data`) and `path` is the absolute host directory (e.g. `/data/vol/platform/stalwart/data`)."
  type = list(object({
    name = string
    path = string
  }))
  default = []
}

variable "pv_node_selector" {
  description = "Node-selector for the PV backup CronJob. Required on multi-node clusters where hostPath PVs live on a single node — without it the scheduler can land the Job where the host directory is empty."
  type        = map(string)
  default     = {}
}

variable "pv_tolerations" {
  description = "Tolerations for the PV backup CronJob."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "schedule_postgres" {
  description = "Cron schedule for the Postgres dump CronJob (UTC)."
  type        = string
  default     = "0 3 * * *"
}

variable "schedule_mysql" {
  description = "Cron schedule for the MySQL dump CronJob (UTC). Offset 15 min from Postgres so the two don't pile up on the network at once."
  type        = string
  default     = "15 3 * * *"
}

variable "schedule_redis" {
  description = "Cron schedule for the Redis snapshot CronJob (UTC)."
  type        = string
  default     = "30 3 * * *"
}

variable "schedule_vault" {
  description = "Cron schedule for the Vault raft snapshot CronJob (UTC)."
  type        = string
  default     = "45 3 * * *"
}

variable "schedule_pv" {
  description = "Cron schedule for the hostPath PV tar CronJob (UTC). Weekly default — tarballs are heavier than DB dumps, restic dedup keeps the weekly cadence cheap."
  type        = string
  default     = "0 4 * * 0"
}

variable "schedule_prune" {
  description = "Cron schedule for the `restic forget --prune` retention CronJob (UTC). Weekly so the prune walk happens off-peak after the heaviest backup window."
  type        = string
  default     = "0 5 * * 0"
}

variable "retention_keep_daily" {
  description = "How many daily restic snapshots to keep per target."
  type        = number
  default     = 7
}

variable "retention_keep_weekly" {
  description = "How many weekly restic snapshots to keep per target."
  type        = number
  default     = 4
}

variable "retention_keep_monthly" {
  description = "How many monthly restic snapshots to keep per target."
  type        = number
  default     = 6
}

variable "image_alpine" {
  description = "Alpine image used as the base for every backup CronJob. Each Job apk-installs the tools it needs (postgresql-client, mysql-client, redis, restic, …) at start. Pinned to keep behavior stable across applies."
  type        = string
  default     = "alpine:3.22"
}
