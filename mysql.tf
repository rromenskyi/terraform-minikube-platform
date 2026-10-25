# Shared MySQL instance for all projects.
# DB + user per project env are provisioned inside modules/project.
#
# Lives in the root-owned `platform` namespace (see platform.tf) along
# with Postgres / Redis / Ollama. Toggle via `services.mysql.enabled`
# in `config/platform.yaml`; when off, the module produces no resources.
module "mysql" {
  source     = "./modules/mysql"
  depends_on = [module.addons]

  context          = module.platform_label.context
  enabled          = local.platform.services.mysql.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path

  storage_class     = local.platform.services.mysql.storage_class
  storage_seed_node = local.platform.services.mysql.storage_seed_node
  volume_node_label = lookup(module.piraeus.volume_node_labels, local.platform.services.mysql.storage_class, "")

  node_selector           = local.platform.services.mysql.node_selector
  preferred_node_affinity = local.node_pool_preference["mysql"]
  tolerations             = local.platform.services.mysql.tolerations
  resources               = local.platform.services.mysql.resources
}
