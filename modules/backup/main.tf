# Platform backups → Backblaze B2 via restic.
#
# One restic repository on a dedicated B2 bucket carries every
# backup target (Postgres dumps, MySQL dumps, Redis snapshots,
# Vault raft snapshots, hostPath PV tarballs, operator-side
# config/.env). Encryption is built into restic (AES-256 + a
# single passphrase shared across targets). Retention is
# `restic forget --prune` on a weekly cron with daily/weekly/
# monthly slots.
#
# Restore scripts ship in this module's `scripts/` directory and
# are pushed into the restic repo as a `scripts` tag on every
# init Job run, so a complete cluster wipe + lost local repo
# still leaves the operator with `restic restore latest --tag
# scripts → run` as the disaster-recovery starting point.
#
# Three layers of secret storage make passphrase loss survivable:
#   - Generated once via `random_password.backup_passphrase`,
#     surfaced as a sensitive Terraform output. Operator pastes
#     into a personal password manager — that is the only
#     long-term source of truth.
#   - Mounted into in-cluster CronJobs via a k8s Secret in this
#     module's namespace.
#   - Operator's `.env` may carry it as `TF_VAR_backup_passphrase`
#     for the wrapper-side `./tf backup-config` invocation;
#     gitignored, never reaches the public repo.
#
# B2 credentials are sourced from the same `.env` shape the
# Terraform S3 backend already uses for tfstate
# (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), but pointed at
# a dedicated `backups` bucket so a tfstate-key compromise can't
# delete or overwrite backups.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── Inputs ─────────────────────────────────────────────────────────────────

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

# Postgres target ----------------------------------------------------------

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

# MySQL target -------------------------------------------------------------

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

# Redis target -------------------------------------------------------------

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

# Vault target -------------------------------------------------------------

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

# PV target ----------------------------------------------------------------

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

# Schedule + retention -----------------------------------------------------

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

# ── Locals ────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  passphrase = var.passphrase != "" ? var.passphrase : (
    var.enabled ? random_password.backup_passphrase[0].result : ""
  )

  # restic repo URL = `s3:<endpoint>/<bucket>`. Same encoding the
  # tfstate backend uses for B2.
  repository_url = "s3:${var.b2_endpoint}/${var.b2_bucket}"

  postgres_set = var.enabled && var.postgres_enabled ? toset(["enabled"]) : toset([])
  mysql_set    = var.enabled && var.mysql_enabled ? toset(["enabled"]) : toset([])
  redis_set    = var.enabled && var.redis_enabled ? toset(["enabled"]) : toset([])
  vault_set    = var.enabled && var.vault_enabled ? toset(["enabled"]) : toset([])
  pv_set       = var.enabled && var.pv_enabled && length(var.pv_paths) > 0 ? toset(["enabled"]) : toset([])

  # Common shell preamble all CronJob containers share. `set -e`
  # so a failing pg_dump / restic backup propagates to the Pod
  # status. `apk add restic` lands the binary at /usr/bin/restic.
  # The retention CronJob only needs restic; the dump CronJobs
  # additionally apk-install the per-target client.
  restic_env = "RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD=$RESTIC_PASSWORD AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"

  # Restore scripts read from `scripts/` directory and bundled
  # into a ConfigMap. The init Job uploads them to the restic
  # repo under the `scripts` tag so a disaster-recovery operator
  # with only the passphrase + B2 creds can pull them back.
  restore_scripts = {
    "restore-postgres.sh" = file("${path.module}/scripts/restore-postgres.sh")
    "restore-mysql.sh"    = file("${path.module}/scripts/restore-mysql.sh")
    "restore-redis.sh"    = file("${path.module}/scripts/restore-redis.sh")
    "restore-vault.sh"    = file("${path.module}/scripts/restore-vault.sh")
    "restore-pv.sh"       = file("${path.module}/scripts/restore-pv.sh")
    "restore-config.sh"   = file("${path.module}/scripts/restore-config.sh")
    "README.md"           = file("${path.module}/scripts/README.md")
  }
}

