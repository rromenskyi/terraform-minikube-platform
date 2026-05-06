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
  source = "./modules/zitadel-app"
  count  = local.platform.services.platform_dash.enabled && local.platform.services.zitadel.enabled ? 1 : 0
  # `depends_on = [module.zitadel]` is intentionally absent. With
  # `org_id` flowing in from `data.zitadel_orgs.platform_org` at root
  # the module no longer queries Zitadel itself, so the module-level
  # depends_on that previously deferred its data sources to apply-time
  # (and cascaded "must be replaced" onto every downstream resource on
  # any plan that touched module.zitadel) is no longer needed.
  depends_on = [kubernetes_namespace_v1.platform]

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org[0].ids[0] : ""
  project_name = "platform-dash"
  app_name     = "platform-dash"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  redirect_uris    = ["https://${local.platform.services.platform_dash.hostname}/auth/callback/zitadel"]
  post_logout_uris = ["https://${local.platform.services.platform_dash.hostname}/"]

  secret_name      = "platform-dash-oidc"
  secret_namespace = kubernetes_namespace_v1.platform.metadata[0].name

  # Role keys mirror what the dashboard's authz code checks for —
  # global admin/sre + per-cluster overrides + per-tenant-namespace
  # delegations. Add cluster_<name>_* entries as more clusters land
  # in DASH_CLUSTERS_JSON. Add namespace_phost-<slug>-<env>_*
  # entries as more tenant namespaces become delegable. System
  # namespaces (`platform`, `mail`, `ops`, `monitoring`,
  # `ingress-controller`) are intentionally NOT delegable — they
  # hold shared platform infra (Vault, Postgres, MySQL, Redis,
  # Zitadel, Stalwart, Roundcube, cloudflared, Traefik). Only
  # `phost-<slug>-<env>` tenant namespaces are listed here.
  roles = [
    { key = "platform_admin", display_name = "Platform Admin" },
    { key = "platform_sre", display_name = "Platform SRE" },
    { key = "user", display_name = "User" },
    { key = "cluster_local_admin", display_name = "Cluster local Admin" },
    { key = "cluster_local_sre", display_name = "Cluster local SRE" },
    { key = "namespace_phost-ipsupport-us-dev_admin", display_name = "Namespace phost-ipsupport-us-dev Admin" },
    { key = "namespace_phost-ipsupport-us-dev_sre", display_name = "Namespace phost-ipsupport-us-dev SRE" },
    { key = "namespace_phost-ipsupport-us-prod_admin", display_name = "Namespace phost-ipsupport-us-prod Admin" },
    { key = "namespace_phost-ipsupport-us-prod_sre", display_name = "Namespace phost-ipsupport-us-prod SRE" },
    { key = "namespace_phost-jagdterrier-club-prod_admin", display_name = "Namespace phost-jagdterrier-club-prod Admin" },
    { key = "namespace_phost-jagdterrier-club-prod_sre", display_name = "Namespace phost-jagdterrier-club-prod SRE" },
    { key = "namespace_phost-paseka-co-dev_admin", display_name = "Namespace phost-paseka-co-dev Admin" },
    { key = "namespace_phost-paseka-co-dev_sre", display_name = "Namespace phost-paseka-co-dev SRE" },
    { key = "namespace_phost-paseka-co-prod_admin", display_name = "Namespace phost-paseka-co-prod Admin" },
    { key = "namespace_phost-paseka-co-prod_sre", display_name = "Namespace phost-paseka-co-prod SRE" },
    { key = "namespace_phost-priroda-kharkov-ua-prod_admin", display_name = "Namespace phost-priroda-kharkov-ua-prod Admin" },
    { key = "namespace_phost-priroda-kharkov-ua-prod_sre", display_name = "Namespace phost-priroda-kharkov-ua-prod SRE" }
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

  node_selector = local.platform.services.platform_dash.node_selector
  tolerations   = local.platform.services.platform_dash.tolerations
}

output "platform_dash_url" {
  description = "Public dashboard URL. Null when disabled."
  value       = local.platform.services.platform_dash.enabled ? "https://${local.platform.services.platform_dash.hostname}" : null
}
