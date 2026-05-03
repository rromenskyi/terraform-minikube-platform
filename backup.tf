# Platform backups → Backblaze B2 via restic.
#
# Module + repo init only. The CronJobs that actually run live in
# `modules/backup`. This file's job is to:
#   1. Bridge the operator's `.env` B2 credentials and the
#      shared-service Secrets the cluster modules expose into a
#      single `module "backup"` invocation.
#   2. Copy the per-target source-of-truth Secrets (Postgres
#      superuser, MySQL root, Redis default user, Vault root
#      token) from their owning namespaces into the `backups`
#      namespace so the CronJobs can `envFrom`/`secret_key_ref`
#      them locally without cross-namespace RBAC.
#   3. Surface the restic passphrase as a sensitive root output
#      the operator can stash in their password manager.
#
# `services.backup.enabled` defaults to false. Operators that
# want backups set it to true in `config/platform.yaml` AND
# populate the matching `var.backup_b2_*` inputs in their
# gitignored `.env` (separate keys from the tfstate B2 bucket —
# blast-radius isolation is the whole point).

variable "backup_b2_bucket" {
  description = "Backblaze B2 bucket NAME used for backups. Should NOT match the bucket the Terraform S3 backend uses for tfstate. Sourced from the operator's gitignored `.env` as `TF_VAR_backup_b2_bucket`."
  type        = string
  default     = ""
}

variable "backup_b2_endpoint" {
  description = "S3-compatible endpoint URL for the B2 region the bucket lives in (e.g. `https://s3.us-east-005.backblazeb2.com`). Same shape as the existing `B2_ENDPOINT`. Empty disables the backup module via the precondition below."
  type        = string
  default     = ""
}

variable "backup_b2_access_key_id" {
  description = "B2 application key id with write access to `backup_b2_bucket`. SHOULD be a key separate from the tfstate-bucket key — a tfstate-key compromise must not delete or overwrite backups."
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

variable "backup_passphrase" {
  description = "Optional pre-set restic passphrase. Empty (default) lets the module generate a 32-char random value. Either way, the operator MUST stash the value (see `terraform output -raw backup_passphrase`) in their password manager — losing it bricks every encrypted backup forever."
  type        = string
  default     = ""
  sensitive   = true
}

check "backup_inputs_set_when_enabled" {
  assert {
    condition = !local.platform.services.backup.enabled || (
      var.backup_b2_bucket != "" &&
      var.backup_b2_endpoint != "" &&
      var.backup_b2_access_key_id != "" &&
      var.backup_b2_secret_access_key != ""
    )
    error_message = "services.backup.enabled = true requires TF_VAR_backup_b2_bucket / TF_VAR_backup_b2_endpoint / TF_VAR_backup_b2_access_key_id / TF_VAR_backup_b2_secret_access_key in the operator's gitignored .env. Use a separate B2 application key from the tfstate one — backup writes should survive a tfstate-key leak."
  }
}

# ── Cross-namespace Secret bridge ─────────────────────────────────────────
#
# CronJobs in `backups` namespace read DB / Vault credentials via
# `secret_key_ref`, which is namespace-local. Mirror the source
# Secrets here. `data` references the live Secret content so a
# rotation in the source namespace propagates on the next apply.

resource "kubernetes_secret_v1" "backup_postgres_superuser" {
  count = local.platform.services.backup.enabled && local.platform.services.postgres.enabled ? 1 : 0

  depends_on = [module.backup]

  metadata {
    name      = "postgres-superuser-mirror"
    namespace = "backups"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backup-creds"
    }
  }

  data = {
    POSTGRES_PASSWORD = data.kubernetes_secret_v1.postgres_superuser[0].data["POSTGRES_PASSWORD"]
  }
}

data "kubernetes_secret_v1" "postgres_superuser" {
  count = local.platform.services.backup.enabled && local.platform.services.postgres.enabled ? 1 : 0

  metadata {
    name      = module.postgres.superuser_secret_name
    namespace = module.postgres.namespace
  }
}

resource "kubernetes_secret_v1" "backup_mysql_root" {
  count = local.platform.services.backup.enabled && local.platform.services.mysql.enabled ? 1 : 0

  depends_on = [module.backup]

  metadata {
    name      = "mysql-root-mirror"
    namespace = "backups"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backup-creds"
    }
  }

  data = {
    MYSQL_ROOT_PASSWORD = data.kubernetes_secret_v1.mysql_root[0].data["MYSQL_ROOT_PASSWORD"]
  }
}