# ── Passphrase generation ─────────────────────────────────────────────────

resource "random_password" "backup_passphrase" {
  count = var.enabled && var.passphrase == "" ? 1 : 0

  length  = 32
  special = false

  # Pin to the bucket name so a bucket rename (= a fresh restic
  # repo) regenerates a fresh passphrase. Same-bucket re-applies
  # keep the existing passphrase — losing it isn't a recoverable
  # event.
  keepers = {
    bucket = var.b2_bucket
  }
}

# ── Namespace + Secret ────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "backup" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backup"
    }
  }
}

# All CronJobs read this Secret via `envFrom`. Holds restic repo
# URL + passphrase + B2 creds + (optionally) per-target client
# credentials. Per-target credentials are also written here as
# additional keys so each Job's env is one Secret pull.
resource "kubernetes_secret_v1" "backup_creds" {
  for_each = local.instances

  metadata {
    name      = "backup-creds"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  data = {
    RESTIC_REPOSITORY     = local.repository_url
    RESTIC_PASSWORD       = local.passphrase
    AWS_ACCESS_KEY_ID     = var.b2_access_key_id
    AWS_SECRET_ACCESS_KEY = var.b2_secret_access_key
  }

  type = "Opaque"
}

# Restore-scripts ConfigMap. Mounted into the init Job so it can
# `restic backup` them into the repo with tag `scripts`.
resource "kubernetes_config_map_v1" "restore_scripts" {
  for_each = local.instances

  metadata {
    name      = "backup-restore-scripts"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  data = local.restore_scripts
}

# ── Repo init Job ─────────────────────────────────────────────────────────
#
# Idempotent. `restic init` returns a non-zero exit code when the
# repo already exists; the script ignores that specific error and
# proceeds to upload the restore scripts under tag `scripts`.
# Running again is harmless — restic dedup makes the script
# upload a no-op on identical content.

resource "kubernetes_job_v1" "restic_init" {
  for_each = local.instances

  metadata {
    name      = "backup-restic-init"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "backup-init"
    }
  }

  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-init" }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "init"
          image = var.image_alpine

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
            }
          }

          command = ["sh", "-c"]
          args = [<<-EOT
            set -e
            apk add --no-cache restic >/dev/null
            echo "[init] checking repository at $RESTIC_REPOSITORY"
            if restic snapshots --no-lock >/dev/null 2>&1; then
              echo "[init] repository already initialised — skipping init"
            else
              echo "[init] initialising fresh repository"
              restic init
            fi
            echo "[init] uploading restore scripts as tag=scripts"
            restic backup --tag scripts /scripts
            echo "[init] done"
          EOT
          ]

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map_v1.restore_scripts["enabled"].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }
}

# ── Postgres dump CronJob ─────────────────────────────────────────────────

