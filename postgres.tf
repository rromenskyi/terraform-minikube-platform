# Shared PostgreSQL for all projects, from one of two engines picked by
# `services.postgres.engine` in the gitignored `config/platform.yaml`:
#
#   single — one server, hostPath data on one node (modules/postgres);
#   cnpg   — a CloudNativePG cluster: replicas on other nodes, failover,
#            continuous backups (modules/cnpg, configured in cnpg.tf).
#
# Whichever engine serves clients owns the Service `services.postgres.
# service_name` and the superuser Secret, so clients connect to the same
# host with the same credentials either way. Everything outside this file
# reads `local.postgres`, never a module directly.
#
# The superuser password lives here, not in a module, so it outlives a
# change of engine.
#
# Changing `engine` on a running cluster moves the Service and the Secret to
# another module: copy the data first (cnpg `sync`), then move those two
# objects and this password in the state with `terraform state mv` before
# applying, so they are updated in place instead of deleted and recreated.

locals {
  postgres_engine = local.platform.services.postgres.engine
  postgres_on     = local.platform.services.postgres.enabled

  # Connection facts for every client, whichever engine is behind them.
  postgres = local.postgres_engine == "cnpg" ? {
    host                  = module.cnpg.host
    port                  = module.cnpg.port
    namespace             = module.cnpg.namespace
    service_name          = local.postgres_on ? local.platform.services.postgres.service_name : null
    superuser_secret_name = module.cnpg.superuser_secret_name
    superuser_password    = one([for p in random_password.postgres_superuser : p.result])
    } : {
    host                  = module.postgres.host
    port                  = module.postgres.port
    namespace             = module.postgres.namespace
    service_name          = module.postgres.service_name
    superuser_secret_name = module.postgres.superuser_secret_name
    superuser_password    = module.postgres.superuser_password
  }
}

resource "terraform_data" "postgres_engine" {
  lifecycle {
    precondition {
      condition     = contains(["single", "cnpg"], local.postgres_engine)
      error_message = "services.postgres.engine must be `single` or `cnpg`."
    }
    precondition {
      condition     = !(local.postgres_on && local.postgres_engine == "cnpg") || local.platform.services.cnpg.enabled
      error_message = "services.postgres.engine = cnpg needs services.cnpg.enabled = true."
    }
  }
}

resource "random_password" "postgres_superuser" {
  for_each = local.postgres_on || local.platform.services.cnpg.enabled ? toset(["enabled"]) : toset([])

  length  = 32
  special = false
}

module "postgres" {
  source     = "./modules/postgres"
  depends_on = [module.addons]

  context          = module.platform_label.context
  enabled          = local.postgres_on && local.postgres_engine == "single"
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path

  service_name       = local.platform.services.postgres.service_name
  superuser_password = one([for p in random_password.postgres_superuser : p.result])

  node_selector = local.platform.services.postgres.node_selector
  tolerations   = local.platform.services.postgres.tolerations
}
