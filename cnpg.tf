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

  # The in-cluster host clients reach the primary at (the shared Service).
  cnpg_client_host = "${local.platform.services.postgres.service_name}.${kubernetes_namespace_v1.platform.metadata[0].name}.svc.cluster.local"

  # Managed roles with their generated passwords, for the module.
  cnpg_managed_roles = [for r in local.cnpg.managed_roles : {
    name             = r.name
    password         = random_password.cnpg_role[r.name].result
    login            = try(r.login, true)
    createdb         = try(r.createdb, false)
    createrole       = try(r.createrole, false)
    connection_limit = try(r.connection_limit, -1)
  }]

  # Roles that deliver their connection URL to a namespace as a Secret, so the
  # consuming app (e.g. a portal that creates its own databases) reads it as
  # env. Points at the writable primary Service, never a read-only replica.
  cnpg_role_url_secrets = {
    for r in local.cnpg.managed_roles : r.name => {
      namespace = r.url_secret.namespace
      name      = r.url_secret.name
      key       = r.url_secret.key
      url       = "postgres://${r.name}:${random_password.cnpg_role[r.name].result}@${local.cnpg_client_host}:5432/${try(r.url_secret.database, "postgres")}"
    } if try(r.url_secret, null) != null
  }
}

# One password per managed role, used for the role and any delivered URL.
resource "random_password" "cnpg_role" {
  for_each = local.cnpg.enabled ? { for r in local.cnpg.managed_roles : r.name => r } : {}
  length   = 32
  special  = false
}

# Deliver a managed role's connection URL into the consuming namespace. The
# namespace is created by module.project, so wait for it.
resource "kubernetes_secret_v1" "cnpg_role_url" {
  for_each   = local.cnpg.enabled ? local.cnpg_role_url_secrets : {}
  depends_on = [module.project]

  metadata {
    name      = each.value.name
    namespace = each.value.namespace
  }
  type = "Opaque"
  data = { (each.value.key) = each.value.url }
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

  # A second cluster (e.g. at another site) following this one, and which of
  # the two takes writes; changing `primary_cluster` is a failover.
  replica_cluster = local.cnpg.replica_cluster
  primary_cluster = local.cnpg.primary_cluster

  # Declarative roles on the primary (passwords generated above).
  managed_roles = local.cnpg_managed_roles

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
