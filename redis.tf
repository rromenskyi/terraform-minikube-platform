# Shared Redis instance for all projects.
# Per-namespace ACL user + key prefix provisioned inside modules/project.
#
# Toggle via `services.redis` in `config/platform.yaml`. Deployed into
# the shared `platform` namespace owned by root-level `platform.tf`.
module "redis" {
  source     = "./modules/redis"
  depends_on = [module.addons]

  enabled          = local.platform.services.redis.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path
  storage_class    = local.platform.services.redis.storage_class

  node_selector = local.platform.services.redis.node_selector
  tolerations   = local.platform.services.redis.tolerations
}
