# `terraform { required_version }` and provider pins live in `_versions.tf`;
# the S3 backend block lives in `_backend.tf`. This file is composition only.

# =============================================================================
# Cluster distribution — pick ONE
# =============================================================================
#
# This platform runs on top of a local Kubernetes cluster provisioned by one of
# two sibling modules. They are drop-in replacements because they export the
# same output signature (cluster_host, client_certificate, client_key,
# cluster_ca_certificate, grafana_credentials, …). Everything below this block
# (providers, Cloudflare tunnel, project modules) is cluster-agnostic.
#
# Switching distribution = comment one block, uncomment the other.
#
# -----------------------------------------------------------------------------
# Option A — minikube (default)
# -----------------------------------------------------------------------------
#   Requires: docker + minikube CLI on PATH.
#   The scott-the-programmer/minikube Terraform provider creates the cluster
#   synchronously inside a single `terraform apply`.
#
# -----------------------------------------------------------------------------
# Option B — k3s (native, via SSH)
# -----------------------------------------------------------------------------
#   Requires: SSH daemon reachable at ssh_host:ssh_port and a user with
#   passwordless sudo on the target host (127.0.0.1 for a local install).
#   A single `terraform apply` is enough: the root `kubernetes` and `helm`
#   providers wire themselves through `config_path = module.platform.kubeconfig_path`
#   (see `_providers.tf`), which is opened lazily at resource-apply time —
#   by then `null_resource.k3s_install` has already written the kubeconfig.
# -----------------------------------------------------------------------------

# --- Option A: minikube ------------------------------------------------------
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

# --- Option B: k3s -----------------------------------------------------------
# module "platform" {
#   source = "../terraform-k3s-k8s"
#
#   cluster_name      = var.cluster_name
#   letsencrypt_email = var.letsencrypt_email
#
#   # Leave kubernetes_version unset to pull the default k3s channel ("stable"),
#   # or pin a specific build like "v1.31.4+k3s1". The minikube-style "stable"
#   # string is not a valid k3s version.
#   # kubernetes_version = "v1.31.4+k3s1"
#
#   ssh_host             = var.ssh_host
#   ssh_port             = var.ssh_port
#   ssh_user             = var.ssh_user
#   ssh_private_key_path = var.ssh_private_key_path
#
#   enable_traefik           = true
#   enable_traefik_dashboard = true
#   enable_cert_manager      = true
#   enable_monitoring        = true
#   create_ops_workload      = true
#
#   # Fail fast at plan time instead of deep inside the child module's SSH
#   # provisioner if the operator forgot to set ssh_user / ssh_private_key_path
#   # (empty-string defaults make them optional for the minikube path).
#   lifecycle {
#     precondition {
#       condition     = var.ssh_user != "" && var.ssh_private_key_path != ""
#       error_message = "ssh_user and ssh_private_key_path are required when the k3s distribution is active (set TF_VAR_ssh_user and TF_VAR_ssh_private_key_path, see .env.example)."
#     }
#
#     precondition {
#       condition     = fileexists(var.ssh_private_key_path)
#       error_message = "ssh_private_key_path does not point to a readable file: ${var.ssh_private_key_path}"
#     }
#   }
# }

# =============================================================================
# Projects — one YAML file per domain, cluster-agnostic from here down.
# =============================================================================
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