data "kubernetes_secret_v1" "mysql_root" {
  count = local.platform.services.backup.enabled && local.platform.services.mysql.enabled ? 1 : 0

  metadata {
    name      = module.mysql.root_secret_name
    namespace = module.mysql.namespace
  }
}

resource "kubernetes_secret_v1" "backup_redis_default" {
  count = local.platform.services.backup.enabled && local.platform.services.redis.enabled ? 1 : 0

  depends_on = [module.backup]

  metadata {
    name      = "redis-default-mirror"
    namespace = "backups"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backup-creds"
    }
  }

  data = {
    REDIS_PASSWORD = data.kubernetes_secret_v1.redis_default[0].data["REDIS_PASSWORD"]
  }
}

data "kubernetes_secret_v1" "redis_default" {
  count = local.platform.services.backup.enabled && local.platform.services.redis.enabled ? 1 : 0

  metadata {
    name      = module.redis.default_secret_name
    namespace = module.redis.namespace
  }
}

resource "kubernetes_secret_v1" "backup_vault_token" {
  count = local.platform.services.backup.enabled && local.platform.services.vault.enabled ? 1 : 0

  depends_on = [module.backup]

  metadata {
    name      = "vault-token-mirror"
    namespace = "backups"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backup-creds"
    }
  }

  data = {
    "root-token" = data.kubernetes_secret_v1.vault_bootstrap[0].data["root-token"]
  }
}

data "kubernetes_secret_v1" "vault_bootstrap" {
  count = local.platform.services.backup.enabled && local.platform.services.vault.enabled ? 1 : 0

  metadata {
    name      = "vault-bootstrap"
    namespace = "platform"
  }
}

# ── Module call ───────────────────────────────────────────────────────────

module "backup" {
  source = "./modules/backup"

  enabled = local.platform.services.backup.enabled

  b2_bucket            = var.backup_b2_bucket
  b2_endpoint          = var.backup_b2_endpoint
  b2_access_key_id     = var.backup_b2_access_key_id
  b2_secret_access_key = var.backup_b2_secret_access_key
  passphrase           = var.backup_passphrase

  # Postgres
  postgres_enabled          = local.platform.services.backup.enabled && local.platform.services.postgres.enabled
  postgres_host             = module.postgres.host
  postgres_superuser_secret = "postgres-superuser-mirror"
  postgres_databases        = local.platform.services.backup.postgres_databases

  # MySQL
  mysql_enabled     = local.platform.services.backup.enabled && local.platform.services.mysql.enabled
  mysql_host        = module.mysql.host
  mysql_root_secret = "mysql-root-mirror"
  mysql_databases   = local.platform.services.backup.mysql_databases

  # Redis
  redis_enabled        = local.platform.services.backup.enabled && local.platform.services.redis.enabled
  redis_host           = module.redis.host
  redis_default_secret = "redis-default-mirror"

  # Vault
  vault_enabled      = local.platform.services.backup.enabled && local.platform.services.vault.enabled
  vault_addr         = local.platform.services.vault.enabled ? "http://vault.platform.svc.cluster.local:8200" : ""
  vault_token_secret = "vault-token-mirror"

  # PV
  pv_enabled       = local.platform.services.backup.enabled && length(local.platform.services.backup.pv_paths) > 0
  pv_paths         = local.platform.services.backup.pv_paths
  pv_node_selector = local.platform.services.backup.pv_node_selector
  pv_tolerations   = local.platform.services.backup.pv_tolerations

  # Schedule + retention overrides (fall through to defaults
  # inside the module when the operator doesn't set them).
  schedule_postgres      = local.platform.services.backup.schedule_postgres
  schedule_mysql         = local.platform.services.backup.schedule_mysql
  schedule_redis         = local.platform.services.backup.schedule_redis
  schedule_vault         = local.platform.services.backup.schedule_vault
  schedule_pv            = local.platform.services.backup.schedule_pv
  schedule_prune         = local.platform.services.backup.schedule_prune
  retention_keep_daily   = local.platform.services.backup.retention_keep_daily
  retention_keep_weekly  = local.platform.services.backup.retention_keep_weekly
  retention_keep_monthly = local.platform.services.backup.retention_keep_monthly
}

output "backup_passphrase" {
  description = "restic repository passphrase. Pull with `terraform output -raw backup_passphrase` and stash in a password manager — losing it bricks every encrypted backup."
  value       = module.backup.passphrase
  sensitive   = true
}

output "backup_repository_url" {
  description = "restic repository URL (`s3:<endpoint>/<bucket>`). Used by `./tf backup-config` and every restore script."
  value       = module.backup.repository_url
}
