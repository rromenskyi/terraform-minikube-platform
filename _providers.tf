# Cloudflare provider reads `CLOUDFLARE_API_TOKEN` from the process
# environment when `api_token` is not set explicitly. The `./tf`
# wrapper exports the value under both the native name and
# `TF_VAR_cloudflare_api_token`; passing it via a `variable` block
# would just round-trip the same value and pin a copy of the token
# into Terraform state.
provider "cloudflare" {}

# The kubeconfig written by the cluster stack (`cluster/`), or one passed
# through TF_VAR_kubeconfig_path / TF_VAR_kube_context (CI). `config_path`
# is opened lazily, only when a resource makes an API call.
provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kube_context
}

provider "kubectl" {
  config_path      = local.kubeconfig_path
  config_context   = local.kube_context
  load_config_file = true
}

provider "helm" {
  # v3 schema: `kubernetes` is a nested attribute (`= {}`), not a
  # block. Same `config_path` semantics flow through.
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = local.kube_context
  }
}
