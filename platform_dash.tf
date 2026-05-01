# Platform operator dashboard — root wiring.
#
# Mirrors the infisical/mail/oauth2-proxy pattern:
#   - Module owns Deployment / Service / RBAC in `platform` ns
#   - `config/components/platform-dash.yaml` (kind: external) wires
#     the hostname into the project + cloudflared pipeline
#   - Domain yaml routes `<sub>: platform-dash` (e.g.
#     `dash: platform-dash`) to that external component
#
# What this file owns:
#   - check blocks (zitadel + hostname required)
#   - zitadel-app instance for OIDC (creates Project + Application,
#     emits AUTH_ZITADEL_* + AUTH_SECRET in a Secret in platform ns)
#   - module.platform_dash invocation, fed the OIDC Secret name +
#     checksum so Deployment env_from picks it up

check "platform_dash_requires_zitadel" {
  assert {
    condition     = !local.platform.services.platform_dash.enabled || local.platform.services.zitadel.enabled
    error_message = "services.platform_dash.enabled = true requires services.zitadel.enabled = true (dashboard authentication is OIDC-only)."
  }
}

check "platform_dash_hostname_set" {
  assert {
    condition     = !local.platform.services.platform_dash.enabled || local.platform.services.platform_dash.hostname != ""
    error_message = "services.platform_dash.hostname must be set when platform_dash is enabled (e.g. `dash.example.com`). Drives ORIGIN + AUTH_URL + the Zitadel redirect URI registration."
  }
}

# OIDC integration. Emits a Secret in `platform` ns with
# AUTH_ZITADEL_ISSUER / AUTH_ZITADEL_ID / AUTH_ZITADEL_SECRET /
# AUTH_SECRET — the module's Deployment mounts it via env_from.
module "platform_dash_oidc" {
  source     = "./modules/zitadel-app"
  count      = local.platform.services.platform_dash.enabled && local.platform.services.zitadel.enabled ? 1 : 0
  depends_on = [module.zitadel, kubernetes_namespace_v1.platform]

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  project_name = "platform-dash"
  app_name     = "platform-dash"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  redirect_uris    = ["https://${local.platform.services.platform_dash.hostname}/auth/callback/zitadel"]
  post_logout_uris = ["https://${local.platform.services.platform_dash.hostname}/"]

  secret_name      = "platform-dash-oidc"
  secret_namespace = kubernetes_namespace_v1.platform.metadata[0].name

  # Role keys mirror what the dashboard's authz code checks for —
  # global admin/sre + per-cluster overrides. Add cluster_<name>_*
  # entries as more clusters land in DASH_CLUSTERS_JSON.
  roles = [
    { key = "platform_admin", display_name = "Platform Admin" },
    { key = "platform_sre", display_name = "Platform SRE" },
    { key = "user", display_name = "User" },
    { key = "cluster_local_admin", display_name = "Cluster local Admin" },
    { key = "cluster_local_sre", display_name = "Cluster local SRE" }
  ]
}

module "platform_dash" {
  source     = "./modules/platform-dash"
  depends_on = [module.platform_dash_oidc]

  enabled              = local.platform.services.platform_dash.enabled
  namespace            = kubernetes_namespace_v1.platform.metadata[0].name
  image                = local.platform.services.platform_dash.image
  replicas             = local.platform.services.platform_dash.replicas
  resources            = local.platform.services.platform_dash.resources
  hostname             = local.platform.services.platform_dash.hostname
  oidc_secret_name     = try(module.platform_dash_oidc[0].secret_name, "platform-dash-oidc")
  oidc_secret_checksum = try(module.platform_dash_oidc[0].secret_checksum, "no-oidc")
}

output "platform_dash_url" {
  description = "Public dashboard URL. Null when disabled."
  value       = local.platform.services.platform_dash.enabled ? "https://${local.platform.services.platform_dash.hostname}" : null
}
