variable "context" {
  description = "Serialised parent context from `terraform-null-label` (the root passes `module.platform_label.context`), so the labels on every object the module creates match the rest of the platform."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Install the operator and the cluster. False collapses every resource to zero."
  type        = bool
  default     = false
}

# ── Operator ────────────────────────────────────────────────────────────────

variable "operator_namespace" {
  description = "Namespace for the CloudNativePG operator and the Barman Cloud plugin (the plugin must live next to the operator). The module creates it."
  type        = string
  default     = "cnpg-system"
}

variable "operator_chart_version" {
  description = "Version of the `cloudnative-pg` Helm chart (cloudnative-pg.github.io/charts)."
  type        = string
  default     = "0.29.1"
}

variable "barman_plugin_chart_version" {
  description = "Version of the `plugin-barman-cloud` Helm chart. It needs cert-manager in the cluster."
  type        = string
  default     = "0.8.1"
}

# ── Cluster ─────────────────────────────────────────────────────────────────

variable "namespace" {
  description = "Namespace the Postgres cluster runs in. Expected to exist already."
  type        = string
}

variable "name" {
  description = "Cluster name. CloudNativePG derives the Services from it: `<name>-rw` (primary), `<name>-ro` (replicas), `<name>-r` (any)."
  type        = string
  default     = "pg"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a DNS label starting with a letter."
  }
}

variable "image" {
  description = "Postgres image (CloudNativePG operand image). `standard` images carry the contrib extensions and all locales."
  type        = string
  default     = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie"
}

variable "instances" {
  description = "Postgres instances: one primary plus `instances - 1` streaming replicas, each on a different node."
  type        = number
  default     = 2

  validation {
    condition     = var.instances >= 1
    error_message = "instances must be at least 1."
  }
}

variable "nodes" {
  description = "Hostnames (`kubernetes.io/hostname`) the instances may run on. Empty = any node. Instances never share a node, so list at least `instances` nodes."
  type        = list(string)
  default     = []
}

variable "synchronous" {
  description = "Synchronous replication with `dataDurability: preferred`: a commit waits until one replica has it, but writes go on when no replica is healthy. False = asynchronous. Ignored with a single instance."
  type        = bool
  default     = true
}

variable "storage_class" {
  description = "StorageClass for the data volumes. A node-local class (`local-path`) suits Postgres: the replicas already copy the data, so the storage layer does not need to."
  type        = string
  default     = "local-path"
}

variable "storage_size" {
  description = "Data volume size per instance."
  type        = string
  default     = "20Gi"
}

variable "resources" {
  description = "Requests and limits of each Postgres container. The operator gives its init and join containers the same, so a namespace ResourceQuota that requires limits is satisfied only with both `cpu` and `memory` limits set."
  type = object({
    requests = optional(map(string), { cpu = "100m", memory = "256Mi" })
    limits   = optional(map(string), { cpu = "1", memory = "1Gi" })
  })
  default = {}
}

variable "parameters" {
  description = "Extra `postgresql.conf` parameters (`postgresql.parameters`). CloudNativePG manages replication and archiving settings itself."
  type        = map(string)
  default     = {}
}

variable "service_name" {
  description = "Extra Service clients connect to, selecting the current primary (e.g. the name clients of a server this cluster replaces already use). Empty = only the operator's `<name>-rw` / `-ro` / `-r` Services."
  type        = string
  default     = ""
}

variable "superuser_secret_name" {
  description = "Name of the Secret with the `postgres` superuser credentials. Empty = `<name>-superuser`."
  type        = string
  default     = ""
}

variable "superuser_password" {
  description = "Password of the `postgres` superuser. Pass the current server's password so that tools logging in as `postgres` keep working after a switch."
  type        = string
  sensitive   = true
}

# ── Backups (Barman Cloud plugin → S3-compatible storage) ─────────────────

variable "backup_bucket" {
  description = "Bucket for the WAL archive and base backups. Empty (with `backup_endpoint`) leaves backups off."
  type        = string
  default     = ""
}

variable "backup_endpoint" {
  description = "S3-compatible endpoint URL (e.g. `https://s3.us-east-005.backblazeb2.com`)."
  type        = string
  default     = ""
}

variable "backup_prefix" {
  description = "Path inside the bucket. Backups land under `s3://<bucket>/<prefix>/<cluster name>/`."
  type        = string
  default     = "cnpg"
}

variable "backup_access_key_id" {
  description = "Access key id for the bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_secret_access_key" {
  description = "Secret access key for the bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_sidecar_resources" {
  description = "Requests and limits of the Barman Cloud sidecar the plugin adds to every instance pod (it ships WAL and runs base backups)."
  type = object({
    requests = optional(map(string), { cpu = "50m", memory = "64Mi" })
    limits   = optional(map(string), { cpu = "500m", memory = "512Mi" })
  })
  default = {}
}

variable "backup_retention" {
  description = "How long base backups and the WAL they need are kept (Barman retention policy, e.g. `30d`)."
  type        = string
  default     = "30d"
}

variable "backup_schedule" {
  description = "Base backup schedule. Six-field cron with seconds first (`0 0 2 * * *` = 02:00 daily)."
  type        = string
  default     = "0 0 2 * * *"
}

# ── Monitoring ──────────────────────────────────────────────────────────────

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects PodMonitors and PrometheusRules by (kube-prometheus-stack: `release = <its release name>`)."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
}

# ── One-off copy from another Postgres server ───────────────────────────────

variable "sync" {
  description = <<-EOT
    Copy every database and role from another Postgres server into this cluster with a Job, e.g. to move off a single-instance server. Null = no Job.
    - `source_host` / `source_secret`: the server and a Secret in `namespace` with its superuser password under `POSTGRES_PASSWORD`.
    - `run`: any id; the Job runs once per value (change it to run again). Empty = no Job.
    - `mode`:
      - `rehearsal` copies while the source keeps running and taking writes; the copy is a throwaway, row-count differences are reported, not fatal.
      - `cutover` first freezes the source (`CONNECTION LIMIT 0` on its databases and ends non-superuser sessions; superusers still connect), so nothing is written after the dump starts; then copies and fails on any row-count or role difference.
      - `thaw` only lifts the freeze (`CONNECTION LIMIT -1`), to roll a cutover back.
    Every copy recreates the target databases (`pg_dump --create --clean`), so nothing may use them yet. Roles keep their password hashes, so client credentials stay valid.
  EOT
  type = object({
    source_host   = string
    source_secret = string
    run           = optional(string, "")
    mode          = optional(string, "rehearsal")
  })
  default = null

  validation {
    condition     = var.sync == null || contains(["rehearsal", "cutover", "thaw"], try(var.sync.mode, ""))
    error_message = "sync.mode must be `rehearsal`, `cutover` or `thaw`."
  }

  validation {
    condition     = var.sync == null || can(regex("^([a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?)?$", try(var.sync.run, "")))
    error_message = "sync.run must be empty or a short DNS label (it is part of the Job name)."
  }
}