resource "kubernetes_cron_job_v1" "postgres" {
  for_each = local.postgres_set

  metadata {
    name      = "backup-postgres"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_postgres
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-postgres" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400 # 1 day

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-postgres" }
          }
          spec {
            restart_policy = "OnFailure"

            container {
              name  = "dump"
              image = var.image_alpine

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "PGHOST"
                value = var.postgres_host
              }
              env {
                name  = "PGUSER"
                value = "postgres"
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = var.postgres_superuser_secret
                    key  = "POSTGRES_PASSWORD"
                  }
                }
              }
              env {
                name  = "DATABASES"
                value = join(" ", var.postgres_databases)
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                apk add --no-cache restic postgresql16-client >/dev/null

                STAGE=$(mktemp -d)
                trap 'rm -rf "$STAGE"' EXIT

                if [ -z "$DATABASES" ]; then
                  echo "[postgres] DATABASES empty — pg_dumpall"
                  pg_dumpall --clean --if-exists | gzip -9 >"$STAGE/all.sql.gz"
                else
                  for db in $DATABASES; do
                    echo "[postgres] pg_dump $db"
                    pg_dump --clean --if-exists -d "$db" | gzip -9 >"$STAGE/$db.sql.gz"
                  done
                fi

                echo "[postgres] restic backup"
                restic backup --host platform-postgres --tag postgres "$STAGE"
                echo "[postgres] done"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── MySQL dump CronJob ────────────────────────────────────────────────────

resource "kubernetes_cron_job_v1" "mysql" {
  for_each = local.mysql_set

  metadata {
    name      = "backup-mysql"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_mysql
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-mysql" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-mysql" }
          }
          spec {
            restart_policy = "OnFailure"

            container {
              name  = "dump"
              image = var.image_alpine

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "MYSQL_HOST"
                value = var.mysql_host
              }
              env {
                name = "MYSQL_PWD"
                value_from {
                  secret_key_ref {
                    name = var.mysql_root_secret
                    key  = "MYSQL_ROOT_PASSWORD"
                  }
                }
              }
              env {
                name  = "DATABASES"
                value = join(" ", var.mysql_databases)
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                apk add --no-cache restic mariadb-client >/dev/null

                STAGE=$(mktemp -d)
                trap 'rm -rf "$STAGE"' EXIT

                if [ -z "$DATABASES" ]; then
                  echo "[mysql] DATABASES empty — mysqldump --all-databases"
                  mysqldump -h "$MYSQL_HOST" -u root --single-transaction \
                    --quick --all-databases | gzip -9 >"$STAGE/all.sql.gz"
                else
                  for db in $DATABASES; do
                    echo "[mysql] mysqldump $db"
                    mysqldump -h "$MYSQL_HOST" -u root --single-transaction \
                      --quick "$db" | gzip -9 >"$STAGE/$db.sql.gz"
                  done
                fi

                echo "[mysql] restic backup"
                restic backup --host platform-mysql --tag mysql "$STAGE"
                echo "[mysql] done"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── Redis snapshot CronJob ────────────────────────────────────────────────

resource "kubernetes_cron_job_v1" "redis" {
  for_each = local.redis_set

  metadata {
    name      = "backup-redis"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_redis
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-redis" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-redis" }
          }
          spec {
            restart_policy = "OnFailure"

            container {
              name  = "snapshot"
              image = var.image_alpine

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "REDIS_HOST"
                value = var.redis_host
              }
              env {
                name = "REDIS_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = var.redis_default_secret
                    key  = "REDIS_PASSWORD"
                  }
                }
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                apk add --no-cache restic redis >/dev/null

                STAGE=$(mktemp -d)
                trap 'rm -rf "$STAGE"' EXIT

                echo "[redis] redis-cli --rdb"
                redis-cli -h "$REDIS_HOST" -a "$REDIS_PASSWORD" --no-auth-warning \
                  --rdb "$STAGE/dump.rdb"

                echo "[redis] restic backup"
                restic backup --host platform-redis --tag redis "$STAGE"
                echo "[redis] done"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── Vault raft snapshot CronJob ───────────────────────────────────────────

resource "kubernetes_cron_job_v1" "vault" {
  for_each = local.vault_set

  metadata {
    name      = "backup-vault"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_vault
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-vault" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-vault" }
          }
          spec {
            restart_policy = "OnFailure"

            container {
              name  = "snapshot"
              image = "hashicorp/vault:1.18.4"

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "VAULT_ADDR"
                value = var.vault_addr
              }
              env {
                name = "VAULT_TOKEN"
                value_from {
                  secret_key_ref {
                    name = var.vault_token_secret
                    key  = "root-token"
                  }
                }
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                # vault image is alpine-based; apk works.
                apk add --no-cache restic >/dev/null

                STAGE=$(mktemp -d)
                trap 'rm -rf "$STAGE"' EXIT

                echo "[vault] operator raft snapshot save"
                vault operator raft snapshot save "$STAGE/vault.snap"

                echo "[vault] restic backup"
                restic backup --host platform-vault --tag vault "$STAGE"
                echo "[vault] done"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── PV tar CronJob ────────────────────────────────────────────────────────

resource "kubernetes_cron_job_v1" "pv" {
  for_each = local.pv_set

  metadata {
    name      = "backup-pv"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_pv
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-pv" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-pv" }
          }
          spec {
            restart_policy = "OnFailure"
            node_selector  = length(var.pv_node_selector) > 0 ? var.pv_node_selector : null

            dynamic "toleration" {
              for_each = var.pv_tolerations
              content {
                key                = toleration.value.key
                operator           = toleration.value.operator
                value              = toleration.value.value
                effect             = toleration.value.effect
                toleration_seconds = toleration.value.toleration_seconds
              }
            }

            container {
              name  = "tar"
              image = var.image_alpine

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "PV_NAMES"
                value = join(",", [for p in var.pv_paths : p.name])
              }
              env {
                name  = "PV_PATHS"
                value = join(",", [for p in var.pv_paths : p.path])
              }

              security_context {
                # Tar of host-mount paths needs root to read every
                # file regardless of UIDs the apps run as.
                run_as_user                = 0
                allow_privilege_escalation = false
                capabilities {
                  drop = ["ALL"]
                  add  = ["DAC_READ_SEARCH"]
                }
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                apk add --no-cache restic >/dev/null

                STAGE=$(mktemp -d)
                trap 'rm -rf "$STAGE"' EXIT

                IFS=','; set -- $PV_NAMES
                NAMES=("$@")
                set -- $PV_PATHS
                PATHS=("$@")
                IFS=' '

                i=0
                while [ $i -lt $${#NAMES[@]} ]; do
                  name="$${NAMES[$i]}"
                  path="$${PATHS[$i]}"
                  echo "[pv] tar $name from $path"
                  tar -czf "$STAGE/$name.tar.gz" -C "$path" .
                  i=$((i+1))
                done

                echo "[pv] restic backup"
                restic backup --host platform-pv --tag pv "$STAGE"
                echo "[pv] done"
              EOT
              ]

              dynamic "volume_mount" {
                for_each = var.pv_paths
                content {
                  name       = "pv-${replace(volume_mount.value.name, "/", "-")}"
                  mount_path = volume_mount.value.path
                  read_only  = true
                }
              }

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }

            dynamic "volume" {
              for_each = var.pv_paths
              content {
                name = "pv-${replace(volume.value.name, "/", "-")}"
                host_path {
                  path = volume.value.path
                  type = "Directory"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── Retention CronJob ─────────────────────────────────────────────────────

resource "kubernetes_cron_job_v1" "prune" {
  for_each = local.instances

  metadata {
    name      = "backup-prune"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_prune
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = { "app.kubernetes.io/component" = "backup-prune" }
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = { "app.kubernetes.io/component" = "backup-prune" }
          }
          spec {
            restart_policy = "OnFailure"

            container {
              name  = "prune"
              image = var.image_alpine

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }

              env {
                name  = "KEEP_DAILY"
                value = tostring(var.retention_keep_daily)
              }
              env {
                name  = "KEEP_WEEKLY"
                value = tostring(var.retention_keep_weekly)
              }
              env {
                name  = "KEEP_MONTHLY"
                value = tostring(var.retention_keep_monthly)
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -e
                apk add --no-cache restic >/dev/null
                echo "[prune] forget --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY"
                restic forget --group-by host,tags --keep-daily "$KEEP_DAILY" \
                  --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune
                echo "[prune] done"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

# ── Outputs ───────────────────────────────────────────────────────────────

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Backups namespace, or null when disabled."
}

output "passphrase" {
  value       = local.passphrase
  sensitive   = true
  description = "restic repository passphrase. Pull with `terraform output -raw backup_passphrase` (root output) and stash in a password manager — losing it bricks every backup."
}

output "repository_url" {
  value       = var.enabled ? local.repository_url : null
  description = "restic repository URL (`s3:<endpoint>/<bucket>`). Used by the wrapper-side `./tf backup-config` command and by every restore-script."
}
