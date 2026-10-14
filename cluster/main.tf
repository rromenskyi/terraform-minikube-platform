# Cluster stack: brings the Kubernetes cluster up and writes its admin
# kubeconfig. Everything inside the cluster lives in the platform stack (the
# repository root), which only needs that kubeconfig (`kubeconfig_path`).
#
# Run it through the wrapper: `./tf cluster <terraform args>`. It needs SSH to
# the k3s host (Option B) or the local docker daemon (Option A), so it never
# runs in CI.
#
# Pick ONE distribution (the other stays commented out). Both modules export
# the same outputs (kubeconfig_path, cluster_name, cluster_distribution).

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

# Fail the plan when the k3s SSH inputs are missing. Module blocks take no
# `lifecycle { precondition }`, so a terraform_data carries it. It belongs to
# the k3s module above: comment both out when switching to minikube.
resource "terraform_data" "k3s_checks" {
  lifecycle {
    precondition {
      condition     = var.ssh_user != "" && var.ssh_private_key_path != ""
      error_message = "ssh_user and ssh_private_key_path are required when the k3s distribution is active (set TF_VAR_ssh_user and TF_VAR_ssh_private_key_path, see .env.example)."
    }

    precondition {
      condition     = var.ssh_private_key_path == "" || fileexists(var.ssh_private_key_path)
      error_message = "ssh_private_key_path does not point to a readable file: ${var.ssh_private_key_path}"
    }
  }
}
