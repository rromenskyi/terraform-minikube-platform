terraform {
  required_version = ">= 1.5.0"
}

# Core platform (external module repo; local development uses the sibling checkout)
module "platform" {
  source = "../terraform-minikube-k8s"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  letsencrypt_email  = var.letsencrypt_email

  enable_traefik           = true
  enable_traefik_dashboard = true
  enable_cert_manager      = true
  enable_monitoring        = true
  create_ops_workload      = true
}

# Projects (one domain = one project)
module "project" {
  for_each = local.projects

  source     = "./modules/project"
  depends_on = [module.platform]

  project_config = each.value
  components     = local.components
  default_limits = local.default_limits
}

output "projects" {
  value = {
    for k, v in module.project : k => v.namespace
  }
}

output "grafana_credentials" {
  value     = module.platform.grafana_credentials
  sensitive = true
}
