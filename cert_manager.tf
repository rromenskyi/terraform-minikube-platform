# cert-manager-side resources owned by the platform root (cert-manager
# itself + ClusterIssuers ship from `module.addons`). Currently just one
# concern: the Cloudflare API token Secret consumed by the LE
# ClusterIssuers' DNS-01 ACME solver.
#
# The token value comes from `var.cloudflare_api_token` (operator's
# `TF_VAR_cloudflare_api_token` from `.env` — same value the Cloudflare
# provider already uses for tunnel + DNS records). Engine does not
# generate the token; operator provisions it once in CF dashboard.

check "dns01_cloudflare_token_present" {
  assert {
    condition     = !local.platform.services.dns01_cloudflare.enabled || var.cloudflare_api_token != ""
    error_message = "services.dns01_cloudflare.enabled = true requires TF_VAR_cloudflare_api_token in operator's .env (same token the cloudflare provider uses for tunnel + DNS records). Empty token would emit a Secret with empty data — DNS-01 challenges would fail at ACME time with `forbidden` from the CF API."
  }
}

check "dns01_cloudflare_zones_present" {
  assert {
    condition     = !local.platform.services.dns01_cloudflare.enabled || length(local.platform.services.dns01_cloudflare.dns_zones) > 0
    error_message = "services.dns01_cloudflare.enabled = true requires services.dns01_cloudflare.dns_zones non-empty (e.g. `[ipsupport.us]`). Without zones, the dns01 solver renders but cert-manager has nothing to match Certificates against — every DNS-01 challenge would fall through to HTTP-01 (defeating the point of enabling dns01)."
  }
}

resource "kubernetes_secret_v1" "cloudflare_acme_token" {
  for_each = local.platform.services.dns01_cloudflare.enabled ? toset(["enabled"]) : toset([])

  depends_on = [module.addons]

  metadata {
    name      = "cloudflare-acme-token"
    namespace = "cert-manager"
    labels    = module.platform_label.tags
  }

  data = {
    # Key name `api-token` matches the addons chart's hardcoded
    # `apiTokenSecretRef.key`. Don't rename without bumping the chart.
    api-token = var.cloudflare_api_token
  }
}
