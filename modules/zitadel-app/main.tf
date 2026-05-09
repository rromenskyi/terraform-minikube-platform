terraform {
  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}


# ── Resources ─────────────────────────────────────────────────────────────────

resource "zitadel_project" "this" {
  org_id = var.org_id
  name   = var.project_name

  # Standard production defaults. project_role_assertion = put roles
  # into the ID token (Auth.js reads from there). project_role_check
  # off because a role is an authorization signal, not an authn gate
  # — let the app decide what unroled users can see.
  project_role_assertion = true
  project_role_check     = false
  has_project_check      = false
}

resource "zitadel_project_role" "roles" {
  for_each = { for r in var.roles : r.key => r }

  org_id       = var.org_id
  project_id   = zitadel_project.this.id
  role_key     = each.value.key
  display_name = each.value.display_name
  group        = each.value.group
}

resource "zitadel_application_oidc" "this" {
  org_id     = var.org_id
  project_id = zitadel_project.this.id
  name       = var.app_name

  redirect_uris             = var.redirect_uris
  post_logout_redirect_uris = var.post_logout_uris
  response_types            = var.response_types
  grant_types               = var.grant_types
  app_type                  = var.app_type
  auth_method_type          = var.auth_method
  dev_mode                  = var.dev_mode

  # ID-token enrichment so Auth.js / similar can decode roles from
  # the JWT without a follow-up /userinfo call.
  id_token_role_assertion      = true
  id_token_userinfo_assertion  = true
  access_token_role_assertion  = true
  access_token_type            = "OIDC_TOKEN_TYPE_BEARER"
  additional_origins           = []
  clock_skew                   = "0s"
  version                      = "OIDC_VERSION_1_0"
  skip_native_app_success_page = false
  back_channel_logout_uri      = ""
}

# Cookie / session encryption key for downstream Auth.js (or similar).
# Generated once per app, lives in TF state, mounted into the pod via
# the Secret below. Replace via `terraform taint` if you ever need to
# rotate (will invalidate every existing user session).
resource "random_password" "auth_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "oidc" {
  metadata {
    name      = var.secret_name
    namespace = var.secret_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "oidc-credentials"
    }
  }

  data = merge(
    # auth_js — @auth/sveltekit / Auth.js standard env names. Default,
    # always-emitted historically; kept as the canonical set so the
    # AUTH_SECRET (signing key for Auth.js JWT cookies) is part of
    # every format's output regardless of which client convention
    # the chart follows.
    contains(var.secret_formats, "auth_js") ? {
      AUTH_ZITADEL_ISSUER = var.issuer_url
      AUTH_ZITADEL_ID     = zitadel_application_oidc.this.client_id
      AUTH_ZITADEL_SECRET = zitadel_application_oidc.this.client_secret
      AUTH_SECRET         = random_password.auth_secret.result
    } : {},

    # open_webui — Open WebUI's `ENABLE_OAUTH_SIGNUP` flow reads a
    # discovery URL (full path to /.well-known/openid-configuration),
    # not the bare issuer. Compose it from issuer + standard suffix
    # so charts don't have to assemble it themselves.
    contains(var.secret_formats, "open_webui") ? {
      OAUTH_CLIENT_ID     = zitadel_application_oidc.this.client_id
      OAUTH_CLIENT_SECRET = zitadel_application_oidc.this.client_secret
      OPENID_PROVIDER_URL = "${var.issuer_url}/.well-known/openid-configuration"
    } : {},

    # grafana_oauth — Grafana's `[auth.generic_oauth]` config can be
    # driven entirely via `GF_AUTH_GENERIC_OAUTH_*` env. Auth/token/
    # API URLs follow Zitadel's standard issuer paths.
    contains(var.secret_formats, "grafana_oauth") ? {
      GF_AUTH_GENERIC_OAUTH_CLIENT_ID     = zitadel_application_oidc.this.client_id
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = zitadel_application_oidc.this.client_secret
      GF_AUTH_GENERIC_OAUTH_AUTH_URL      = "${var.issuer_url}/oauth/v2/authorize"
      GF_AUTH_GENERIC_OAUTH_TOKEN_URL     = "${var.issuer_url}/oauth/v2/token"
      GF_AUTH_GENERIC_OAUTH_API_URL       = "${var.issuer_url}/oidc/v1/userinfo"
    } : {},
  )
}

