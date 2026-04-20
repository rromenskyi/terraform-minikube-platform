# `terraform { required_version }` and provider pins live in `_versions.tf`;
# the backend block lives in `_backend.tf`. This file is composition only.

# =============================================================================
# Three-layer stack
# =============================================================================
#
# Layer 1 — module "k8s"    (cluster bootstrap)
#   Picks ONE of:
#     `terraform-minikube-k8s` — local minikube via the minikube provider
#     `terraform-k3s-k8s`      — native k3s over SSH
#   Both export an identical signature (cluster_host, *_certificate,
#   cluster_ca_certificate, kubeconfig_path, cluster_name,
#   cluster_distribution) so everything above is distribution-agnostic.
#
# Layer 2 — module "addons"  (platform services)
#   `terraform-k8s-addons` — Traefik, cert-manager + Let's Encrypt,
#   kube-prometheus-stack (Grafana), PodSecurity-labeled namespaces with
#   default ResourceQuota/LimitRange, optional ops StatefulSet. Consumes
#   the Layer-1 kubeconfig_path via `config_path`.
#
# Layer 3 — module "mysql", module "project"  (tenant workloads)
#   Shared MySQL plus the per-domain project modules. They need
#   namespaces/ingress/cert issuers from Layer 2, so they depend_on
#   module.addons.

# -----------------------------------------------------------------------------
# Layer 1: Cluster distribution — pick ONE (the other stays commented out).
# -----------------------------------------------------------------------------

# --- Option A: minikube ------------------------------------------------------
# module "k8s" {
#   source = "git::https://github.com/rromenskyi/terraform-minikube-k8s.git?ref=v3.0.0"
#
#   cluster_name       = var.cluster_name
#   kubernetes_version = var.kubernetes_version
#   memory             = var.memory
#
#   # Keep Pod and Service ranges in separate CGNAT slices so neither collides
#   # with the host LAN nor with each other.
#   pod_cidr     = var.pod_cidr
#   service_cidr = "100.64.0.0/12"
#   dns_ip       = "100.64.0.10"
#   cni          = "flannel"
# }

# --- Option B: k3s -----------------------------------------------------------
module "k8s" {
  source = "git::https://github.com/rromenskyi/terraform-k3s-k8s.git?ref=v0.3.1"

  cluster_name = var.cluster_name

  # Leave kubernetes_version unset to pull the default k3s channel ("stable"),
  # or pin a specific build like "v1.31.4+k3s1". The minikube-style "stable"
  # string is not a valid k3s version.
  # kubernetes_version = "v1.31.4+k3s1"

  ssh_host             = var.ssh_host
  ssh_port             = var.ssh_port
  ssh_user             = var.ssh_user
  ssh_private_key_path = var.ssh_private_key_path
}

# Fail fast at plan time if the operator forgot to set ssh_user /
# ssh_private_key_path when the k3s distribution is active. Module blocks do
# not accept `lifecycle { precondition }` in current Terraform, so a `check`
# block is used. When the minikube distribution is active instead, the k3s
# SSH vars are unused — the check still runs but is harmless informational
# noise.
check "k3s_ssh_vars_set" {
  assert {
    condition     = var.ssh_user != "" && var.ssh_private_key_path != ""
    error_message = "ssh_user and ssh_private_key_path are required when the k3s distribution is active (set TF_VAR_ssh_user and TF_VAR_ssh_private_key_path, see .env.example)."
  }

  assert {
    condition     = var.ssh_private_key_path == "" || fileexists(var.ssh_private_key_path)
    error_message = "ssh_private_key_path does not point to a readable file: ${var.ssh_private_key_path}"
  }
}

# -----------------------------------------------------------------------------
# Layer 2: Platform add-ons (Traefik, cert-manager, monitoring, namespaces).
# -----------------------------------------------------------------------------
module "addons" {
  source = "git::https://github.com/rromenskyi/terraform-k8s-addons.git?ref=v1.1.2"

  kubeconfig_path      = module.k8s.kubeconfig_path
  cluster_name         = module.k8s.cluster_name
  cluster_distribution = module.k8s.cluster_distribution

  letsencrypt_email = var.letsencrypt_email

  enable_traefik      = true
  enable_cert_manager = true
  enable_monitoring   = true
  enable_ops_workload = true

  # Traefik's chart-side dashboard IngressRoute at `traefik.<base_domain>`
  # stays off — this platform owns dashboard routing through the tenant
  # YAML layer (see `config/components/traefik.yaml`), so leaving the
  # chart-side one on would create two IRs serving the dashboard at
  # different hostnames with different auth.
  enable_traefik_dashboard = false
}

# =============================================================================
# Layer 3: Projects — one entry per domain × env combination.
# =============================================================================
module "project" {
  for_each = local.projects

  source     = "./modules/project"
  depends_on = [module.addons, kubernetes_namespace_v1.platform, module.mysql, module.postgres, module.redis, module.ollama]

  project_config   = each.value
  components       = local.components
  default_limits   = local.default_limits
  volume_base_path = var.host_volume_path

  # Shared-service endpoints. Each module's outputs collapse to null
  # when its own `enabled` flag is off, so the preconditions in
  # modules/project can reject any component that asks for a disabled
  # service with a clear error rather than a silent mis-deploy.
  mysql_namespace           = module.mysql.namespace
  mysql_host                = module.mysql.host
  postgres_namespace        = module.postgres.namespace
  postgres_host             = module.postgres.host
  postgres_superuser_secret = module.postgres.superuser_secret_name
  redis_namespace           = module.redis.namespace
  redis_host                = module.redis.host
  redis_default_secret      = module.redis.default_secret_name
  ollama_url                = module.ollama.url
}
