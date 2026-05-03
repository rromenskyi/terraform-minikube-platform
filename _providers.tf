# Cloudflare provider reads `CLOUDFLARE_API_TOKEN` from the process
# environment when `api_token` is not set explicitly. The `./tf`
# wrapper exports the value under both the native name and
# `TF_VAR_cloudflare_api_token`; passing it via a `variable` block
# would just round-trip the same value and pin a copy of the token
# into Terraform state.
provider "cloudflare" {}

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
  # v3 schema: `kubernetes` is a nested attribute (`= {}`), not a
  # block. Same `config_path` semantics flow through.
  kubernetes = {
    config_path = module.k8s.kubeconfig_path
  }
}
