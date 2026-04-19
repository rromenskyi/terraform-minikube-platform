# Shared PostgreSQL instance for all projects.
# Per-namespace database + user provisioned inside modules/project.
#
# Lives in the root-owned `platform` namespace (see platform.tf) along
# with MySQL / Redis / Ollama. Toggle via `services.postgres.enabled`
# in `config/platform.yaml`.
module "postgres" {
  source     = "./modules/postgres"
  depends_on = [module.addons]

  enabled          = local.platform.services.postgres.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path
}
