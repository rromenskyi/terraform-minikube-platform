# CloudNativePG — a highly available Postgres cluster (modules/cnpg),
# configured under `services.cnpg` in the gitignored `config/platform.yaml`.
#
# It runs next to the single-instance `module.postgres`. Clients keep using
# `module.postgres` outputs (host `postgres`); moving them over takes three
# config steps, no client changes:
#   1. `sync_run` + `sync_mode = cutover`: a Job freezes `postgres` and copies
#      every database and role here, then verifies the copy;
#   2. `serve_postgres_service = true`: the `postgres` Service selects this
#      cluster's primary (postgres.tf);
#   3. rollback, if needed: `serve_postgres_service = false` and a
#      `sync_mode = thaw` run.
#
# The superuser password is the current server's, so tools that log in as
# `postgres` keep working on either server. Without a `module.postgres` the
# cluster gets a password of its own.

locals {
  cnpg = local.platform.services.cnpg
}

resource "random_password" "cnpg_superuser" {
  for_each = local.cnpg.enabled && !local.platform.services.postgres.enabled ? toset(["enabled"]) : toset([])

  length  = 32
  special = false
}

module "cnpg" {
  source     = "./modules/cnpg"
  depends_on = [module.addons]

  context = module.platform_label.context
  enabled = local.cnpg.enabled

  namespace    = kubernetes_namespace_v1.platform.metadata[0].name
  name         = local.cnpg.name
  instances    = local.cnpg.instances
  nodes        = local.cnpg.nodes
  synchronous  = local.cnpg.synchronous
  storage_size = local.cnpg.storage_size

  superuser_password = local.platform.services.postgres.enabled ? module.postgres.superuser_password : one([for p in random_password.cnpg_superuser : p.result])

  # Same bucket and key as the restic backups (backup.tf), under its own
  # prefix. Empty when the operator has no backup bucket configured.
  backup_bucket            = var.backup_b2_bucket
  backup_endpoint          = var.backup_b2_endpoint
  backup_access_key_id     = var.backup_b2_access_key_id
  backup_secret_access_key = var.backup_b2_secret_access_key
  backup_prefix            = local.cnpg.backup_prefix
  backup_retention         = local.cnpg.backup_retention
  backup_schedule          = local.cnpg.backup_schedule

  # Only from a running `postgres` server: once it is off, `postgres` is
  # this cluster itself.
  sync = local.platform.services.postgres.enabled && local.platform.services.postgres.server_enabled ? {
    source_host   = module.postgres.host
    source_secret = module.postgres.superuser_secret_name
    run           = local.cnpg.sync_run
    mode          = local.cnpg.sync_mode
  } : null
}
