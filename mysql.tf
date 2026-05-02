# Shared MySQL instance for all projects.
# DB + user per project env are provisioned inside modules/project.
#
# Lives in the root-owned `platform` namespace (see platform.tf) along
# with Postgres / Redis / Ollama. Toggle via `services.mysql.enabled`
# in `config/platform.yaml`; when off, the module produces no resources.
module "mysql" {
  source     = "./modules/mysql"
  depends_on = [module.addons]

  enabled          = local.platform.services.mysql.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path

  node_selector = local.platform.services.mysql.node_selector
  tolerations   = local.platform.services.mysql.tolerations
}
