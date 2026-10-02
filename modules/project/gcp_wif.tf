# ── GCP Workload Identity Federation — per-component credential-config ConfigMap
#
# When a component yaml has `gcp_wif.gcp_service_account: <email>`,
# the engine emits a ConfigMap whose `credential-config.json` is the
# GCP SDK `external_account` shape. The Pod mounts it at
# `/var/run/secrets/gcp/creds/credential-config.json` (handled in
# `modules/component`) and the SDK reads `GOOGLE_APPLICATION_CREDENTIALS`
# = that path, auto-exchanges the projected k8s SA token at GCP STS,
# impersonates the GCP SA, and starts calling GCP APIs.
#
# The audience (full WIF pool provider path) is operator-supplied
# cluster-wide via `services.gcp_wif.pool_provider_audience`. Only
# the GCP SA email varies per-component.
#
# GCP-side principalSet binding (which k8s SA may impersonate which
# GCP SA) is NOT engine-managed — it lives in whichever Terraform
# stack owns the GCP project IAM.
resource "kubernetes_config_map_v1" "gcp_wif_credential_config" {
  for_each = local.gcp_wif_components

  metadata {
    name      = "${each.key}-gcp-wif-credential-config"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    "credential-config.json" = jsonencode({
      type                              = "external_account"
      audience                          = var.gcp_wif_pool_provider_audience
      subject_token_type                = "urn:ietf:params:oauth:token-type:jwt"
      token_url                         = "https://sts.googleapis.com/v1/token"
      service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${each.value}:generateAccessToken"
      credential_source = {
        file = "/var/run/secrets/gcp/tokens/token"
        format = {
          type = "text"
        }
      }
    })
  }
}

# ── GCP WIF — standalone SA + credential-config for chart-managed workloads ────
#
# Same external_account ConfigMap as the per-component knob above, but
# decoupled from any engine-owned Pod. Declared via
# `envs.<env>.gcp_wif_service_accounts:` for workloads the engine does
# NOT render (Argo CD helm charts). Engine emits the bare ServiceAccount
# the GCP-side principalSet binding authorizes, plus the credential-config
# ConfigMap; the chart sets `serviceAccountName`, renders the projected
# SA-token volume, and mounts the ConfigMap itself.
resource "kubernetes_service_account_v1" "gcp_wif_standalone" {
  for_each = local.gcp_wif_service_accounts

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }
}

resource "kubernetes_config_map_v1" "gcp_wif_standalone_credential_config" {
  for_each = local.gcp_wif_service_accounts

  metadata {
    name      = "${each.key}-gcp-wif-credential-config"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    "credential-config.json" = jsonencode({
      type                              = "external_account"
      audience                          = var.gcp_wif_pool_provider_audience
      subject_token_type                = "urn:ietf:params:oauth:token-type:jwt"
      token_url                         = "https://sts.googleapis.com/v1/token"
      service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${each.value}:generateAccessToken"
      credential_source = {
        file = "/var/run/secrets/gcp/tokens/token"
        format = {
          type = "text"
        }
      }
    })
  }
}
