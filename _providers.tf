provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Consume the kubeconfig emitted by the chosen cluster module. Both sibling
# modules (`terraform-minikube-k8s` and `terraform-k3s-k8s`) export a
# `kubeconfig_path` output as a static, plan-time-known string. `config_path`
# is opened lazily — only when a resource actually makes an API call — so the
# file does not have to exist at plan time, which removes the two-phase
# `-target` bootstrap that inline host/cert attributes would otherwise force
# on the k3s distribution.
provider "kubernetes" {
  config_path = module.k8s.kubeconfig_path
}

provider "kubectl" {
  config_path      = module.k8s.kubeconfig_path
  load_config_file = true
}

provider "helm" {
  kubernetes {
    config_path = module.k8s.kubeconfig_path
  }
}
