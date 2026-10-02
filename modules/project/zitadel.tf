# ── Zitadel auto-provisioning for chart-deployed apps ────────────────────────
#
# Counterpart of the `kind: app` machinery below — but for charts the
# engine doesn't render itself (Argo CD-managed Helm charts in this
# project's namespace). Operator declares
# `chart_oidc_apps:<secret-name>` in the domain yaml; engine spins up
# one Zitadel Project + OIDC Application per entry and writes the
# four standard keys (issuer / client_id / client_secret / auth
# secret) into a `kubernetes_secret_v1` of the matching name in the
# project namespace. The chart's `envFrom: secretRef` then picks
# them up — no operator-side `kubectl create secret`, no OIDC
# values committed in plain text.

# A warning, not a precondition: on a first install the PAT exists only
# after Zitadel is up, and a hard stop would block that apply.
check "zitadel_provider_authenticated_when_chart_oidc_used" {
  assert {
    condition     = length(var.chart_oidc_apps) == 0 || var.zitadel_provider_authenticated
    error_message = "project '${local.namespace}' declares `chart_oidc_apps:` entries but `var.zitadel_pat` is empty — the Zitadel TF provider can't authenticate, so `zitadel_application_oidc` resources would fail at apply time. Set `TF_VAR_zitadel_pat` from a Zitadel IAM_OWNER PAT and re-run."
  }
}

# Naming for chart_oidc_apps entries.
#
# The yaml key (e.g. `web-frontend-oidc`) is descriptive of the
# Secret it produces (k8s Secret carrying `AUTH_ZITADEL_*`), but
# defaulting the Zitadel project + app name to the same string
# leaves operators reading the Zitadel UI unable to tell which
# environment they're looking at — `web-frontend-oidc` could be
# dev, prod, staging.
#
# Solution: route naming through `terraform-null-label` so the
# Zitadel project + app name auto-include the env (`web-frontend
# -dev`), while the k8s Secret name keeps the descriptive `-oidc`
# suffix the chart's `envFrom` references. Operators can override
# every output via explicit `project_name` / `app_name` /
# `secret_name` fields per entry — `try(each.value.X, default)`
# preserves the override-wins semantics.
#
# `trimsuffix(each.key, "-oidc")` strips the operator's descriptive
# Secret-naming convention before composing the project / app id —
# the engine's strong opinion is that yaml keys SHOULD end in
# `-oidc` (matches what the pod's envFrom references) but the
# Zitadel-side names SHOULD NOT (operators read those in the
# Zitadel console where `-oidc` is just noise).
module "chart_oidc_label" {
  for_each = var.chart_oidc_apps

  source  = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"
  context = module.project_label.context
  name    = trimsuffix(each.key, "-oidc")
  # Explicit `label_order` shrinks the id to `<name>-<attributes>`
  # so the Zitadel project name stays the operator's chosen
  # `<key-without-oidc-suffix>-<env>` shape. Without this override
  # the inherited default `["namespace", "environment", "name",
  # "attributes"]` from `module.project_label.context` would prefix
  # the id with the tenant namespace + env, renaming every existing
  # Zitadel project — destructive.
  label_order = ["name", "attributes"]
  attributes  = [local.env]
}

module "chart_oidc" {
  for_each = var.chart_oidc_apps

  source = "../zitadel-app"

  org_id           = var.zitadel_org_id
  project_name     = try(each.value.project_name, module.chart_oidc_label[each.key].id)
  app_name         = try(each.value.app_name, module.chart_oidc_label[each.key].id)
  issuer_url       = var.zitadel_issuer_url
  redirect_uris    = try(each.value.redirect_uris, [])
  post_logout_uris = try(each.value.post_logout_uris, [])
  dev_mode         = try(each.value.dev_mode, false)
  roles            = try(each.value.roles, [])

  secret_namespace = kubernetes_namespace_v1.this.metadata[0].name
  secret_name      = try(each.value.secret_name, each.key)
  secret_formats   = try(each.value.secret_formats, ["auth_js"])
}

# ── Zitadel auto-provisioning for `kind: app` components ─────────────────────
#
# One Project + Application + Roles + k8s Secret per opted-in app.
# Project name defaults to the component name (v1: one project per
# app); roles default to `[platform_admin, tenant_admin, user]` so a
# bare `oidc.enabled: true` already buys a usable role tree. Override
# both via the component yaml — see any `kind: app` example for the
# worked shape.

# A warning, not a precondition: on a first install the PAT exists only
# after Zitadel is up, and a hard stop would block that apply.
check "zitadel_pat_set_when_app_oidc_used" {
  assert {
    condition     = length(local.app_components_with_oidc) == 0 || var.zitadel_provider_authenticated
    error_message = "project '${local.namespace}' has `kind: app` components with `oidc.enabled: true` (${join(", ", keys(local.app_components_with_oidc))}) but `TF_VAR_zitadel_pat` is empty. Bootstrap the PAT once: `kubectl get secret zitadel-tf-pat -n platform -o jsonpath='{.data.access_token}' | base64 -d`, then paste it into `.env` as `TF_VAR_zitadel_pat=...`. See operating.md → 'Zitadel PAT bootstrap'."
  }
}

module "zitadel_app" {
  for_each = local.app_components_with_oidc

  source = "../zitadel-app"

  org_id       = var.zitadel_org_id
  project_name = try(each.value.oidc.project, each.key)
  app_name     = each.key

  issuer_url = var.zitadel_issuer_url

  # Build prod-style redirect URIs from the hostnames Traefik routes
  # to this component crossed with the operator-supplied paths. Local
  # `http://localhost:5173/...` URIs are intentionally NOT auto-added
  # — wire those by hand on a separate dev-mode application in the
  # Zitadel UI when iterating locally.
  redirect_uris = flatten([
    for host in local.hosts_by_component[each.key] : [
      for path in try(each.value.oidc.redirect_paths, ["/auth/callback/zitadel"]) :
      "https://${host}${path}"
    ]
  ])

  post_logout_uris = flatten([
    for host in local.hosts_by_component[each.key] : [
      for path in try(each.value.oidc.post_logout_paths, ["/"]) :
      "https://${host}${path}"
    ]
  ])

  grant_types    = try(each.value.oidc.grant_types, ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"])
  response_types = try(each.value.oidc.response_types, ["OIDC_RESPONSE_TYPE_CODE"])
  app_type       = try(each.value.oidc.app_type, "OIDC_APP_TYPE_WEB")
  auth_method    = try(each.value.oidc.auth_method, "OIDC_AUTH_METHOD_TYPE_BASIC")
  dev_mode       = try(each.value.oidc.dev_mode, false)

  roles = try(each.value.oidc.roles, [
    { key = "platform_admin", display_name = "Platform Admin", group = "" },
    { key = "tenant_admin", display_name = "Tenant Admin", group = "" },
    { key = "user", display_name = "User", group = "" },
  ])

  secret_namespace = kubernetes_namespace_v1.this.metadata[0].name
  secret_name      = "${each.key}-oidc"
}
