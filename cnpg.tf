# CloudNativePG — a highly available Postgres cluster (modules/cnpg),
# configured under `services.cnpg` in the gitignored `config/platform.yaml`.
#
# With `services.postgres.engine = cnpg` it is the platform's Postgres: it
# owns the `services.postgres.service_name` Service and the superuser Secret
# that clients use (postgres.tf). With `engine = single` it can run next to
# the single server, unused by clients, e.g. to move over: `sync_run` with
# `sync_mode = rehearsal` / `cutover` copies every database and role from
# the single server, then the engine switch hands clients over.

locals {
  cnpg = local.platform.services.cnpg
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

  # The platform's superuser password (postgres.tf), whichever engine
  # serves clients; the Service and Secret names only while it serves them.
  superuser_password    = one([for p in random_password.postgres_superuser : p.result])
  service_name          = local.postgres_on && local.postgres_engine == "cnpg" ? local.platform.services.postgres.service_name : ""
  superuser_secret_name = local.postgres_on && local.postgres_engine == "cnpg" ? "${local.platform.services.postgres.service_name}-superuser" : ""

  # Same bucket and key as the restic backups (backup.tf), under its own
  # prefix. Empty when the operator has no backup bucket configured.
  backup_bucket            = var.backup_b2_bucket
  backup_endpoint          = var.backup_b2_endpoint
  backup_access_key_id     = var.backup_b2_access_key_id
  backup_secret_access_key = var.backup_b2_secret_access_key
  backup_prefix            = local.cnpg.backup_prefix
  backup_retention         = local.cnpg.backup_retention
  backup_schedule          = local.cnpg.backup_schedule

  # Only from a running single server: with `engine = cnpg` there is none,
  # and its name is this cluster itself.
  sync = local.postgres_on && local.postgres_engine == "single" ? {
    source_host   = module.postgres.host
    source_secret = module.postgres.superuser_secret_name
    run           = local.cnpg.sync_run
    mode          = local.cnpg.sync_mode
  } : null
}
