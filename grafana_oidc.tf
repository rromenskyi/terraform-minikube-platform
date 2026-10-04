# Grafana single sign-on through Zitadel.
#
# Grafana's own `generic_oauth` provider, not the forward-auth gate: Grafana
# then knows who the user is and maps Zitadel roles to its own roles. Enabled
# when Zitadel is on and `monitoring.grafana_external_url` is set (the public
# URL builds the OIDC redirect URI and Grafana's `root_url`).
#
#   - `module "grafana_oidc"` creates the Zitadel project + OIDC app and a
#     Secret with the `GF_AUTH_GENERIC_OAUTH_*` env (format `grafana_oauth`).
#   - `local.grafana_oidc_values` is merged into the Grafana chart values in
#     main.tf. It names the Secret by its fixed name (optional, so the pod
#     still starts before the Secret exists on a fresh install) instead of a
#     module reference: the Secret lives in the namespace the addons module
#     creates, and a reference would make addons wait for it.
#   - `kubernetes_annotations.grafana_oidc_checksum` rolls Grafana when the
#     Secret changes (a recreated Zitadel app means a new client secret).
#
# Roles come from the `groups` claim (zitadel_actions.tf: every role key the
# user holds in any project). `platform_admin` / `grafana_admin` → Admin,
# `grafana_editor` → Editor, `grafana_viewer` → Viewer. Anyone else is
# refused (`role_attribute_strict`), so a Zitadel account alone grants
# nothing. The local login form stays as break-glass:
# `<url>/login?disableAutoLogin=true` with the chart's admin password.

locals {
  grafana_external_url = trimsuffix(try(local.platform.monitoring.grafana_external_url, ""), "/")
  grafana_oidc_enabled = local.platform.services.zitadel.enabled && local.grafana_external_url != ""
  grafana_oidc_secret  = "grafana-oidc"

  # `for ... if` instead of `cond ? {...} : {}`: the two branches would have
  # different object types.
  grafana_oidc_values = {
    for k, v in {
      envFromSecrets = [{ name = local.grafana_oidc_secret, optional = true }]
      "grafana.ini" = {
        server = {
          root_url = local.grafana_external_url
        }
        auth = {
          # Logout ends the Zitadel session too, not only Grafana's.
          signout_redirect_url = "https://${local.platform.services.zitadel.external_domain}/oidc/v1/end_session?post_logout_redirect_uri=${urlencode("${local.grafana_external_url}/login")}"
        }
        "auth.generic_oauth" = {
          enabled               = true
          name                  = "Zitadel"
          auto_login            = true
          allow_sign_up         = true
          use_pkce              = true
          scopes                = "openid profile email"
          login_attribute_path  = "preferred_username"
          email_attribute_path  = "email"
          name_attribute_path   = "name"
          role_attribute_strict = true
          role_attribute_path   = "(contains(groups[*], 'platform_admin') || contains(groups[*], 'grafana_admin')) && 'Admin' || contains(groups[*], 'grafana_editor') && 'Editor' || contains(groups[*], 'grafana_viewer') && 'Viewer'"
        }
      }
    } : k => v if local.grafana_oidc_enabled
  }
}

module "grafana_oidc" {
  source     = "./modules/zitadel-app"
  for_each   = local.grafana_oidc_enabled ? toset(["enabled"]) : toset([])
  depends_on = [module.addons]

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = data.zitadel_orgs.platform_org["enabled"].ids[0]
  project_name = "grafana"
  app_name     = "grafana"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  redirect_uris    = ["${local.grafana_external_url}/login/generic_oauth"]
  post_logout_uris = ["${local.grafana_external_url}/login"]

  secret_name      = local.grafana_oidc_secret
  secret_namespace = "monitoring"
  secret_formats   = ["grafana_oauth"]

  roles = [
    { key = "grafana_admin", display_name = "Grafana Admin" },
    { key = "grafana_editor", display_name = "Grafana Editor" },
    { key = "grafana_viewer", display_name = "Grafana Viewer" },
  ]
}

resource "kubernetes_annotations" "grafana_oidc_checksum" {
  for_each = module.grafana_oidc

  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = "monitoring"
  }
  template_annotations = {
    "checksum/oidc" = each.value.secret_checksum
  }
}
