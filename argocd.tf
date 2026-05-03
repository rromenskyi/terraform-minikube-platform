# Argo CD — root wiring.
#
# Mirrors the platform-dash / vault pattern:
#   - `module "argocd_oidc"` creates the Zitadel project + OIDC
#     application + role list, emits a Secret with AUTH_ZITADEL_*
#     env names. The chart consumes only `client_id` /
#     `client_secret` from it, but the Secret stays a
#     consistent shape across kind:app components.
#   - `module "argocd"` deploys the chart with OIDC values.
#   - `config/components/argocd.yaml` (kind: external) wires the
#     hostname into the project + cloudflared pipeline.
#   - Domain yaml routes `argocd: argocd` (or whatever sub the
#     operator picks) to that external component.

check "argocd_requires_zitadel" {
  assert {
    condition     = !local.platform.services.argocd.enabled || local.platform.services.zitadel.enabled
    error_message = "services.argocd.enabled = true requires services.zitadel.enabled = true (Argo CD authentication is OIDC-only in this stack — local admin is intentionally not exposed publicly)."
  }
}

check "argocd_hostname_set" {
  assert {
    condition     = !local.platform.services.argocd.enabled || local.platform.services.argocd.hostname != ""
    error_message = "services.argocd.hostname must be set when argocd is enabled (e.g. `argocd.example.com`). Drives `server.config.url` and the OIDC redirect URI registration in Zitadel."
  }
}

# Root-owned namespace so the OIDC Secret (created by
# `module.argocd_oidc`) lands BEFORE the chart's `create_namespace`
# step would have run. The chart's `create_namespace = false` below
# expects the namespace to already exist.
resource "kubernetes_namespace_v1" "argocd" {
  count = local.platform.services.argocd.enabled ? 1 : 0

  metadata {
    name = local.platform.services.argocd.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# OIDC integration. Emits a Secret in `argocd` ns with AUTH_ZITADEL_*
# (consistent with other kind:app modules); the chart values
# downstream only consume `client_id` / `client_secret` directly.
module "argocd_oidc" {
  source     = "./modules/zitadel-app"
  count      = local.platform.services.argocd.enabled && local.platform.services.zitadel.enabled ? 1 : 0
  depends_on = [kubernetes_namespace_v1.argocd]
  # No `depends_on = [module.zitadel]` — the org_id input below is
  # resolved at root via `data.zitadel_orgs.platform_org`, so the
  # cascade-defer trap (see comment on
  # `zitadel_default_login_policy.main` in zitadel.tf) does not
  # apply here.

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org[0].ids[0] : ""
  project_name = "argocd"
  app_name     = "argocd"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  # Argo CD's Dex OIDC connector posts back to
  # `<server.config.url>/auth/callback`. The CLI uses
  # `<url>/api/dex/callback` for `argocd login --sso`.
  redirect_uris = [
    "https://${local.platform.services.argocd.hostname}/auth/callback",
    "https://${local.platform.services.argocd.hostname}/api/dex/callback",
  ]
  post_logout_uris = ["https://${local.platform.services.argocd.hostname}/"]

  secret_name      = "argocd-oidc"
  secret_namespace = local.platform.services.argocd.namespace

  # Roles the operator's workforce can hold. `argocd_admin` maps to
  # Argo CD's built-in `role:admin` policy via the chart values. All
  # other roles are role-keys the operator can hand-grant in Argo
  # CD's RBAC ConfigMap later.
  roles = [
    { key = "argocd_admin", display_name = "Argo CD Admin" },
    { key = "user", display_name = "User" },
  ]
}

module "argocd" {
  source     = "./modules/argocd"
  depends_on = [module.argocd_oidc, module.addons]

  enabled  = local.platform.services.argocd.enabled
  hostname = local.platform.services.argocd.hostname

  oidc_issuer        = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  oidc_client_id     = try(module.argocd_oidc[0].client_id, "")
  oidc_client_secret = try(module.argocd_oidc[0].client_secret, "")
  oidc_admin_groups  = ["argocd_admin"]

  node_selector = local.platform.services.argocd.node_selector
  tolerations   = local.platform.services.argocd.tolerations
}

output "argocd_url" {
  description = "Public Argo CD URL. Null when disabled."
  value       = local.platform.services.argocd.enabled ? "https://${local.platform.services.argocd.hostname}" : null
}
