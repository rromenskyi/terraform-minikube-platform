# Shared MySQL instance for all projects.
# DB + user per project env are provisioned inside modules/project.
module "mysql" {
  source     = "./modules/mysql"
  depends_on = [module.k8s]

  namespace_prefix = var.namespace_prefix
  volume_base_path = local.minikube_volume_path
}
