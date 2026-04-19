# Shared MySQL instance for all projects.
# DB + user per project env are provisioned inside modules/project.
#
# Depends on module.addons (not just module.k8s) so this layer lands only
# after all addon namespaces (cert-manager, ingress-controller, monitoring,
# ops) are in place. The MySQL namespace (`platform`) is owned by this
# module and deliberately NOT prefixed with `var.namespace_prefix` — the
# prefix is for tenant-project namespaces (`phost-<slug>-<env>`), whereas
# platform infra namespaces keep fixed short names.
module "mysql" {
  source     = "./modules/mysql"
  depends_on = [module.addons]

  volume_base_path = var.host_volume_path
}
