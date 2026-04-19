# Shared MySQL instance for all projects.
# DB + user per project env are provisioned inside modules/project.
#
# Depends on module.addons (not just module.k8s) so the MySQL namespace lands
# AFTER the addons module has created its namespaces — MySQL itself is deployed
# into `{prefix}platform`, which it creates, but the tenant namespaces that
# modules/project reference need to exist first.
module "mysql" {
  source     = "./modules/mysql"
  depends_on = [module.addons]

  namespace_prefix = var.namespace_prefix
  volume_base_path = var.host_volume_path
}
